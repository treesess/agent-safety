# Agent Safety Kit

> After an AI coding agent deleted 1.75 GB of a user's working folder with
> `cmd /c rd /s /q "C:\"`, this repository collects what we built so it does not
> happen again — to us or to anyone else.

On 2026-11-16 a desktop AI agent (DeepSeek Harness, full-access mode) was testing an
uninstall script it had just written. A `-Dest "C:\"` argument slipped through the
script's own path guards (the canonicalization missed the drive root), and the script
ran `cmd /c rd /s /q "C:\"`. It deleted ~1.75 GB / 1,372 files before being killed.
Everything was recovered from a Windows VSS shadow copy taken six hours earlier.
Most users do not have that safety net, so the failure class deserves more than luck.

This repository contains three independent layers of defence and one write-up:

| Folder | What it is |
|---|---|
| [`safedelete/`](safedelete/) | A PowerShell 5.1+ module that canonicalizes and validates paths **before** any delete/mirror, handles junctions safely, and scans command lines for destructive verbs. 8 exported functions, **76 tests**. |
| [`dsh-guard/`](dsh-guard/) | A DeepSeek Harness **host plugin** prototype that hooks `tools/pre-execute` and answers `deny` / `ask` for destructive shell commands before they run. Includes a pure rule engine and tests. |
| [`docs/`](docs/) | The incident review (Traditional Chinese), a concrete feature request for the agent runtime, a feasibility study of tool-call interception, and safety notes for users and agents. |

## Quick start

### SafeDelete (PowerShell)

```powershell
Import-Module .\safedelete\SafeDelete\SafeDelete.psd1

# Never feed a raw argument to a delete verb:
Assert-SafePath -Path $Dest -ExpectedLeafName 'my-tool' | Out-Null

# Or use the guarded wrapper (WhatIf/Confirm built in):
Remove-SafeItem -Path "$env:TEMP\scratch" -WhatIf

# Scan a command line before running it:
Test-DangerousCommandLine 'cmd /c rd /s /q "C:\"'
```

Run the tests:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\safedelete\tests\run-tests.ps1
```

### dsh-guard (DeepSeek Harness plugin)

Read [`dsh-guard/README.md`](dsh-guard/README.md) for installation (GUI Plugins page or a
manual `link:` dependency) and the five safe acceptance checks. Run its unit tests with
any Node.js 20+:

```powershell
cd dsh-guard
node --test --test-isolation=none test/rules.test.mjs test/contract.test.mjs
```

## The one rule that would have prevented this

```powershell
# WRONG: GetFullPath("C:\") returns "C:\" (trailing separator kept),
# so the comparison can never match a user profile — and the delete runs.
if ([IO.Path]::GetFullPath($Dest) -eq [IO.Path]::GetFullPath($env:USERPROFILE)) { throw }

# RIGHT: canonicalize, trim the separator, compare against the drive root too.
$canonical = [IO.Path]::GetFullPath($Dest).TrimEnd('\', '/')
if ($canonical -eq [IO.Path]::GetPathRoot($canonical).TrimEnd('\', '/')) { throw 'drive root' }
if ($canonical -ieq $env:USERPROFILE.TrimEnd('\')) { throw 'user profile' }
```

## Safety rules for AI-agent users

1. Keep `danger-full-access` for short, supervised bursts; work in `workspace-write`.
2. Enable the agent's own review layer (e.g. DeepSeek Harness "Auto review") if available.
3. Never test a destructive script against a real path — use `%TEMP%` and fixtures.
4. Turn on Windows System Protection / snapshots and know how to restore from them.
5. Keep an offline backup of your working roots (see `docs/agent-safety-notes.md`).
6. Put the canonicalize-and-deny rules in the agent's global instruction file.
7. Install a first-party or third-party guard plugin only from source you can read — host
   plugins run with the agent's full privileges.

## Limitations (read before trusting anything here)

- The plugin is a **speed bump, not a sandbox**. Commands assembled from variables,
  destructive logic inside `.ps1`/`.py` files, external programs, or direct Node file APIs
  from code-execution tools can bypass text rules.
- In `danger-full-access` the runtime's approval policy is `never`, so an `ask` decision
  becomes a deny without anyone being prompted. The guard detects that and reports an
  explicit deny message instead of a misleading "user rejected".
- SafeDelete cannot know that `D:\important` matters to you. Use `-AllowedRoot` allowlists
  in real scripts.
- Both codebases target Windows / PowerShell 5.1 (SafeDelete) and DeepSeek Harness
  `0.2.2-rc.1` (dsh-guard). APIs change; re-verify after upgrades.

## License

MIT — see [`LICENSE`](LICENSE).
