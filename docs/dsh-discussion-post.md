# 可直接貼上的 DSH Discussion 草稿

> 目錄：`deepseek-ai/deepseek-harness` → **Discussions → New discussion**
> 分類：若有「Bug Reports／缺陷回報」選它；沒有的話選「Ideas」。
> 這個 repo **關閉了 Issues**（`has_issues: false`），只能用 Discussions 回報。
>
> 建議標題（選一個）：
> 1. `[Data loss] Unnormalized path argument + full access ran rd /s /q "C:\" and deleted 1.75 GB — please gate destructive tool calls`
> 2. `[缺陷] 路徑參數未正規化 + full access → 執行 rd /s /q "C:\"，刪掉 1.75 GB 工作資料`
>
> 內文先用英文（repo 主要語言），最後附繁中摘要；整段貼上即可。

> ---
>
> **2026-11-18 追記：本文已發佈於 GitHub（discussion #13528）。以下內文是發佈當時的版本，不要修改它——其中兩處已被推翻：**
>
> 1. 「Everything was recovered … verified byte-for-byte」**不成立**。影子複本回傳 NULL 區塊，78 個以上檔案大小正確但內容全零（見 `vss-null-blocks.md`）。
> 2. 根因寫成「`GetFullPath` 保留尾端分隔符，導致使用者目錄比較永遠不成立」**不準確**。那道比較其實有效；真正失效的是磁碟根檢查 `^[A-Za-z]:$` 與「不修剪 3 字元磁碟根」的正規化互相抵銷。
>
> 追加更正請貼 `dsh-discussion-update-20261118.md` 的內容。

---

## English

**TL;DR** — In `danger-full-access`, a `pwsh` tool call ran a script whose path argument
(`-Dest "C:\"`) passed its own guards unnormalized, and the script executed
`cmd /c rd /s /q "C:\"`. It deleted 1.75 GB / 1,372 files of my working folder before I
killed it. I recovered everything from a VSS shadow copy taken 6 hours earlier — most users
do not have that safety net. DSH 0.2.2-rc.1 (app 44.7.0), Windows 11.

**What happened (2 minutes, 4 facts)**

1. The tool call itself looked benign: `pwsh -File uninstall.ps1 -Dest "C:\" -Force`.
   The destructive verb lived inside the script, not on the tool's command line.
2. The script's own guard compared `[IO.Path]::GetFullPath("C:\")` (→ `C:\`, trailing
   separator kept) against the user profile — it can never match, so the drive root passed;
   a `-Force` flag then skipped the last leaf-name check.
3. `rd /s /q "C:\"` ran for 2–3 minutes; the shell tool had no reason to stop it, the
   sandbox had no say (full access), and the approval layer is `never` under this preset —
   no one was asked, nothing was logged, no restore point was created.
4. Recovery: `vssadmin list shadows` → mounted `HarddiskVolumeShadowCopy23` (6 h earlier) →
   `robocopy /E /COPYALL` restored 143 dirs / 1,372 files / 1.744 GB, verified byte-for-byte.

**Why every existing layer was bypassed**

| Layer | Why it did nothing |
|---|---|
| Approval prompts | `danger-full-access` preset = approval policy `never`; not asked, by design |
| Filesystem sandbox | It constrains file *effects*, not command semantics; full access bypasses it entirely |
| Shell tool command inspection | The tool saw a benign `pwsh -File script.ps1`; the delete verb was inside the script |
| Auto review (optional plugin) | Ships switched off; it was off in this session |
| Script's own guard | Model-written; missed canonicalization, drive root, and `-Force` skipped the last check |

**What I built (all MIT, public):** <https://github.com/treesess/agent-safety>

- `safedelete/` — PowerShell module: canonicalize + protected-path denylist + junction-safe
  delete + command-line scanner; 76 tests (the incident command is rejected with
  `DriveRoot`).
