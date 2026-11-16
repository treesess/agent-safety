# 討論串常見問題：預備回答

> 給 <https://github.com/deepseek-ai/deepseek-harness/discussions/13528> 用。
> 維護者或其他人問起時，直接複製對應答案即可；回答都刻意簡短、只講事實、附連結。
> 中文提示在最下面一節（回覆風格）。

---

## Q: "Did you know that `danger-full-access` disables approval prompts?"

**A:** "Yes — I enabled full access deliberately for a plugin-migration task, and I know it
means no per-edit prompts. My point is narrower: *no prompts for file edits* should not also
mean *no prompt for irreversibly deleting a drive root*. The intent was speed, not silent
mass deletion of the workspace."

## Q: "Why didn't Auto review catch it? It's an optional plugin."

**A:** "It was off in that session, which is part of the report: the one shipped mechanism
that checks tool calls against the request ships disabled, and nothing forces destructive
calls through it. Deterministic rules (drive root, user profile, `.dsh`, outside-workspace
targets) should be the floor even when Auto review is off — that's the P0 ask."

## Q: "The model wrote the script and tested it on a real path — isn't this the agent's (or your) mistake, not a DSH bug?"

**A:** "Both are true: I used a real path as the test value, and the model's guard missed
canonicalization. But 'an agent will eventually make a mistake' is a design assumption for a
product that gives agents shell access. The ask is a last line of defence around the small
set of irreversible operations — not for DSH to prevent every user error. Feel free to treat
this as defence-in-depth rather than blame allocation."

## Q: "What is the smallest change you'd ask for?"

**A:** "A deterministic pre-execute filter: if a shell command contains a recursive-delete,
mirror, or format verb and its canonical target is a drive root, `$env:USERPROFILE`, `.dsh`,
the install/runtime dirs, or outside the workspace → require approval (or deny with a clear
reason). That's a handful of rules with no LLM in the loop; everything else in the proposal is
optional."

## Q: "Can you share a minimal reproduction?"

**A:** "Yes. The failure chain is in the report
([`docs/dsh-feature-request.md`](dsh-feature-request.md), concept script
`Remove-ByDest -Dest 'C:\' -Force`), and the path matrix is in
[`../safedelete/tests`](../safedelete/tests). If useful I can post a fully sanitized `.ps1`
that reproduces only the guard failure; the delete line stays commented out so running it
deletes nothing."

## Q: "Would you open a PR?"

**A:** "Yes. I'd start with P0 + P1 — a deterministic pre-filter plus a quarantine-style
checkpoint — with tests against the path matrix (drive roots, `C:`, UNC, `\\?\`, junctions,
`$env:USERPROFILE`). I'd need a pointer to where the team wants the rules (a new package vs.
inside `dsh-tool-pwsh`), and I'd follow the repo's contribution conventions."

## Q: "Is `dsh-guard` safe to install? Host plugins run with full privileges."

**A:** "Correct, and I wouldn't install it blindly either. It is ~0 dependencies, does not
spawn processes, and writes nothing except an optional audit JSONL; the rules are pure
functions with tests. Still — host plugins run inside the app process, so read the source
before installing. The repo is public and the README says this explicitly."

## Q: "Why did VSS save it, and what about macOS/Linux?"

**A:** "Windows System Protection happened to be on. The equivalents — APFS local snapshots,
btrfs/LVM snapshots, Time Machine — are not guaranteed either. That's why the cheapest
mechanism in the proposal is quarantine (move the subtree to a trash directory) rather than
depending on OS snapshots."

## Q: "Is the tooling actually tested?"

**A:** "Yes: 76 PowerShell tests (path canonicalization, drive roots, junctions, long paths,
dangerous-command scanning) and 27 Node tests for the plugin rules plus a Cordis 4.1
integration check. The test output is committed at
[`../safedelete/tests/test-output.txt`](../safedelete/tests/test-output.txt)."

## Q: "Are you asking DSH to stop agents from running scripts?"

**A:** "No — scripts have to keep working. The ask is that when a script or command contains
an irreversible mass-delete verb aimed at a protected target, the runtime pauses once with a
clear reason and an option to create a restore point before executing."

## 回覆風格（給自己看）

- 先承認對方講對的部分，再補事實；不要爭「誰的錯」。
- 每次回覆附一個具體連結（repo 檔案／行號），不要重貼整篇。
- 如果維護者提出替代設計：說「我可以照這個方向改／測試」，比堅持原方案有效。
- 如果被要求縮小範圍：接受，先做 P0 最小版；後續再談 P1–P3。
- 不要催回覆；這個 repo 流量大，一兩週沒回應是常態。
