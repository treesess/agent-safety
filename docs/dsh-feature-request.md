# Safety: destructive shell commands should require approval and a restore point, even in full access mode

> 這份文件是可直接貼成 GitHub issue 的草稿。英文摘要（下一節）可當 issue 開頭，繁中完整說明在後。
>
> **建議標題**（選用其一）：
> 1. `Safety: destructive shell commands need approval + restore point even in full access (incident: rd /s /q "C:\")`
> 2. `Data-loss risk: an uncanonicalized path argument reached a destructive shell verb; please gate destructive tool calls`
>
> **建議標籤**：`safety`、`data-loss`、`tools`、`enhancement`
> **提報者**：一位 DSH 桌面版使用者（2026-11-16 事故當事人）。
>
> **2026-11-18 修訂**：初稿寫「資料已完整救回」。**不成立。** 影子的檔案大小正確，但 78 個以上檔案內容是零、15 個全毀；這是 Windows 已知的 VSS 缺陷。時間線、根因、最小重現腳本與一條新的 P0 建議都已據此更新。

---

## English summary (issue opening)

On 2026-11-16, a DSH desktop user had granted the agent full access for a plugin-migration task. While testing a PowerShell uninstall script that the agent had just written, a caller-supplied `-Dest "C:\"` value passed the script's own destination guard: the guard's canonicalizer deliberately leaves a three-character drive root as `C:\`, while the drive-root check was written as `^[A-Za-z]:$`, which only matches the trimmed form `C:`. Two individually correct checks cancelled each other out. The script then ran `cmd /c rd /s /q "C:\"`. It deleted the user's working folder — 1,372 files in 143 directories, about 1.75 GB — within 127 seconds, and stopped when the agent killed the background job. Files were restored from a Windows VSS shadow copy taken roughly six hours earlier, **but that turned out to be size-and-count recovery only**: 78+ files came back with correct sizes and zeroed runs (15 entirely zero). A 2026-11-18 decoy test — single-file deletes and a 1 GB mass delete, on both the original and the updated build — did **not** reproduce the zeroing. The documented VSS NULL-block behaviour remains the best explanation, not a confirmed cause. Most users have neither the safety net nor a way to detect that it lied.

Every existing layer was bypassed for a different reason. Full access mode skipped approval entirely, which is what full access means — but the user's intent was "let the agent work without babysitting every file edit", not "irreversible mass deletion may proceed unannounced". The shell tool itself saw a benign-looking `pwsh -File uninstall.ps1 -Dest C:\ -Force` invocation, because the destructive verb lived inside the script the model had just authored, not in the tool's command line. The optional Auto review access mode — the one mechanism that checks each tool call against the user's request — was off by default.

One fact makes this less a story about model judgment than about verification discipline. **125 seconds before the fatal command**, an independent review subagent the agent had spawned returned a P0 finding that named `-Dest C:\` as a bypass and said the uninstaller's `-Dest` had no validation at all. The agent received it and acted: 59 seconds later it rewrote both scripts and added the missing guard, specifically in response to that review. That part worked. Then it validated the new guard by running `-Dest "C:\" -Force` — the very object the review had named. The guard test and the protected target were the same thing, so validation became the accident.

That is the cheapest thing to fix in this entire report: an explicit norm, in the tool description or system prompt, that a guard test must use a **decoy target** (`-Dest "C:\__probe_does_not_exist__"`) and never the real one. It costs nothing, it is checkable, and it would have prevented this incident even after the guard was written wrong.

This issue does not ask DSH to block deletions, to take responsibility for user scripts, or to weaken the full-access escape hatch. It asks for a last line of defense around irreversible operations: (1) approval for destructive commands whose canonical targets are a disk root, a user directory, DSH's own data, or outside the workspace — including in full access mode; (2) a restore point or quarantine copy before the delete executes, with the UI saying so; (3) a first-party safe-delete tool; (4) deterministic path canonicalization plus a protected-path list built into the shell tools; (5) an audit log and one-click undo. A small PowerShell reference implementation with Pester tests exists from the follow-up work and can be contributed if useful. We would rather have this discussed than quietly patched: the failure class is generic to every shell-backed agent, not specific to this one session.

