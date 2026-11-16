/**
 * Unit tests for the dsh-guard rule engine.
 *
 * Run with: node --test test/   (Node 18+; verified on Node 24/26)
 * The tests are pure: they never create, move, or delete a real file and
 * never write the audit log.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  analyzeCode,
  analyzeCommand,
  evaluateCall,
  isProtectedPath,
  normalizePath,
} from '../rules.js';

const PROTECTED = ['C:\\work'];
const settings = { protectedPaths: PROTECTED, allowedRoots: [] };

/** Evaluate a plausible exec record for the `pwsh` tool. */
function pwsh(command, extra = {}) {
  return evaluateCall({ name: 'pwsh', callId: 'call-1', arguments: { command, ...extra } }, settings);
}

test('normalizePath canonicalizes separators and trailing slashes', () => {
  assert.equal(normalizePath('  "C:/"  '), 'C:\\');
  assert.equal(normalizePath('C:\\Temp\\'), 'C:\\Temp');
  assert.equal(normalizePath('c:\\Temp\\\\x'), 'c:\\Temp\\x');
  assert.equal(normalizePath('/'), '\\');
  assert.equal(normalizePath(''), '');
});

test('drive and filesystem roots are protected', () => {
  for (const target of ['C:\\', 'C:/', 'C:', '\\', '/', 'D:\\']) {
    assert.equal(isProtectedPath(target, PROTECTED)?.level, 'protected', target);
  }
});

test('common catastrophic deletions are denied', () => {
  const commands = [
    'rd /s /q C:\\',
    'rd /s /q "C:/"',
    'cmd /c rd /s /q "C:\\"',
    'rmdir /s /q C:\\',
    'Remove-Item -Recurse -Force C:\\',
    'Remove-Item -Recurse -Force "C:\\"',
    'rm -rf /',
    'rm -rf C:/',
  ];
  for (const command of commands) {
    const verdict = pwsh(command);
    assert.equal(verdict.action, 'deny', `${command} -> ${JSON.stringify(verdict)}`);
  }
});

test('protected data roots are denied, including subpaths', () => {
  const commands = [
    'Remove-Item -Recurse -Force "C:\\work"',
    "Remove-Item -Recurse -Force 'C:\\work\\project'",
    'rd /s /q "C:\\work\\project"',
    'Remove-Item -Recurse -Force "$env:USERPROFILE"',
    'Remove-Item -Recurse -Force "C:\\Users\\user\\.dsh"',
    'Remove-Item -Recurse -Force "C:\\Windows\\System32"',
    'Remove-Item -Recurse -Force "C:\\ProgramData"',
    'robocopy "C:\\Temp\\src" "C:\\Program Files" /MIR',
  ];
  for (const command of commands) {
    const verdict = pwsh(command);
    assert.equal(verdict.action, 'deny', `${command} -> ${JSON.stringify(verdict)}`);
  }
});

test('harmless read-only and single-file commands stay allowed', () => {
  const commands = [
    'Get-ChildItem C:\\Temp',
    'git status',
    'npm run test',
    'Set-Content C:\\Temp\\a.txt hello',
    'Remove-Item C:\\Temp\\one-file.txt',
    'robocopy "C:\\Temp\\src" "C:\\Temp\\dst" /E',
  ];
  for (const command of commands) {
    assert.equal(pwsh(command).action, 'allow', command);
  }
});

test('recursive deletion of an ordinary literal path asks for approval', () => {
  const verdict = pwsh('Remove-Item -Recurse -Force "C:\\Temp\\dsh-guard-test"');
  assert.equal(verdict.action, 'ask', JSON.stringify(verdict));
  assert.match(verdict.reasons.join(' '), /recursive\/bulk/i);
});

test('a reverse mirror asks but does not hard-deny (source may be protected)', () => {
  // SOURCE is read-only; only DEST is deleted into. This must not be a deny.
  const verdict = pwsh('robocopy "C:\\work" "D:\\backup\\work" /MIR');
  assert.equal(verdict.action, 'ask', JSON.stringify(verdict));
});

test('unresolvable targets ask instead of guessing', () => {
  const commands = [
    'Remove-Item -Recurse -Force $target',
    'Get-ChildItem C:\\Temp | Remove-Item -Recurse',
    'Remove-Item -Recurse -Force C:\\Temp\\*',
    'git clean -fdx',
  ];
  for (const command of commands) {
    assert.equal(pwsh(command).action, 'ask', `${command} -> ${JSON.stringify(pwsh(command))}`);
  }
});

test('dry-run forms are allowed', () => {
  assert.equal(pwsh('Remove-Item -Recurse -Force "C:\\work" -WhatIf').action, 'allow');
  assert.equal(pwsh('robocopy "C:\\Temp" "C:\\Temp2" /MIR /L').action, 'allow');
});

test('allowedRoots makes scratch-directory cleanup silent', () => {
  const verdict = evaluateCall(
    { name: 'pwsh', arguments: { command: 'Remove-Item -Recurse -Force "C:\\Temp\\dsh-guard-scratch"' } },
    { protectedPaths: PROTECTED, allowedRoots: ['C:\\Temp'] },
  );
  assert.equal(verdict.action, 'allow', JSON.stringify(verdict));
});

test('mode "deny" escalates every recursive deletion to a block', () => {
  const verdict = evaluateCall(
    { name: 'pwsh', arguments: { command: 'Remove-Item -Recurse -Force "C:\\Temp\\dsh-guard-test"' } },
    { protectedPaths: PROTECTED, allowedRoots: [], mode: 'deny' },
  );
  assert.equal(verdict.action, 'deny', JSON.stringify(verdict));
});

test('unresolvedAction "deny" blocks wildcard and pipeline deletions', () => {
  const verdict = evaluateCall(
    { name: 'pwsh', arguments: { command: 'Remove-Item -Recurse -Force C:\\Temp\\*' } },
    { protectedPaths: PROTECTED, allowedRoots: [], unresolvedAction: 'deny' },
  );
  assert.equal(verdict.action, 'deny', JSON.stringify(verdict));
});

test('run_code bodies are scanned for programmatic destruction', () => {
  const verdict = evaluateCall(
    {
      name: 'run_code',
      arguments: { code: "await tools.pwsh({ command: 'rd /s /q C:\\\\' })", description: 'run a command' },
    },
    settings,
  );
  assert.equal(verdict.action, 'ask', JSON.stringify(verdict));

  const benign = evaluateCall(
    { name: 'run_code', arguments: { code: 'return await tools.pwsh({ command: "git status" })' } },
    settings,
  );
  assert.equal(benign.action, 'allow', JSON.stringify(benign));
});

test('analyzeCommand reports the matching verb', () => {
  const { hits } = analyzeCommand('robocopy "C:\\Temp\\a" "C:\\Temp\\b" /MIR', settings);
  assert.ok(hits.some((hit) => hit.rule === 'robocopy-mirror' && hit.recursive));
});

test('analyzeCode matches destructive program patterns', () => {
  const { hits } = analyzeCode('import { rmSync } from "node:fs"; rmSync("x", { recursive: true })');
  assert.ok(hits.some((hit) => hit.rule === 'code-rm-sync'));
});

test('bogus arguments never throw', () => {
  assert.equal(evaluateCall({ name: 'pwsh', arguments: undefined }, settings).action, 'allow');
  assert.equal(evaluateCall({ name: 'pwsh', arguments: { command: '' } }, settings).action, 'allow');
  assert.equal(evaluateCall({ name: 'pwsh', arguments: { command: 42 } }, settings).action, 'allow');
});
