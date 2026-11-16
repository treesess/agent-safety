/**
 * dsh-guard rule engine.
 *
 * Pure, dependency-free classification of a model tool call BEFORE the tool
 * body runs. It answers one question: does this call contain a destructive
 * shell operation, and is its target a path the user must never lose?
 *
 * The engine is intentionally conservative and textual. Shell command lines
 * are not decidable in general (variables, aliases, nested shells, encoded
 * payloads), so the guard never claims to be a sandbox; it is a speed bump
 * that turns the common catastrophic shape into a block or an approval.
 *
 * API:
 *   normalizePath(raw)                       -> canonical Windows path string
 *   isProtectedPath(path, protectedPaths)    -> { level, why } | undefined
 *   analyzeCommand(command, settings)        -> hit list
 *   analyzeCode(code, settings)              -> hit list (PTC run_code body)
 *   evaluateCall(exec, settings)             -> { action, reasons, hits, ... }
 */

export const ACTIONS = Object.freeze(['allow', 'ask', 'deny']);

/**
 * User data roots that are protected regardless of depth. A personal default;
 * deployments add their own with the `protectedPaths` config field.
 */
export const DEFAULT_PROTECTED_PATHS = Object.freeze(['C:\\work']);

/** Directory names that are protected wherever they appear below a drive root. */
const PROTECTED_SEGMENTS = new Set([
  '.dsh', 'windows', 'program files', 'program files (x86)', 'programdata',
  'system32', 'syswow64', 'appdata', 'system volume information', 'recovery',
]);

/** First-level drive directories whose deletion is always a system-level loss. */
const PROTECTED_FIRST_LEVEL = new Set(['windows', 'program files', 'program files (x86)', 'programdata', 'users']);