- `dsh-guard/` — a DSH **host plugin** prototype that hooks `tools/pre-execute`
  (`@deepseek-ai/dsh-tools/lib/pipeline.js:386`) and answers `deny` / `ask` for destructive
  shell commands; 27 tests + a real-Cordis 4.1 integration check; still a parameter-level
  speed bump, not a sandbox.
- `docs/` — feasibility study with file/line evidence, incident review, and a concrete
  feature request (acceptance criteria included).

**Proposal — what would actually prevent this in DSH itself**

1. **P0 — gate destructive tool calls, even in full access.** Detect recursive-delete verbs
   (`rd /s`, `rmdir /s`, `Remove-Item -Recurse`, `del /s /q`, `rm -rf`) and mirror/format
   verbs (`robocopy /MIR`, `Format-Volume`, `diskpart clean`); canonicalize the target; if
   it is a drive root, the user profile, `.dsh`, the install/runtime dirs, or outside the
   workspace → require approval (or deny with a clear reason). Also scan called script files
   when the command is `pwsh -File` / `cmd /c *.bat`, and treat unparsable commands as
   risky.
2. **P1 — a restore point before irreversible deletes.** Cheapest option: quarantine (move
   to a trash dir) instead of delete; optionally a VSS/APFS/shadow snapshot. If the
   checkpoint fails, fail closed — do not delete.
3. **P2 — make the review layer a default for this class.** You already ship
   `@deepseek-ai/dsh-experimental-auto-review` (a model checks each call against the request
   and holds denied calls for approval). For destructive calls it should not be optional,
   or at least should be on by default with a deterministic pre-filter.
4. **P3 — a first-party `safe_delete` tool** so the model has a safe path instead of
   hand-writing `rd /s /q`.

The full write-up with acceptance criteria and non-goals is in
[`docs/dsh-feature-request.md`](https://github.com/treesess/agent-safety/blob/main/docs/dsh-feature-request.md);
the interception feasibility study is in
[`docs/dsh-guard-feasibility.md`](https://github.com/treesess/agent-safety/blob/main/docs/dsh-guard-feasibility.md)
(it documents `tools/pre-execute` behaviour, the `ask`→`deny` behaviour under `never`, and
scope handling — all read from the 0.2.2-rc.1 asar).

I am happy to turn any of this into a PR (e.g. a deterministic pre-filter + quarantine
hook), or to keep it as a third-party plugin if you prefer to keep core minimal. The one
thing I would ask: **please do not let "full access" mean "no approval for irreversible
mass deletion"** — that is the gap this incident walked through.

---

## 繁中摘要

在 `danger-full-access` 下，`pwsh` 工具執行了一支腳本，腳本的路徑參數（`-Dest "C:\"`）
未經正規化就通過自己的防護，接著執行 `cmd /c rd /s /q "C:\"`，刪掉我 1.75 GB / 1,372 個
檔案的工作資料夾；靠 6 小時前的 VSS 影子複本完整救回。多數使用者沒有這種安全網。

既有的每一層都失效了：full access 的 approval policy 是 `never`（不會問）；沙箱只管
檔案效果、full access 直接繞過；shell 工具只看到 `pwsh -File script.ps1`，刪除動詞在
腳本裡；Auto review 預設關閉；腳本自己的防護是模型寫的，漏了 canonicalize 與磁碟根。

我做了 MIT 授權的公開 repo（<https://github.com/treesess/agent-safety>）：
SafeDelete（PowerShell 模組，76 測試）、dsh-guard（DSH host plugin 原型，掛
`tools/pre-execute`，27 測試＋真 Cordis 整合）、以及含檔案行號證據的可行性研究與
feature request。

建議（優先級）：① 破壞性工具呼叫一律要求批准（即使 full access），目標為磁碟根／使用者
目錄／`.dsh`／workspace 外時尤其；② 刪除前先建立可還原點（quarantine 最便宜），失敗就
fail closed；③ 把 Auto review 變成這類呼叫的最低標；④ 提供官方 `safe_delete` 工具。
我可以配合改為 PR。
