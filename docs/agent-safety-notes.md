# Agent 安全操作筆記（給使用者與 agent）

- 背景：2026-11-16 在 the machine 上，一個 AI agent（DSH）測試自製 `uninstall-pc1.ps1`
  時，`-Dest "C:\"` 沒被正規化擋下，腳本執行 `cmd /c rd /s /q "C:\"`，刪掉
  `C:\work` 整棵樹（數個專案…約 1.74 GB），靠
  Windows VSS 影子複本取回檔案清單與大小——但 78 個以上檔案出現零段（15 個全零；實際零化 8.5 MB）。機制未證實：替身實驗沒有重現（見 `vss-null-blocks.md`）。完整記錄：`../incident-review-public.md`。
- 本筆記的用途：把那次事故轉成「使用者怎麼設防線」與「agent 自己該怎麼做」的
  可執行守則。配套工具：`../dsh-guard/`（DSH 執行前守門插件）、
  `..\safedelete\`（PowerShell 安全刪除模組）。

---

## 1. 事故為什麼會發生（三個同時失效）

1. **路徑沒有 canonicalize**：防護只比對 `GetFullPath(...)` 的結果，`"C:\"`
   保留尾端 `\`，跟 `$env:USERPROFILE` 不同，所以通過所有檢查
   （`..\incident-20261116.md:22-28`）。
2. **`-Force` 跳過資料夾名稱檢查**：最後一層名稱必須符合預期的規則被繞過
   （同檔 `:26`）。
3. **執行環境沒有任何批准關卡**：事故在 **danger-full-access** 下發生；DSH 的
   `danger-full-access` preset 對應 approval policy = `never`
   （`dsh-base/cordis.patch.yml:274–276`），所以就算腳本或工具想「要求批准」，
   也只會被直接判拒絕——更糟的是，實際執行的是腳本自己的 `rd`，根本不經過
   任何守門。

還有一個關鍵事實：**VSS 影子複本救了這次**（事故前 6 小時的還原點，
`..\incident-20261116.md:38-42`）。沒有還原點就沒有這次的結局。

---

## 2. 給使用者的守則

### 2.1 環境設定（一次做完）

1. **不要讓 agent 長時間在 `danger-full-access` 跑。** 用 `workspace-write`
   就好；要動工作區外的東西時，逐次批准。full access 的 approval policy 是
   `never`，等於沒有最後一道人工關卡。
2. **確認 Windows「系統保護」開著、還原點密度夠。** 事故時影子儲存上限
   9.51 GB、已用 6.89 GB（`..\incident-20261116.md:40`），最新還原點只差約
   6 小時——這就是「刪光到救回」與「真的丟資料」的差別。定期
   `vssadmin list shadows /for=C:` 檢查。
3. **重要資料另外備份**（外接碟／雲端／另一台機器）。影子複本只覆蓋同一個
   磁碟區，而且會被新的寫入擠掉。
4. **安裝執行前守門**：DSH 裝 `../dsh-guard/`（見其 README），並把你真正的資料根
   加進 `protectedPaths`。它只擋得到「命令字串」層，所以是「多一道」，不是
   「唯一一道」。
5. **不要安裝來路不明的 plugin**：DSH 的 host plugin 在 app process 內以完整
   權限執行。

### 2.2 對 agent 下指令時

6. **不要把真實資料路徑餵給沒測過的刪除腳本／命令。** 要測，就在
   `%TEMP%` 建假資料，或先叫 agent 用 `-WhatIf`（PowerShell）跑一遍給你看。
7. **要求「先列目標、再刪」**：叫 agent 先跑
   `Get-ChildItem <目標> -Force | Select-Object -First 50 FullName` 確認目標，
   再執行刪除；對 `rd /s /q`、`robocopy /MIR`、`Remove-Item -Recurse`、
   `rm -rf` 這四種動詞提高警覺。
8. **要求 agent 在破壞性操作前說出「完整、正規化後的路徑」**，並且你親自
   核對一次。特別是尾端有 `\`、只有磁碟機代號、或路徑是變數組出來的。
9. **看到「刪除／大量覆寫」就先 checkpoint**：重要工作前手動建還原點或備份，
   或至少確認今天的還原點存在。**不要**在「剛好沒有還原點」的日子跑遷移／
   清理腳本。
10. **測試腳本 ≠ 正式執行**：遷移、卸載、清理腳本一律在「暫存目錄＋暫存
    profile」驗證過，才對真實環境執行（事故就是拿 `-Dest "C:\"` 當測試輸入）。

### 2.3 萬一刪掉了：VSS 救援摘要

事故當天實際用過的流程（管理員 PowerShell；完整記錄見
`..\incident-20261116.md:15-19`）：

```powershell
vssadmin list shadows /for=C:                      # 找事故前的影子複本
cmd /c mklink /D C:\vss-restore \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopyNN\
robocopy C:\vss-restore\work "C:\work" /E /COPYALL   # 只還原需要的子樹
# 核對檔案數／大小無誤後再移除連結：cmd /c rmdir C:\vss-restore
```

**先確認影子內容再覆蓋還原**；不要對整顆磁碟做還原。

