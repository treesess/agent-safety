/**
 * Offline integration check for dsh-guard against the real Cordis 4.1 runtime
 * that DSH 0.2.2-rc.1 ships.
 *
 * Prerequisite: run `node asar-extract.mjs` first (writes ./node_modules here).
 *
 * Why this exists: installing the plugin into a live DSH profile is a user
 * action, so this reproduces the parts that actually need verification:
 *   1. Cordis accepts the plugin (object plugin with `apply`) and mounts it.
 *   2. The listener is admitted for an agent-scoped carrier even though the
 *      plugin is mounted at the root (@deepseek-ai/dsh-scope admission rule).
 *   3. Decisions match the tools pipeline's gate vocabulary.
 *   4. Under approval policy "never", ask becomes an explicit denial.
 *   5. Disposing the plugin fiber removes the listener.
 */
import assert from 'node:assert/strict';
import { Context } from '@deepseek-ai/cordis';
import { scopeTarget } from '@deepseek-ai/dsh-scope';
import * as guard from '../dsh-guard/index.js';

const PROTECTED = ['C:\\work'];
const agent = { session: { id: 'session-harness' } };

/** Provide a minimal `approval` service stub with a fixed policy. */
async function makeRoot(policy) {
  const root = new Context();
  const approvalFiber = root.plugin({
    name: 'approval-stub',
    apply(ctx) {
      ctx.provide('approval', { config: { policy }, effectivePolicy: () => policy });
    },
  });
  await approvalFiber;
  const fiber = root.plugin(guard, { auditPath: false, protectedPaths: PROTECTED });
  await fiber;
  return { root, fiber };
}

/** Dispatch exactly like @deepseek-ai/dsh-tools/lib/pipeline.js prepare(). */
async function prepare(root, exec) {
  const carrier = scopeTarget({}, Symbol('agent-scope'));
  return root.waterfall(carrier, 'tools/pre-execute', exec, async () => ({ kind: 'allow' }));
}

let failures = 0;
function check(label, got, expected) {
  const ok = got === expected;
  if (!ok) failures++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}: expected=${expected} got=${got ?? 'undefined'}`);
}

// --- approval policy "ask" (the workspace-write preset default) -------------
{
  const { root, fiber } = await makeRoot('ask');
  const cases = [
    ['drive-root recursive delete', 'rd /s /q C:\\', 'deny'],
    ['protected personal root', 'Remove-Item -Recurse -Force "C:\\work\\project"', 'deny'],
    ['ordinary read', 'Get-ChildItem C:\\Temp', 'allow'],
    ['recursive delete of a scratch path', 'Remove-Item -Recurse -Force "C:\\Temp\\dsh-guard-test"', 'ask'],
  ];
  for (const [label, command, expected] of cases) {
    const decision = await prepare(root, { name: 'pwsh', callId: label, agent, arguments: { command } });
    check(label, decision?.kind, expected);
    if (decision.kind === 'deny' || decision.kind === 'ask') {
      assert.ok(typeof decision.reason === 'string' && decision.reason.length > 0, 'decision carries a reason');
    }
  }

  const ptc = await prepare(root, {
    name: 'run_code',
    callId: 'ptc',
    agent,
    arguments: { code: "await tools.pwsh({ command: 'rd /s /q C:\\\\' })" },
  });
  check('unresolved PTC program body', ptc?.kind, 'ask');

  await fiber.dispose();
  const afterDispose = await prepare(root, { name: 'pwsh', callId: 'after', agent, arguments: { command: 'rd /s /q C:\\' } });
  check('listener removed after plugin disposal', afterDispose?.kind, 'allow');
}

// --- approval policy "never" (the shipped danger-full-access preset) --------
{
  const { root } = await makeRoot('never');
  const decision = await prepare(root, {
    name: 'pwsh',
    callId: 'never-policy',
    agent,
    arguments: { command: 'Remove-Item -Recurse -Force "C:\\Temp\\dsh-guard-test"' },
  });
  check('ask degrades to explicit denial under policy "never"', decision?.kind, 'deny');
}

if (failures > 0) {
  console.error(`\n${failures} case(s) failed`);
  process.exit(1);
}
console.log('\nall cordis integration cases passed');
