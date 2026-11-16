/**
 * dsh-guard — a deterministic pre-execution guard for destructive shell calls.
 *
 * The plugin is a Cordis host plugin (the "server half" of a DSH plugin). It
 * listens to the tool pipeline's extensible `tools/pre-execute` waterfall,
 * inspects a tool call's arguments before the tool body runs, and returns one
 * of the pipeline's gate decisions:
 *
 *   next()                                  -> allow (let the call proceed)
 *   { kind: 'deny', reason }                -> block; nothing executes
 *   { kind: 'ask', reason, displayReason }  -> route one approval request
 *
 * It never rewrites arguments (the pipeline forbids that on purpose) and never
 * runs a command itself. Approval routing, auditing of the decision, and the
 * fail-closed behavior of an absent approval channel are owned by DSH.
 *
 * Reference: `tools/pre-execute` is dispatched from
 * `@deepseek-ai/dsh-tools/lib/pipeline.js` (`prepare()`), and `ask` is resolved
 * through the `approval` service (`serviceAsk()`). See the research document
 * `../research/dsh-guard-feasibility.md` for file/line evidence.
 */
import { appendFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { DEFAULT_PROTECTED_PATHS, evaluateCall } from './rules.js';

/** Stable plugin name shown in the profile tree. */
export const name = 'dsh-guard';

const DEFAULT_TOOLS = ['pwsh', 'bash', 'terminal', 'pwsh-persistent', 'bash-persistent'];
const DEFAULT_CODE_TOOLS = ['run_code'];
const MODES = new Set(['ask', 'deny', 'audit']);

/** Default audit log location: `<temp>/dsh-guard/audit.jsonl`. */
function defaultAuditPath() {
  return join(tmpdir(), 'dsh-guard', 'audit.jsonl');
}

/** Normalize the raw Cordis config into the settings the engine expects. */
function buildSettings(config = {}) {
  const mode = MODES.has(config.mode) ? config.mode : 'ask';
  const protectAction = config.protectAction === 'ask' ? 'ask' : 'deny';
  const unresolvedAction = config.unresolvedAction === 'deny' ? 'deny' : 'ask';
  const protectedPaths = Array.isArray(config.protectedPaths)
    ? config.protectedPaths.filter((item) => typeof item === 'string')
    : [];
  const allowedRoots = Array.isArray(config.allowedRoots)
    ? config.allowedRoots.filter((item) => typeof item === 'string')
    : [];
  const auditPath = config.auditPath === false
    ? false
    : typeof config.auditPath === 'string' && config.auditPath.trim() !== ''
      ? config.auditPath
      : defaultAuditPath();
  return {
    mode,
    protectAction,
    unresolvedAction,
    failClosed: config.failClosed !== false,
    auditPath,
    auditAllow: config.auditAllow === true,
    protectedPaths: [...DEFAULT_PROTECTED_PATHS, ...protectedPaths],
    allowedRoots,
    toolNames: new Set(Array.isArray(config.toolNames) && config.toolNames.length > 0 ? config.toolNames : DEFAULT_TOOLS),
    inspectCodeTools: new Set(
      Array.isArray(config.inspectCodeTools) && config.inspectCodeTools.length > 0 ? config.inspectCodeTools : DEFAULT_CODE_TOOLS,
    ),
    inspectUnknownTools: config.inspectUnknownTools !== false,
  };
}

/** Append one audit record. Auditing must never break the tool call. */
function audit(settings, record) {
  if (settings.auditPath === false) return;
  try {
    mkdirSync(dirname(settings.auditPath), { recursive: true });
    appendFileSync(settings.auditPath, `${JSON.stringify(record)}\n`, { encoding: 'utf8' });
  } catch {
    // A read-only temp area or a full disk must not turn into a tool failure.
  }
}

/** Model-facing denial text. The model reads this as `Error: <reason>`. */
function denyReason(verdict) {
  return [
    'dsh-guard blocked this call before execution',
    verdict.reasons.join('; '),
    'Nothing was executed.',
    'Use an explicit absolute target inside a scratch/workspace directory, verify it with a read-only command first, or ask the user to run this deletion themselves.',
  ].join(': ');
}

/**
 * Decide whether an approval request can actually reach a human.
 *
 * The tools pipeline resolves `ask` through the `approval` service, which under
 * the `never` policy (the shipped danger-full-access preset) returns
 * `rejected` without prompting, and returns `unavailable` when no answerer is
 * composed. Reporting our own explicit denial in those states keeps the model
 * message truthful instead of "the user rejected tool ..." when no prompt ever
 * existed.
 *
 * @returns {'ask'|'deny'} the effective gate outcome for an ask-class verdict.
 */
function approvalPath(ctx, exec) {
  let approval;
  try {
    approval = typeof ctx.get === 'function' ? ctx.get('approval') : undefined;
  } catch {
    approval = undefined;
  }
  const session = exec?.agent?.session;
  if (approval === undefined || session === undefined) return 'deny';
  try {
    if (typeof approval.effectivePolicy === 'function' && approval.effectivePolicy(session) === 'never') return 'deny';
    if (approval.config !== undefined && approval.config !== null && approval.config.policy === 'never') return 'deny';
    if (exec.agent === undefined) return 'deny';
  } catch {
    return 'deny';
  }
  return 'ask';
}

/** Model-facing ask text; the text is also the approval request's logged reason. */
function askReason(verdict) {
  return [
    'dsh-guard paused this call for explicit user approval',
    verdict.reasons.join('; '),
    'The call runs unchanged only if the user approves it now.',
  ].join(': ');
}

/** Approval prompt text (Traditional Chinese) shown to the user. */
function askDisplayReason(verdict) {
  const detail = verdict.reasons.join('；');
  return `dsh-guard：偵測到破壞性命令，已暫停等待你批准（${detail}）。批准後命令會原樣執行；請先確認目標路徑就是你想要的那一個。`;
}

/**
 * Mount the guard.
 *
 * @param {import('@deepseek-ai/cordis').Context} ctx host context
 * @param {object} [config] see README.md; raw object because this package
 *   deliberately ships no schemastery schema and no runtime dependency.
 */
export function apply(ctx, config = {}) {
  const settings = buildSettings(config);
  let log;
  try {
    log = typeof ctx.logger === 'function' ? ctx.logger('dsh-guard') : undefined;
  } catch {
    log = undefined;
  }

  ctx.on('tools/pre-execute', async (exec, next) => {
    let verdict;
    try {
      verdict = evaluateCall(exec, settings);
    } catch (error) {
      // Fail closed by default: an internal rule error degrades to an approval
      // request (which becomes a denial under the `never` approval policy)
      // instead of silently letting a possibly destructive call through.
      const message = error instanceof Error ? error.message : String(error);
      log?.warn?.('rule evaluation failed, failing closed: %s', message);
      audit(settings, {
        ts: new Date().toISOString(),
        tool: exec?.name ?? '',
        callId: exec?.callId ?? '',
        action: settings.failClosed ? 'ask' : 'allow',
        error: message,
      });
      if (!settings.failClosed) return next();
      return {
        kind: 'ask',
        reason: `dsh-guard could not evaluate this call (${message}), so it paused the call for explicit approval.`,
        displayReason: 'dsh-guard：規則評估失敗，已暫停此呼叫等你決定。',
      };
    }

    if (verdict.action === 'allow') {
      if (settings.auditAllow && verdict.reasons.length > 0) {
        audit(settings, {
          ts: new Date().toISOString(),
          tool: exec?.name ?? '',
          callId: exec?.callId ?? '',
          action: 'allow',
          reasons: verdict.reasons,
          hits: verdict.hits,
        });
      }
      return next();
    }

    // An ask-class verdict becomes a real denial when no human can be asked.
    const askBlocked = verdict.action === 'ask' && approvalPath(ctx, exec) === 'deny';
    const finalAction = askBlocked ? 'deny' : verdict.action;

    audit(settings, {
      ts: new Date().toISOString(),
      tool: exec?.name ?? '',
      callId: exec?.callId ?? '',
      action: finalAction,
      reasons: verdict.reasons,
      hits: verdict.hits,
      command: verdict.command,
    });

    if (finalAction === 'deny') {
      log?.warn?.('blocked %s call %s: %s', exec?.name ?? '', exec?.callId ?? '', verdict.reasons.join('; '));
      const note = askBlocked
        ? ' No approval prompt can be shown here (the session approval policy is "never", or the call has no agent), so it was denied instead of paused.'
        : '';
      return { kind: 'deny', reason: denyReason(verdict) + note };
    }

    log?.info?.('asking for approval on %s call %s: %s', exec?.name ?? '', exec?.callId ?? '', verdict.reasons.join('; '));
    return { kind: 'ask', reason: askReason(verdict), displayReason: askDisplayReason(verdict) };
  });

  log?.info?.(
    'active (mode=%s, protect=%s, unresolved=%s, audit=%s)',
    settings.mode,
    settings.protectAction,
    settings.unresolvedAction,
    settings.auditPath === false ? 'off' : settings.auditPath,
  );
}