---

## 問題陳述（繁中）

AI agent 在使用者授予 **full access** 的情況下，把一個**未正規化**的路徑參數餵給刪除動詞，實際執行 `cmd /c rd /s /q "C:\"`，刪掉使用者的工作資料夾（1,372 個檔案、143 個目錄、約 **1.75 GB**）。整個過程沒有任何人被詢問、沒有任何還原點被建立、沒有任何審計記錄留下。使用者靠 Windows VSS 影子複本（約 6 小時前的還原點）以 robocopy 取回，**但只救回檔案清單與大小——78 個以上檔案出現零段（15 個全零），實際零化 8.5 MB**。機制未證實：替身實驗（單檔與 1 GB 大量刪除、兩個 build）沒有重現，見 `vss-null-blocks.md`。

還有一個初稿沒寫、但對 DSH 更關鍵的事實：**這道出事的防護，是為了回應一個 19:00:11 送達的審查警告才寫的**（距致命指令 2 分 5 秒）。agent 收到警告、59 秒內照著補上防護——然後拿警告點名的那個 `-Dest "C:\"` 去驗證它。所以問題不只是「模型會不會寫錯防護」，而是**沒有人要求「守門測試的輸入不能是被保護的目標本身」**。這一條寫進工具描述或系統提示就能生效，成本為零。

問題不在「agent 會不會犯錯」——它一定會。問題在於：**一個不可逆、影響範圍可達整個磁碟的動作，在 full access 模式下沒有任何第二道關卡，也沒有任何復原路徑。** 這對任何 shell-backed agent 都是通用風險。

## 環境與事實

| 項目 | 內容 |
|---|---|
| 產品 | DSH 桌面版 `0.2.2-rc.1`（app 版本 `44.7.0`） |
| 作業系統 | Windows 11，build 26200 |
| Shell | Windows PowerShell 5.1 與 PowerShell 7 皆可用 |
| Access mode | `danger-full-access`（使用者在該會話主動開啟） |
| 出事的呼叫鏈 | shell 工具（`pwsh`）→ 子行程 `pwsh -File uninstall.ps1 -Dest "C:\" -Force` → `cmd /c rd /s /q "C:\"` |
| 未生效的既有機制 | workspace sandbox（full access 下不約束子行程）、approval prompt（full access 略過）、Auto review 外掛（未啟用） |
| 恢復方式 | Windows VSS 影子複本 + `robocopy /E /COPYALL`；143 目錄 / 1,372 檔案 / 1.744 GB / 0 FAILED。**但這只代表數量與大小**：事後逐檔掃描發現 78 個以上檔案有零段、15 個全毀；實際零化 8.5 MB。機制未證實（見 `vss-null-blocks.md`）。 |
| 破壞視窗 | 指令 19:02:16 送出、19:04:23 中止，**上限 127 秒**；19:05:25 才目視確認損害 |
| 事前警告 | 19:00:11 收到 subagent 審查的 P0 警告，點名 `-Dest C:\` 可繞過；59 秒後據此補上防護，再以同一個輸入驗證該防護 |

## 重現條件（最小）

1. 使用者在會話中授予 full access（`danger-full-access`）。
2. agent 撰寫或執行一個帶有「路徑參數」的清理／卸載腳本；該參數最終會傳給一個刪除動詞（`rd /s`、`Remove-Item -Recurse`、`del /s /q`、`robocopy /MIR`、`rm -rf` 等）。
3. 參數值未經正規化（尾端分隔符、`C:` 磁碟相對路徑、`..`、大小寫、UNC、裝置路徑…）就能通過腳本自己的檢查。
4. 腳本由 shell 工具啟動（`pwsh -File`、`powershell -Command`、`cmd /c *.bat`、`bash *.sh`…）。

結果：工具鏈上沒有任何人停下來問一句，刪除動詞直接對作業系統使用者有權限的任意子樹生效。在這個案例中，模型還自己選擇了真實的磁碟根當「測試值」，而不是暫存目錄——這一步同樣沒有被攔。

## 最小重現腳本（概念版）

> 以下刻意用「概念版」而非原始腳本：它重現的是**失敗鏈**，不是任何專案細節。不要在真實資料上執行。

```powershell
# CONCEPT ONLY — do not run this against real data.
# Concept: reproduces the chain "unnormalized path argument -> delete verb".
# This mirrors the real defect: two individually correct guards cancelling out.