---

## 3. 給 agent 的守則（写给會讀這份文件的 agent）

### 3.1 刪除／覆寫前必做

1. **Canonicalize 目標**：`[IO.Path]::GetFullPath($p).TrimEnd('\')`，再比對。
   直接比較字串（尤其含尾端 `\`、相對路徑、`~`、`$env:` 展開前後）不算。
2. **逐項拒絕**：磁碟根（`C:\`、`C:`、`/`、`\`）、`$env:USERPROFILE`、`.dsh`、
   系統目錄（`Windows`、`Program Files`、`ProgramData`）、執行中腳本自身
   目錄、以及使用者標記的資料根（本機為 `C:\work`）。
3. **不要把使用者輸入／命令列參數直接餵給** `Remove-Item -Recurse`、
   `rd /s /q`、`robocopy /MIR`、`rm -rf`。先過白名單／防護函式
   （用 `..\safedelete\` 的 `Assert-SafePath`）。
4. **路徑最後一層名稱要符合預期**（例如 `dsh-tts`）；不符合就停下來問。
5. **先列出再刪**：先 `Get-ChildItem` 給人看，確認數量與名稱；刪除時用
   `-WhatIf` 或先跑 dry-run（`robocopy /L`）。
6. **變數／pipeline／萬用字元組出的目標**：不要自信地執行；先展開成字面
   路徑給人確認。
7. **遇到 junction／reparse point**：只刪連結本身，用 `cmd /c rmdir`，
   不要讓 `Remove-Item -Recurse` 追進去。
8. **不確定就停**。停下來問人比事後救援便宜。

### 3.2 測試與示範

9. 測試刪除類腳本一律用 `%TEMP%` 的假資料；**禁止**拿真實資料路徑當測試輸入
   （事故就是把 `"C:\"` 當測試輸入）。
10. 示範「防護有效」時，用**不存在的受保護路徑**（例如
    `C:\work\__probe_does_not_exist__`），這樣即使防護失效也不會刪到東西。
11. 破壞性操作前先 checkpoint（還原點／備份），或先告知使用者「這一步不可逆、
    請先確認還原點」。

### 3.3 下命令時的習慣

12. 清空目錄不要用 `rd /s /q` 當預設；用「列出→逐項刪→確認」或安全模組。
13. `robocopy /MIR` 會**刪掉目標端多出來的檔案**；執行前確認「來源／目標」方向
    與目標端內容。備份應該用 `/E`（或確認 `/MIR` 的目標是專用備份碟）。
14. 不要把 `$HOME`／`$home`（PowerShell 自動變數，大小寫不敏感）當一般變數
    賦值；也不要對它做刪除。
15. 對 `cmd /c`、`iex`、`.ps1`／`.bat`、Base64 這類「命令包命令」的形式提高
    警覺——那是繞過字串檢查的常見方式，也是守門插件的盲區。

---

## 4. 可直接貼給 agent 的「破壞性操作前檢查清單」

```text
在執行任何刪除／大量覆寫前，逐項回答並貼出結果：
1. 完整命令（原文）與每個目標路徑的 GetFullPath + TrimEnd('\') 結果。
2. 目標是否為：磁碟根 / 使用者目錄 / .dsh / 系統目錄 / 專案資料根？若是，停止。
3. 目標路徑最後一層名稱是什麼？與預期相符嗎？
4. 先用 Get-ChildItem 列出前 50 個項目（或 robocopy /L）給我看。
5. 有沒有 -WhatIf / dry-run 的版本可以先跑？
6. 這一步可以復原嗎？還原點／備份存在嗎？
若以上任一項不確定：停下來，不要執行。
```

---

## 5. 「為什麼不能只靠模型自律」

模型（包括寫這份文件的 agent）會犯錯：事故中的腳本防護是「有寫但沒寫對」，
而且 agent 在 full access 下可以一次把錯誤命令送出去。**防線要放在模型之外**：

| 防線 | 擋什麼 | 什麼時候失效 |
|---|---|---|
| DSH 守門插件（`../dsh-guard/`） | 工具參數層的字面破壞性命令 | 命令用變數／外部程式組出；插件沒安裝 |
| DSH 權限模式（workspace-write + ask） | 工作區外的檔案效果 | 用 full access；approval 被關 |
| 安全刪除模組（`..\safedelete\`） | 自己寫的腳本的路徑錯誤 | 腳本沒用模組 |
| 檔案 ACL | 特定目錄被刪 | 需要設計、可能影響日常 |
| **VSS／備份** | **救回已發生的災難** | 沒有還原點／備份 |

最後一列是唯一在你「什麼都做錯」時還能救命的。**先確保它存在**，再談前面幾列。

---

## 6. 引用與延伸

- 事故完整記錄：`..\incident-20261116.md`（時間線、根因、VSS 救援）
- 高危操作守則（已加入全域 `~/.dsh/AGENTS.md`）：同檔 `:44-56`
- DSH 守門研究與證據：`dsh-guard-feasibility.md`
- DSH 守門原型安裝：`../dsh-guard/README.md`
- 安全刪除模組：`..\safedelete\README.md`（另一個交付物）
