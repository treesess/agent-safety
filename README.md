# Agent Safety Kit

> After an AI coding agent deleted 1.75 GB of a user's working folder with
> `cmd /c rd /s /q "C:\"`, this repository collects what we built so it does not
> happen again — to us or to anyone else.

On 2026-11-16 a desktop AI agent (DeepSeek Harness, full-access mode) was testing an
uninstall script it had just written. A `-Dest "C:\"` argument slipped through the
script's own path guards (the canonicalization missed the drive root), and the script
ran `cmd /c rd /s /q "C:\"`. It deleted ~1.75 GB / 1,372 files before being killed
127 seconds later.

The files were then restored from a Windows VSS shadow copy taken six hours earlier —
**and that turned out to be only half a rescue.** A 2026-11-18 review found that 78+
files came back with the correct size and entirely zeroed content. The shadow copies
themselves were handing back NULL blocks without a single error. See
[`docs/vss-null-blocks.md`](docs/vss-null-blocks.md).

Most users do not have even that half-net, so the failure class deserves more than luck.

> ### Update 2026-11-18: the original write-up was wrong in four places
>
> This repository's first version of the review said "everything was recovered,
> verified byte-for-byte". That conclusion was false. Corrections now applied to
> [`docs/incident-review-public.md`](docs/incident-review-public.md):
>
> 1. **Timeline.** The command was issued at 19:02:16 and killed at 19:04:23 — an
>    upper bound of 127 seconds, not "2–3 minutes". The damage was first seen at
>    19:05:25, not 19:07.
> 2. **Root cause.** Not "the `USERPROFILE` comparison failed". The user-profile check
>    worked. The failure was that `Get-Canonical` deliberately does not trim a 3-character
>    drive root, while the drive-root check was written as `^[A-Za-z]:$` — which only
>    matches the *trimmed* form. Two individually correct guards cancelled each other out.
> 3. **"Recovered."** File counts and byte totals matched exactly because the zeroed
>    files had the right size. Size and count cannot detect zeroed content.
> 4. **The uncomfortable one.** The guard existed *because of a warning*. An independent
>    review subagent delivered a P0 finding at 19:00:11 that named `-Dest C:\` as a
>    bypass; the agent wrote the guard 59 seconds later in response — and then validated
>    that guard by running it against `-Dest "C:\"` itself. The test input and the thing
>    being protected were the same object.


This repository contains three independent layers of defence and one write-up:

| Folder | What it is |
|---|---|
| [`safedelete/`](safedelete/) | A PowerShell 5.1+ module that canonicalizes and validates paths **before** any delete/mirror, handles junctions safely, and scans command lines for destructive verbs. 8 exported functions, **76 tests**. |
| [`dsh-guard/`](dsh-guard/) | A DeepSeek Harness **host plugin** prototype that hooks `tools/pre-execute` and answers `deny` / `ask` for destructive shell commands before they run. Includes a pure rule engine and tests. |
| [`docs/`](docs/) | The incident review (Traditional Chinese), a concrete feature request for the agent runtime, a feasibility study of tool-call interception, a write-up of the [VSS NULL-block defect](docs/vss-null-blocks.md), and safety notes for users and agents. |
| [`scripts/`](scripts/) | `scan-zero-damage.py` — detects zeroed file content by page alignment (two-tier `damaged` / `suspect`, `--exclude` for evidence folders). No dependencies. |

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

## …and the second rule: never test a guard against the real target

The 2026-11-18 review turned up something sharper than the regex bug. The guard was
written **because a review told the agent that `-Dest C:\` was a bypass** — and the
agent then verified the guard by running it with `-Dest "C:\"` itself.

```powershell
# WRONG: the test input *is* the thing you are trying to protect
.\uninstall.ps1 -Purge -Dest "C:\" -Force       # if the guard fails, you find out by losing everything

# RIGHT: test against a decoy that cannot matter
.\uninstall.ps1 -Purge -Dest "C:\__probe_does_not_exist__" -Force
```

A guard test and the protected target must be different objects. One character of
difference in the test string is the difference between a caught bug and 1.75 GB.

## Safety rules for AI-agent users

1. Keep `danger-full-access` for short, supervised bursts; work in `workspace-write`.
2. Enable the agent's own review layer (e.g. DeepSeek Harness "Auto review") if available.
3. Never test a destructive script against a real path — use `%TEMP%` and fixtures.
4. Turn on Windows System Protection / snapshots and know how to restore from them —
   **but do not treat a shadow copy as a backup.** It can return zero-filled blocks
   silently. Verify content (page-level zero scan, hashes, `testzip()`) and copy the
   shadow out to another disk *before* restoring over the live tree.
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