/** Tokens that name a home directory without spelling its path. */
const HOME_TOKENS = [/\$env:userprofile\b/i, /%userprofile%/i, /\$home\b/i, /(?:^|[\s"'=])~(?=[\\/]?[\s"']|$)/];

/** Flags that turn a command into a dry run. */
const DRY_RUN = /(?:-whatif\b|--dry-run\b|\/l\b)/i;

/**
 * Destructive verbs. `recursive(text)` decides whether the matched call is
 * recursive, bulk, or mirroring — the class the guard gates. A single-file
 * delete stays allowed by default so ordinary cleanup keeps working.
 */
const VERBS = [
  {
    id: 'cmd-rd',
    label: 'rd/rmdir',
    re: /(?:^|[\s;&|("'`])(?:rd|rmdir)(?:\.exe)?(?=[\s"'])/i,
    recursive: (text) => /(?:^|\s)\/(?:s|q|sq|qs)\b/i.test(text),
    targetMode: 'positional',
  },
  {
    id: 'cmd-del',
    label: 'del/erase',
    re: /(?:^|[\s;&|("'`])(?:del|erase)(?:\.exe)?(?=[\s"'])/i,
    recursive: (text) => /(?:^|\s)\/(?:s|q|f|sq|fs|sqf)\b/i.test(text),
    targetMode: 'positional',
  },
  {
    id: 'ps-remove-item',
    label: 'Remove-Item',
    re: /(?:^|[\s;&|("'`])(?:Remove-Item|ri|rm)(?=[\s;"']|$)/i,
    recursive: (text) => /(?:^|\s)-(?:recurse|r|rf|fr)\b/i.test(text),
    targetMode: 'positional',
  },
  {
    id: 'posix-rm',
    label: 'rm',
    re: /(?:^|[\s;&|("'`])(?:rm|unlink|rmdir)(?=[\s;"']|$)/i,
    recursive: (text) => /(?:^|\s)-(?:r|rf|fr|recursive)\b|--recursive\b/i.test(text),
    targetMode: 'positional',
  },
  {
    id: 'robocopy-mirror',
    label: 'robocopy /MIR',
    re: /(?:^|[\s;&|("'`])robocopy(?:\.exe)?(?=[\s"'])/i,
    recursive: (text) => /(?:^|\s)\/(?:mir|purge|move|mov)\b/i.test(text),
    targetMode: 'robocopy',
  },
  {
    id: 'git-clean',
    label: 'git clean',
    re: /(?:^|[\s;&|("'`])git\s+clean(?=[\s"'])/i,
    recursive: (text) => /(?:^|\s)-[a-z]*[dfx]/i.test(text),
    targetMode: 'positional',
  },
  {
    id: 'disk-destructive',
    label: 'disk/volume operation',
    re: /(?:^|[\s;&|("'`])(?:format|Format-Volume|Clear-Disk|Initialize-Disk|Remove-Partition|diskpart)(?=[\s;"']|$)/i,
    recursive: () => true,
    targetMode: 'positional',
  },
  {
    id: 'shadow-copy-delete',
    label: 'shadow-copy deletion',
    re: /(?:vssadmin\s+delete\s+shadows|wmic\s+shadowcopy\s+delete)/i,
    recursive: () => true,
    targetMode: 'positional',
  },
  {
    id: 'registry-delete',
    label: 'reg delete',
    re: /(?:^|[\s;&|("'`])reg\s+delete(?=[\s"'])/i,
    recursive: () => true,
    targetMode: 'positional',
  },
];

/**
 * Destructive operations that may appear inside a PTC `run_code` program.
 * The guard cannot know their target, so a match only raises the call to the
 * unresolved-target class (approval by default).
 */
const CODE_PATTERNS = [
  { id: 'code-rm-sync', re: /\b(?:rmSync|rmdirSync|unlinkSync|rm|rmdir|unlink)\s*\(/ },
  { id: 'code-child-process', re: /\b(?:child_process|node:child_process)\b|\b(?:spawn|spawnSync|exec|execSync|execFile|execFileSync)\s*\(/ },
  { id: 'code-bulk-fs', re: /\b(?:fs\.rm|fs\.rmdir|fs\.unlink|fsp\.rm)\b/ },
  { id: 'code-destructive-text', re: /\b(?:rd\s+\/s|rmdir\s+\/s|Remove-Item\s+-Recurse|rm\s+-rf|robocopy\b[^\n]*\/MIR|git\s+clean\s+-[a-z]*[dfx]|vssadmin\s+delete\s+shadows)\b/i },
];

/** Convert a raw path to a canonical Windows spelling (no trailing separators). */
export function normalizePath(raw) {
  if (typeof raw !== 'string') return '';
  let p = raw.trim();
  if (p.length >= 2 && ((p.startsWith('"') && p.endsWith('"')) || (p.startsWith("'") && p.endsWith("'")))) {
    p = p.slice(1, -1).trim();
  }
  if (!p) return '';
  p = p.replace(/\//g, '\\');
  // Collapse runs of separators, keeping a leading UNC prefix intact.
  p = p.replace(/\\{2,}/g, (match, offset) => (offset === 0 ? '\\\\' : '\\'));
  // A bare separator run is the filesystem root and must not be trimmed away.
  if (/^\\+$/.test(p)) return '\\';
  if (/^[A-Za-z]:$/.test(p)) return p[0].toUpperCase() + ':\\';
  if (/^[A-Za-z]:\\+$/.test(p)) return p[0].toUpperCase() + ':\\';
  p = p.replace(/\\+$/, '');
  if (!p) return '';
  return p;
}

/** True when the path is a filesystem or drive root. */
function isRootPath(p) {
  return /^[A-Za-z]:\\?$/.test(p) || /^\\+$/.test(p) || p === '\\' || p === '/';
}

/**
 * Classify one path.
 * @returns {{level: 'protected'|'high'|'safe', why: string}|undefined}
 */
export function isProtectedPath(path, protectedPaths = DEFAULT_PROTECTED_PATHS) {
  const p = normalizePath(path);
  if (!p) return undefined;
  if (isRootPath(p)) return { level: 'protected', why: 'filesystem/drive root' };

  const lower = p.toLowerCase();
  const home = (process.env.USERPROFILE ?? '').toLowerCase();
  if (HOME_TOKENS.some((re) => re.test(path))) return { level: 'protected', why: 'home directory reference' };
  if (home && (lower === home || lower === home + '\\')) return { level: 'protected', why: 'user profile root' };

  for (const root of protectedPaths) {
    const r = normalizePath(root).toLowerCase();
    if (!r) continue;
    if (lower === r || lower.startsWith(r.endsWith('\\') ? r : r + '\\')) {
      return { level: 'protected', why: `protected data root (${root})` };
    }
  }

  if (lower.startsWith('\\\\')) {
    // UNC: only the share root itself is treated as catastrophic.
    const parts = lower.split('\\').filter(Boolean);
    if (parts.length <= 2) return { level: 'protected', why: 'network share root' };
    return { level: 'safe', why: '' };
  }

  const parts = p.split('\\').filter(Boolean);
  const rest = parts.slice(1);
  if (parts.length === 1 && parts[0].length === 2) return { level: 'protected', why: 'drive root' };

  for (const segment of rest) {
    if (PROTECTED_SEGMENTS.has(segment.toLowerCase())) {
      return { level: 'protected', why: `system/configuration directory (${segment})` };
    }
  }
  if (rest.length === 1 && PROTECTED_FIRST_LEVEL.has(rest[0].toLowerCase())) {
    return { level: 'protected', why: `system directory (${rest[0]})` };
  }
  if (rest.length === 1) return { level: 'high', why: 'top-level directory below a drive root' };
  if (home && lower.startsWith(home + '\\')) {
    const under = lower.slice(home.length + 1).split('\\').filter(Boolean);
    if (under.length === 1) return { level: 'high', why: 'direct child of the user profile' };
  }
  return { level: 'safe', why: '' };
}

/** True when the raw token cannot be resolved statically. */
function isUnresolvedToken(token) {
  return /[\$%*?`]|\(|\)/.test(token) || /^(?:Join-Path|Resolve-Path|Get-Item|Get-ChildItem|Get-Location)\b/i.test(token);
}

/** Split a command tail into quoted and bare tokens. */
function tokenize(text) {
  const tokens = [];
  const re = /"([^"]*)"|'([^']*)'|([^\s]+)/g;
  let m;
  while ((m = re.exec(text)) !== null) tokens.push(m[1] ?? m[2] ?? m[3]);
  return tokens;
}

/** True for a CLI flag token (keeps `C:\...` drive paths as values). */
function isFlag(token) {
  if (/^[A-Za-z]:/.test(token) || /^[A-Za-z]:\\/.test(token)) return false;
  return /^[-/][A-Za-z]/.test(token) || /^--?[A-Za-z]/.test(token);
}

/** Remove flags from a token list, preserving order. */
function values(tokens) {
  return tokens.filter((token) => !isFlag(token));
}

/** Cut a command string at the next pipeline/statement boundary. */
function commandTail(command, index) {
  let tail = command.slice(index);
  const cut = tail.search(/[;&|\n]|\|\|/);
  if (cut >= 0) tail = tail.slice(0, cut);
  return tail.trim().replace(/^(?:\.exe)?\s*/i, '');
}

/** Extract the deletion targets for one matched verb. */
function extractTargets(mode, tail) {
  const tokens = tokenize(tail);
  if (mode === 'robocopy') {
    // Positional arguments: SOURCE DIR DEST DIR [FILES...]; /MIR deletes inside DEST.
    const positional = values(tokens);
    if (positional.length < 2) return { targets: [], unresolved: true };
    return { targets: [positional[1]], unresolved: isUnresolvedToken(positional[1]) };
  }
  const positional = values(tokens);
  if (positional.length === 0) return { targets: [], unresolved: true };
  const targets = positional.filter((token) => token.trim().length > 0).slice(0, 4);
  return { targets, unresolved: targets.some(isUnresolvedToken) };
}

/**
 * Analyze a shell command string.
 * @param {string} command
 * @param {{protectedPaths?: string[], allowedRoots?: string[]}} settings
 * @returns {{hits: Array<object>, dryRun: boolean, bulk: boolean}}
 */
export function analyzeCommand(command, settings = {}) {
  const protectedPaths = settings.protectedPaths ?? DEFAULT_PROTECTED_PATHS;
  const allowedRoots = settings.allowedRoots ?? [];
  const hits = [];
  if (typeof command !== 'string' || command.trim() === '') return { hits, dryRun: false, bulk: false };

  const dryRun = DRY_RUN.test(command);

  for (const verb of VERBS) {
    const match = verb.re.exec(command);
    if (!match) continue;
    const verbStart = match.index;
    const tail = commandTail(command, verbStart + match[0].length);
    const recursive = verb.recursive(tail) || verb.recursive(match[0]);
    if (!recursive && !DRY_RUN.test(command)) {
      // Single-object deletion stays out of the gate; still report as a low hit.
      hits.push({ rule: verb.id, verb: verb.label, recursive: false, level: 'low', targets: [], unresolved: false });
      continue;
    }
    const extracted = extractTargets(verb.targetMode, tail);
    const wildcard = /\*|\?/.test(tail);
    let level = 'safe';
    let why = '';
    let matchedTarget = '';
    for (const target of extracted.targets) {
      const classified = isProtectedPath(target, protectedPaths);
      if (classified?.level === 'protected') {
        level = 'protected';
        why = classified.why;
        matchedTarget = target;
        break;
      }
      if (classified?.level === 'high' && level !== 'protected') {
        level = 'high';
        why = classified.why;
        matchedTarget = target;
      }
      if (allowedRoots.some((root) => {
        const r = normalizePath(root).toLowerCase();
        const t = normalizePath(target).toLowerCase();
        return r && (t === r || t.startsWith(r.endsWith('\\') ? r : r + '\\'));
      })) {
        level = 'allowed';
        matchedTarget = target;
      }
    }
    if (extracted.unresolved) level = level === 'protected' ? 'protected' : 'unresolved';
    if (wildcard && level === 'safe') level = 'unresolved';
    hits.push({
      rule: verb.id,
      verb: verb.label,
      recursive: true,
      bulk: wildcard,
      level,
      why,
      targets: extracted.targets,
      target: matchedTarget,
      unresolved: extracted.unresolved,
    });
  }

  const bulk = hits.some((hit) => hit.recursive);
  return { hits, dryRun, bulk };
}

/**
 * Analyze a PTC `run_code` program body for destructive effects the guard
 * cannot resolve to a concrete target.
 * @returns {{hits: Array<object>, dryRun: boolean, bulk: boolean}}
 */
export function analyzeCode(code, settings = {}) {
  const hits = [];
  if (typeof code !== 'string' || code.trim() === '') return { hits, dryRun: false, bulk: false };
  const dryRun = DRY_RUN.test(code);
  for (const pattern of CODE_PATTERNS) {
    if (pattern.re.test(code)) {
      hits.push({
        rule: pattern.id,
        verb: 'programmatic file/process operation',
        recursive: true,
        bulk: true,
        level: 'unresolved',
        why: 'the program body computes its own targets',
        targets: [],
        target: '',
        unresolved: true,
      });
    }
  }
  return { hits, dryRun, bulk: hits.length > 0 };
}

/**
 * Evaluate one tool execution from the `tools/pre-execute` waterfall.
 *
 * @param {{name: string, arguments?: object, callId?: string}} exec
 * @param object settings see `buildSettings` in index.js
 * @returns {{action: 'allow'|'ask'|'deny', reasons: string[], hits: object[], command?: string}}
 */
export function evaluateCall(exec, settings = {}) {
  const reasons = [];
  const args = exec?.arguments ?? {};
  const toolNames = settings.toolNames ?? new Set(['pwsh', 'bash', 'terminal', 'pwsh-persistent', 'bash-persistent']);
  const inspectCodeTools = settings.inspectCodeTools ?? new Set(['run_code']);
  const protectedPaths = settings.protectedPaths ?? DEFAULT_PROTECTED_PATHS;
  const allowedRoots = settings.allowedRoots ?? [];

  let analyzed = { hits: [], dryRun: false, bulk: false };
  let payload = '';

  if (typeof args.command === 'string' && (toolNames.has(exec?.name) || settings.inspectUnknownTools !== false)) {
    payload = args.command;
    analyzed = analyzeCommand(args.command, { protectedPaths, allowedRoots });
  } else if (typeof args.code === 'string' && inspectCodeTools.has(exec?.name)) {
    payload = args.code;
    analyzed = analyzeCode(args.code, settings);
  }

  const gated = analyzed.hits.filter((hit) => hit.recursive && !analyzed.dryRun);
  if (gated.length === 0) {
    return { action: 'allow', reasons, hits: [], command: payload.slice(0, 200) };
  }

  const protectedHit = gated.find((hit) => hit.level === 'protected');
  const highHit = gated.find((hit) => hit.level === 'high');
  const unresolvedHit = gated.find((hit) => hit.level === 'unresolved');
  const allowedHit = gated.find((hit) => hit.level === 'allowed');
  const safeHit = gated.find((hit) => hit.level === 'safe');

  let action = 'allow';
  if (protectedHit) {
    action = settings.protectAction === 'ask' ? 'ask' : 'deny';
    reasons.push(
      `${protectedHit.verb} targets a protected path (${protectedHit.why})` +
        (protectedHit.target ? `: ${protectedHit.target}` : ''),
    );
  } else if (highHit) {
    action = 'ask';
    reasons.push(`${highHit.verb} targets a high-risk path (${highHit.why}): ${highHit.target}`);
  } else if (unresolvedHit) {
    action = settings.unresolvedAction === 'deny' ? 'deny' : 'ask';
    reasons.push(`${unresolvedHit.verb} has a target this guard cannot resolve safely (variables, wildcards, pipeline, or program code)`);
  } else if (allowedHit) {
    action = 'allow';
    reasons.push(`${allowedHit.verb} targets an allowed root: ${allowedHit.target}`);
  } else if (safeHit) {
    action = settings.mode === 'audit' ? 'allow' : settings.mode === 'deny' ? 'deny' : 'ask';
    reasons.push(
      `${safeHit.verb} is recursive/bulk and targets ${safeHit.target || 'a literal path'}; ` +
        'approve only if that absolute path is exactly what you intend',
    );
  }

  if (action !== 'allow' && analyzed.dryRun) action = 'allow';

  return { action, reasons, hits: gated, command: payload.slice(0, 200) };
}
