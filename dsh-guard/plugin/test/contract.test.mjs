/**
 * Contract tests for the dsh-guard plugin entry.
 *
 * They reproduce the exact listener shape the DSH tool pipeline uses:
 *   ctx.waterfall(carrier, 'tools/pre-execute', exec, () => ({ kind: 'allow' }))
 * where the listener receives `(exec, next)` and returns a gate decision.
 * See @deepseek-ai/dsh-tools/lib/pipeline.js `prepare()`.
 *
 * The tests do not load a real DSH application (that needs a profile change);
 * they verify the plugin's own contract against that pipeline shape.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { apply, name } from '../index.js';

/**
 * Minimal Cordis-like context: records listeners, offers a logger stub, and
 * exposes an `approval` service stub so the ask path can be exercised.
 *
 * @param {{policy?: 'ask'|'never'|'none'}} options
 */
function fakeContext(options = {}) {
  const policy = options.policy ?? 'ask';
  const listeners = new Map();
  const approval = policy === 'none'
    ? undefined
    : {
        config: { policy },
        effectivePolicy: () => policy,
      };
  return {
    listeners,
    on(event, listener) {
      const list = listeners.get(event) ?? [];
      list.push(listener);
      listeners.set(event, list);
      return () => {};
    },
    get(service) {
      return service === 'approval' ? approval : undefined;
    },
    logger() {
      return { info() {}, warn() {}, error() {}, debug() {} };
    },
  };
}

/**
 * Drive one gate decision exactly like the pipeline does: a waterfall where a
 * listener that does not call `next()` vetoes the built-in `{ kind:'allow' }`.
 */
async function gate(ctx, exec) {
  const chain = ctx.listeners.get('tools/pre-execute') ?? [];
  const inner = async () => ({ kind: 'allow' });
  const dispatch = async (index) => {
    const listener = chain[index];
    if (!listener) return inner();
    let called = false;
    const next = () => {
      if (called) throw new Error('next() called multiple times');
      called = true;
      return dispatch(index + 1);
    };
    return listener(exec, next);
  };
  return dispatch(0);
}

function mount(config = {}, options = {}) {
  const ctx = fakeContext(options);
  apply(ctx, { auditPath: false, ...config });
  assert.equal(ctx.listeners.get('tools/pre-execute')?.length, 1, 'registers one pre-execute listener');
  return ctx;
}

const SCRATCH_DELETE = 'Remove-Item -Recurse -Force "C:\\Temp\\dsh-guard-test"';

/** A fake exec carries the agent/session the pipeline would supply. */
const agent = { session: { id: 'session-test' } };

test('exports a stable plugin name', () => {
  assert.equal(name, 'dsh-guard');
});

test('catastrophic shell command is denied before execution', async () => {
  const ctx = mount();
  let executed = false;
  const decision = await gate(ctx, {
    name: 'pwsh',
    callId: 'c1',
    agent,
    arguments: { command: 'rd /s /q C:\\', description: 'clean up' },
  });
  if (decision.kind === 'allow') executed = true;
  assert.equal(decision.kind, 'deny', JSON.stringify(decision));
  assert.equal(executed, false);
  assert.match(decision.reason, /protected path/i);
});

test('ordinary read command passes through by calling next()', async () => {
  const ctx = mount();
  const decision = await gate(ctx, { name: 'pwsh', callId: 'c2', agent, arguments: { command: 'Get-ChildItem C:\\Temp' } });
  assert.equal(decision.kind, 'allow');
});

test('recursive delete asks the approval seam and runs unchanged if approved', async () => {
  const ctx = mount();
  const decision = await gate(ctx, { name: 'pwsh', callId: 'c3', agent, arguments: { command: SCRATCH_DELETE } });
  assert.equal(decision.kind, 'ask', JSON.stringify(decision));
  assert.ok(decision.reason.length > 0);
  assert.ok(decision.displayReason.includes('dsh-guard'));
});

test('the pipeline default resolves a non-vetoing listener to allow', async () => {
  const ctx = mount();
  const decision = await gate(ctx, { name: 'pwsh', callId: 'c4', agent, arguments: { command: 'git status' } });
  assert.deepEqual(decision, { kind: 'allow' });
});

test('ask becomes an explicit denial when the approval policy is "never"', async () => {
  const ctx = mount({}, { policy: 'never' });
  const decision = await gate(ctx, { name: 'pwsh', callId: 'c5', agent, arguments: { command: SCRATCH_DELETE } });
  assert.equal(decision.kind, 'deny', JSON.stringify(decision));
  assert.match(decision.reason, /approval policy is "never"|cannot be shown/i);
});

test('ask becomes a denial when no approval service is composed', async () => {
  const ctx = mount({}, { policy: 'none' });
  const decision = await gate(ctx, { name: 'pwsh', callId: 'c6', agent, arguments: { command: SCRATCH_DELETE } });
  assert.equal(decision.kind, 'deny', JSON.stringify(decision));
});

test('an internal rule error fails closed to an approval request', async () => {
  const ctx = mount();
  const exec = {
    name: 'pwsh',
    callId: 'c7',
    agent,
    get arguments() {
      throw new Error('simulated rule failure');
    },
  };
  const decision = await gate(ctx, exec);
  assert.equal(decision.kind, 'ask', JSON.stringify(decision));
  assert.match(decision.reason, /could not evaluate/i);
});

test('failClosed: false lets the call through on an internal error', async () => {
  const ctx = mount({ failClosed: false });
  const exec = {
    name: 'pwsh',
    callId: 'c8',
    agent,
    get arguments() {
      throw new Error('simulated rule failure');
    },
  };
  assert.deepEqual(await gate(ctx, exec), { kind: 'allow' });
});

test('config mode "deny" turns the ask into a block', async () => {
  const ctx = mount({ mode: 'deny' });
  const decision = await gate(ctx, { name: 'pwsh', callId: 'c9', agent, arguments: { command: SCRATCH_DELETE } });
  assert.equal(decision.kind, 'deny', JSON.stringify(decision));
});

test('permitted tool name filter ignores unrelated tools', async () => {
  const ctx = mount();
  const decision = await gate(ctx, {
    name: 'write',
    callId: 'c10',
    agent,
    arguments: { path: 'C:\\Temp\\a.txt', content: 'rd /s /q C:\\' },
  });
  assert.deepEqual(decision, { kind: 'allow' });
});