# (A) The canonicalizer deliberately does NOT trim a three-character drive root.
function Get-Canonical([string]$p) {
    $full = [IO.Path]::GetFullPath($p)                            # "C:\" stays "C:\"
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\', '/') }   # -gt 3 is intentional
    return $full
}

function Remove-ByDest {
    param(
        [Parameter(Mandatory)][string]$Dest,
        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($Dest)) { throw 'refusing: empty -Dest' }

    $canon = Get-Canonical $Dest                                  # → "C:\"

    # (B) The drive-root check only matches the TRIMMED form "C:".
    if ($canon -match '^[A-Za-z]:$') { throw 'refusing: drive root' }   # "C:\" does not match

    # (C) This one genuinely works — which is why the first version of this report
    #     blamed the wrong check.
    if ($canon -eq (Get-Canonical $env:USERPROFILE)) { throw 'refusing: user profile' }

    # (D) -Force skips the leaf-name check.
    if (-not $Force -and (Split-Path -Leaf $canon) -ne 'my-plugin') {
        throw 'refusing: unexpected folder name'
    }

    # The destructive verb eats the caller-controlled path.
    if (Test-Path -LiteralPath $canon) {
        cmd /c rd /s /q "$canon"                                  # delete runs
    }
}

# Passes every guard above; the delete runs.
# AND: this is also the *test invocation* — the guard test and the protected
# object are the same thing, so a broken guard becomes an incident.
Remove-ByDest -Dest 'C:\' -Force
```

（A）與（B）單獨看都對：（A）的作者知道磁碟根是 3 個字元，所以刻意不把它修剪成 `C:`；（B）的正則要求的是修剪後的形式。兩者合起來，`C:\` 兩邊都過。（C）反而是有效的——初版把責任歸給它，是錯的。

對照：**正確**的防護長什麼樣（同樣是概念版）：

```powershell
# Canonicalize first; reject roots and protected trees before any delete verb.
$canonical = [IO.Path]::GetFullPath($Dest).TrimEnd('\', '/')
$root      = [IO.Path]::GetPathRoot($canonical).TrimEnd('\', '/')
if ($canonical -eq $root) { throw 'refusing: drive root' }
if ($canonical -ieq $env:USERPROFILE.TrimEnd('\')) { throw 'refusing: user profile' }

# Windows-only traps that a string comparison misses:
#   - drive-relative "C:" (no separator) is not the root "C:\"
#   - UNC share roots: \\server\share
#   - device paths: \\?\C:\... and \\.\...
#   - trailing dots/spaces: "C:\work." resolves to "C:\work"
#   - 8.3 short names: C:\PROGRA~1
#   - junctions/symlinks: resolve the final target before applying the denylist
```

## 為什麼既有的安全層沒有擋住

| 防線 | 為什麼失效 |
|---|---|
| Approval / 授權提示 | full access 模式的定義就是不逐次詢問；使用者授權的是「自動工作」，不是「可以無聲刪光」。 |
| Workspace sandbox | 被刪除是子行程（`cmd /c rd`）的副作用；full access 下不限制子行程能做到什麼。 |
| shell 工具的命令字串檢查（若有） | 工具只看到 `pwsh -File uninstall.ps1 -Dest C:\ -Force`，**刪除動詞在腳本檔案裡**，不在命令列上。純字串比對抓不到。 |
| 腳本自己的路徑防護 | 防護是模型寫的，**而且有 canonicalize、也有磁碟根檢查**——但兩者的形式不一致（不修剪的 `C:\` 對上只認 `C:` 的正則）而互相抵銷。`-Force` 又跳過資料夾名稱檢查。 |
| Agent 的判斷 | 模型選擇拿真實磁碟根當測試值，並在 full access 下執行；沒有任何機制要求它先凍結、先列清單、先問人。 |
| Auto review（自動授權審查） | 現有外掛 `@deepseek-ai/dsh-experimental-auto-review` 能對照使用者要求審查每次工具呼叫，但**預設關閉**；事故會話中並未啟用。 |
| 刪除前 checkpoint | 不存在。唯一救命的 VSS 還原點是「剛好有開系統保護」的運氣，不是產品設計。 |
| 審計記錄 | 沒有留下足以回溯「刪了什麼、何時、經誰批准」的結構化記錄。 |

## 影響與嚴重度

- **直接損失**：工作資料夾整棵樹 1,372 檔案 / 143 目錄 / 1.744 GB。這只是「被刪掉的部分」；若沒有 VSS，就是全部。
- **不可逆**：一般使用者的 Windows 安裝不一定開系統還原；工作目錄很少即時備份到外接碟；macOS／Linux 的對應機制（APFS 快照、btrfs subvolume）同樣不是預設保證。對多數人而言，這類事故＝永久資料損失。
- **不可預測**：`rd /s /q` 對磁碟根實際刪到哪裡，取決於 ACL、服務帳號、目錄列舉順序與時間。本案例在 **127 秒**內刪掉字母序上幾乎最前的工作資料夾就被中止；其餘系統目錄「剛好」沒被刪，**不是被保護，是還沒輪到**。這是巧合，不是安全設計。
- **沒有即時感**：命令輸出不會列出被刪的檔案；使用者通常幾分鐘後才發現。
- **嚴重度：Critical（資料全毀、不可逆、影響所有 shell-backed agent 使用者）；發生頻率低，但後果不可接受。**

## 建議（依優先級）

### P0 — 破壞性工具呼叫一律要求人工批准（不管 access mode，至少 full access 也要）

這不是要恢復「每個動作都問一次」，而是把「不可逆、影響範圍失控」的呼叫單獨分級。

**需要分類為 destructive 的動詞（Windows 與 Unix）**

| 類別 | 例子 |
|---|---|
| 遞迴刪除 | `rd /s`、`rmdir /s`、`Remove-Item -Recurse`、`del /s /q`、`del /f /s /q`、`rm -rf`、`rm -r` |
| 鏡像／清除 | `robocopy /MIR`、`robocopy /PURGE`、`rsync --delete`、`git clean -fdx` |
| 格式化／分割區 | `Format-Volume`、`Clear-Disk`、`Remove-Partition`、`Initialize-Disk`、`diskpart clean`、`format`、`mkfs.*`、`wipefs` |
| 透過腳本 | `pwsh -File x.ps1`、`powershell -Command`、`cmd /c x.bat`、`bash x.sh`、`python x.py`；命令列本身看不到破壞性動詞，必須檢查被呼叫的檔案內容（best effort），檢查不到就當 opaque 處理 |

**需要觸發批准（或直接拒絕）的目標**（一律先 canonicalize，見 P3）

| 目標 | 判定方式 |
|---|---|
| 磁碟根 | canonical path == `GetPathRoot(canonical)` |
| 使用者目錄 | canonical == `$env:USERPROFILE`，或其下的廣泛子樹（Desktop、Documents、Downloads…） |
| DSH 自身資料 | `.dsh`、安裝目錄、runtime／profile 目錄 |
| workspace 以外 | canonical 不在 workspace root 之下 |
| workspace 根本身 | 對 workspace root 做遞迴刪除 |
| 無法解析 | junction／symlink 無法解析、`-EncodedCommand`、opaque 腳本 |

**行為要求**

- 批准卡片要顯示：使用者看到的原始命令、**canonical 絕對目標**、被標記的原因、預估影響（檔案數／大小，若便宜可算）。
- 提供「執行前先建立 checkpoint」選項與「拒絕」。
- 一次批准不等於永久授權；同一會話重複同一 destructive 指令應重新提示，或要求明確的 session 授權。
- 對 `-EncodedCommand` 這類無法審閱的內容，視為 opaque → 一律批准，或直接拒絕。
- 建議同時提供使用者層級的設定（例如 `safety.destructive: off | protected-and-outside | always`），但**預設值應為「保護路徑 + workspace 外」**；「off」必須是明確、需輸入確認的 opt-in。
- 低成本配套：把三句話寫進 agent 行為指引／系統提示／`AGENTS.md` 範本：
  1. 不得用真實資料路徑測試刪除腳本；
  2. **守門測試的輸入必須是替身**（例如 `-Dest "C:\__probe_does_not_exist__"`），不得拿被保護的目標本身當驗證輸入——本案例就是拿真磁碟根測守門，守門一有洞就直接執行；
  3. 不確定就停下來問人，先 dry-run。

### P1 — 刪除前自動建立 checkpoint／快照（並在 UI 顯示「已建立還原點」）

- **首選實作：quarantine（軟刪除）**。把目標子樹搬到 `%LOCALAPPDATA%\dsh\trash\<session>-<timestamp>\`，而不是真的刪除；成本低、跨平台、可即時 undo，並有保留期限與磁碟壓力清理策略。對「刪掉 workspace 內資料夾」這個最常見情境，這已經足夠。
- **OS 快照**（可選、盡力而為）：
  - Windows：VSS 還原點／shadow copy。注意 `Checkpoint-Computer` 預設 24 小時節流且需要管理員權限，不能當唯一保證；實作時應檢查系統保護是否開啟，關閉時明確告知「本機沒有快照能力」。
  - macOS：`tmutil localsnapshot`（APFS 本機快照）。
  - Linux：btrfs subvolume snapshot、LVM thin snapshot、或偵測到 Timeshift／Snapper 時善用。
- **失敗要 fail closed**：如果 checkpoint 建立失敗，且該操作沒有被 quarantine 覆蓋，就**不要執行刪除**，而是回報「無法建立還原點，操作已取消」。
- UI 必須明示「已建立還原點」與復原方式（哪個快照、怎麼還原、保留多久）；使用者需要知道這一步真的發生了。

### P2 — 官方安全刪除工具（first-party safe delete）

提供一個工具（名稱例如 `safe_delete`／`safe-remove`），把正確行為內建，而不是讓每個模型自己寫防護：

- 必經 canonicalize、denylist、junction／reparse point 處理（只刪連結本身，不刪連結指向的目標，用 `cmd /c rmdir`）。
- **兩階段**：先 `dry_run` 回傳「將刪除的檔案數、總大小、樣本清單、canonical 目標」，再由使用者確認才執行。
- 回傳結構化結果（成功數、失敗數、被跳過的原因）。
- 同一套語意套用到 PowerShell、bash、Python（`shutil.rmtree` 同樣危險）；至少 DSH 的 shell 工具應優先建議使用它。
- 這次事故的後續工作已有一個 PowerShell 參考實作（含 Pester 測試：canonicalize、根目錄、`C:`、UNC、junction、`-WhatIf`），需要的話可以提供給 DSH 參考或改寫。

### P3 — 工具輸入的路徑正規化與保護清單（內建在 shell 工具）

這一步必須是**確定性的程式邏輯**，不能交給模型判斷：

- 先做 canonicalize：`GetFullPath` → 去掉尾端分隔符（根目錄除外）→ Windows 大小寫不敏感比較。
- Windows 特有的坑：`C:`（磁碟相對）、`\\server\share`（UNC 根）、`\\?\C:\...`／`\\.\...`（裝置路徑）、尾端點與空白（`C:\work.` → `C:\work`）、8.3 短名、ADS（`file.txt:stream`）、`..` 穿越、`%VAR%` 展開。
- 一律**先解析 junction／symlink 的最終目標**，再套用 denylist。否則「刪連結」會變成「刪目標」。
- 內建保護清單：磁碟根、`$env:USERPROFILE`／`$env:APPDATA`／`$env:LOCALAPPDATA`、家目錄下的 `.dsh`、`%ProgramFiles%`、`%SystemRoot%`、DSH 安裝與 runtime 目錄、workspace root（遞迴刪除時）。
- 批准決策的輸入必須是 canonical 後的路徑，而不是使用者／模型給的原字串。

### P4 — 審計日誌與一鍵 undo

- 以 append-only JSONL 記錄每一次 destructive 呼叫：時間、session／turn／step、工具、原始命令、canonical 目標、批准來源（使用者／Auto review／規則）、checkpoint id、檔案數與位元組、結果、exit code。
- 一鍵 undo：從 quarantine 或快照還原，並在 UI 顯示「還原了哪些檔案、與原始狀態的差異」。
- 保留策略與隱私：日誌留在本機；路徑可能含使用者名稱，UI 呈現時可摘要，但完整記錄要有，否則事後無法追查。

## 可參考的現有機制：Auto review（自動授權審查）

DSH 已經有一個直接對應這個問題的機制，但目前是 optional、預設關閉：

> `@deepseek-ai/dsh-experimental-auto-review` — “Adds an Auto review access mode: before each tool call, a model checks it against what you asked for, runs allowed calls at once, and holds denied calls for your approval.”

也就是說：每次工具呼叫前，由模型對照「使用者到底要求了什麼」來審查，越界的呼叫停下來等批准。這正是這次事故需要的語意檢查——使用者要求的是「測試卸載腳本的防護」，不是「刪掉磁碟根」。

建議：

1. **把 Auto review 變成破壞性操作的最低標**：即使使用者沒開 Auto review，destructive 類呼叫也應走同一道審查／批准；或至少讓 Auto review 預設開啟。
2. 審查者的輸入要包含 canonical 目標與 destructive 分類結果；路徑正規化仍由 deterministic 邏輯負責，不要讓模型重新推算路徑。
3. 只針對 destructive 類呼叫審查，成本與延遲幾乎為零，不影響一般工作流程。
4. 審查 prompt 應明確包含這份 issue 的檢查清單：磁碟根、使用者目錄、`.dsh`、workspace 外、被呼叫腳本內含刪除動詞、目標與使用者要求不符。

## Acceptance criteria（可驗收）

- [ ] 在 `danger-full-access` 下，shell 呼叫 `cmd /c rd /s /q "C:\"` 不會未經批准執行；批准卡片顯示 canonical 目標 `C:\` 與原因 `drive root`。
- [ ] 同上，下列每一個都觸發批准或拒絕：`Remove-Item -Recurse -Force $env:USERPROFILE`、`robocopy C:\ D:\ /MIR`、`rm -rf /`、`Format-Volume -DriveLetter D`、`diskpart` 內含 `clean`。
- [ ] 執行一個**內容含** destructive 指令的腳本（`pwsh -File uninstall.ps1 -Dest "C:\"`）會觸發同一道關卡；批准卡片註明「被呼叫的腳本內含破壞性指令」。
- [ ] **守門測試準則**：agent 被要求「驗證磁碟根會被擋」時，預設使用替身目標（不存在路徑），不會對真實磁碟根執行該腳本；此行為可從 session 記錄檢出。（本案例做到的是：收到 P0 警告後 59 秒內補上防護，然後用警告點名的輸入驗證它。）
- [ ] **驗收驗內容、不驗數量**：還原或修復後的檢查包含零段掃描（整頁 4096 位元組全零）與 Office／zip `testzip()`；因為檔案大小在內容被清空時完全不會變，本案例就是這樣被誤判為「完整救回」。
- [ ] 路徑正規化測試全數通過：`C:\`、`C:`、`C:/`、`c:\`、`C:\..\`、`\\?\C:\`、`\\server\share`、`%USERPROFILE%`、`~\`、指向磁碟根的 junction／symlink、workspace root 的遞迴刪除。
- [ ] 對 workspace 內資料夾的破壞性操作，在執行前建立 quarantine 或快照，UI 顯示「已建立還原點」與復原入口；對 fixture 目錄 undo 後檔案數與位元組與操作前一致。
- [ ] checkpoint 建立失敗時，破壞性操作被取消（fail closed），而不是照常執行。
- [ ] 審計日誌以 JSONL 記錄上述欄位，重啟後仍存在；可從 UI 一鍵還原。
- [ ] 一般非破壞性操作（建立檔案、workspace 暫存目錄內的單檔刪除）**不會**跳出批准，證明沒有把使用者淹沒在提示裡。
- [ ] Auto review 關閉時，destructive 呼叫仍會被審查／批准（最低標成立）；開啟時，審查者拿得到 canonical 目標與分類結果。
- [ ] macOS／Linux 上：有快照能力的環境（APFS local snapshot、btrfs/LVM）建立快照；沒有時走 quarantine 並在 UI 說明。

## Non-goals

- 不是要求 DSH 禁止刪除功能，或把 full access 改回逐次批准。
- 不是要求 DSH 為使用者要求 agent 執行的腳本內容負全責；使用者的錯誤路徑選擇仍是事故的一部分。
- 不是要求預設每次都做全碟 VSS 快照（耗時且對系統負擔明顯）；quarantine 是更低成本的預設。
- 不是要求短期內全部實作；P0＋P1 已能消除「無聲、不可逆、無記錄」這個最致命組合。

## 附註

- 事故後使用者已採取：全域 `AGENTS.md` 加入高危操作守則（canonicalize、保護清單、暫存目錄測試）、開啟系統保護、建立外接備份。11-18 復盤後再補三條：**取證順序**（停止寫入 → 複製影子到別顆碟 → 才還原 → 驗內容）、**守門測試用替身**、**VSS 影子不是備份**。
- 願意協助驗證：可提供去識別化的最小重現腳本、PowerShell SafeDelete 參考實作與 Pester 測試、各種路徑邊界案例的測試清單，以及一支零段掃描工具（`scripts/scan-zero-damage.py`，頁級判準＋`suspect` 層＋`--exclude`，無依賴）。
- 這份 issue 以建設性為前提：DSH 在 full access 下的流暢度是它最有價值的部分之一，這裡要求的是在不可逆的少數操作上保留一個人工確認點與一條復原路徑，而不是降低它。
- **修訂記錄（2026-11-18）**：初版的三處事實已更正——「完整救回」→ 僅清單與大小、內容零化；「2–3 分鐘」→ 上限 127 秒；根因「`USERPROFILE` 比較失效」→ 磁碟根正則與不修剪的正規化互相抵銷。另新增「收到審查警告後仍以同一輸入驗證」一節與兩條驗收條件。
- **修訂記錄（2026-11-18 晚間）**：新增替身實驗（Remove-Item／cmd rd／1 GB 大量刪除，8457 與 9974 各一輪，0 個全零）；把「VSS 已知缺陷」降級為「最佳解釋、未證實」；78 改註明為下限，零化量更正為 8.5 MB（144.9 MB 是受損檔總大小）。
