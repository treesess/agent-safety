# dsh-guard — DSH 的破壞性指令守門插件（原型）

一個 **DSH host plugin**，在工具呼叫「執行前」檢查 shell 命令字串；遇到
遞迴／大量刪除、`robocopy /MIR`、磁碟格式化、陰影複本刪除等操作時：

- 目標是**受保護路徑**（磁碟根目錄、使用者目錄、`.dsh`、`C:\work`、系統目錄…）
  → `deny`：**直接阻止，工具本體不會執行**。
- 目標是普通路徑的遞迴刪除 → `ask`：**要求使用者批准**（走 DSH 既有 approvals UI）。
- 目標無法靜態解析（變數、萬用字元、pipeline、`run_code` 程式內操作）→ `ask`。
- 一般讀取、單一檔案刪除、`-WhatIf`／`/L` dry-run → 直接放行。

> 研究結論與證據（為什麼可行、限制在哪）：`../docs/dsh-guard-feasibility.md`。
> 本目錄只放檔案與說明，**不安裝、不改任何 profile**；安裝由使用者自己執行。

## 機制（為什麼能擋在執行前）

DSH 的工具管線是固定的五段（`@deepseek-ai/dsh-tools`）：

```
tools/pre-execute（可擴充 waterfall，回傳 allow / deny / ask）
  → 已註冊的 monotonic guards
  → tools/execute（包住真正的工具本體；時間到這裡才可能呼叫 shell）
  → tools/post-execute → tools/result
```

本插件只做第一段：`ctx.on('tools/pre-execute', async (exec, next) => …)`。
回傳 `{ kind: 'deny', reason }` 就不會執行；回傳 `{ kind: 'ask', reason,
displayReason }` 會由 DSH 的 `approval` 服務向使用者要一次批准，批准後指令
「原樣」執行。詳見 `../docs/dsh-guard-feasibility.md` 的檔案＋行號證據。

## 檔案

| 路徑 | 用途 |
|---|---|
| `plugin/package.json` | plugin 套件宣告（`dsh.bundle.patch` 指向 profile 層） |
| `plugin/cordis.patch.yml` | profile 層插入的設定（預設值都在這裡） |
| `plugin/index.js` | plugin 進入點：掛 `tools/pre-execute`、audit、組 decision |
| `plugin/rules.js` | 純函式規則引擎（無相依、可單獨測試） |
| `plugin/test/rules.test.mjs` | 規則單元測試（node:test） |
| `plugin/test/contract.test.mjs` | 依管線契約模擬 waterfall 的插件測試 |
| `tools/verify-cordis.mjs` | 用真的 Cordis 4.1 + `dsh-scope` 載具跑整合驗證 |
| `tools/asar-extract.mjs` | 從 `app.asar` 抽出驗證所需的 4 個套件（只讀 asar、只寫本目錄） |
| `tools/README.md` | 重現離線整合驗證的步驟 |

## 安裝（兩種方式，先備份）

安裝前先備份 profile 的三個檔案（複製成 `.bak` 即可）：

```
C:\Users\user\.dsh\profiles\desktop\package.json
C:\Users\user\.dsh\profiles\desktop\cordis.patch.yml
C:\Users\user\.dsh\profiles\desktop\pnpm-lock.yaml
```

> 為什麼不用 `dsh plugin --profile desktop add`：Desktop profile 由 Electron
> 應用程式專屬管理，CLI 會回 `error: profile "desktop" is managed exclusively by
> the Electron application`。所以用下面 A 或 B。

### A. 從 GUI 的 Plugins 頁安裝（建議先試）

DSH 桌面版的 sidebar → **Plugins** 頁支援安裝外部 bundle；`plugin_manager`
的 `inspect(spec)` 接受**絕對路徑**（讀該路徑的 `package.json`）。把
`C:\work\agent-safety\dsh-guard\plugin` 這個資料夾當成 bundle 安裝，
它宣告了 `dsh.bundle.patch`，安裝後會自動接到 profile 層。安裝後**重啟整個
DSH 桌面版**（不是只關視窗）。

### B. 手動加 link 依賴（本機已驗證過的同型做法：`@local/dsh-tts`）

1. 編輯 `C:\Users\user\.dsh\profiles\desktop\package.json`：

   ```json
   "dependencies": {
     "@local/dsh-guard": "link:C:/work/agent-safety/dsh-guard/plugin",
     ...
   },
   "dsh": {
     "profile": {
       "bundles": [
         "@deepseek-ai/dsh-base",
         "@deepseek-ai/dsh-web-app",
         ...,
         "@local/dsh-guard"
       ]
     }
   }
   ```

   `link:` 路徑用正斜線，並且**不要**移動 `dsh-guard` 資料夾（link 是活的）。

2. 在 profile 目錄跑內建 pnpm 更新 node_modules：

   ```powershell
   $node = 'C:\Users\user\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'
   $pnpm = 'C:\Users\user\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\pnpm\bin\pnpm.cjs'
   & $node $pnpm install
   ```

   （在 `C:\Users\user\.dsh\profiles\desktop` 目錄下執行。若網路不可用而失敗，
   先確認 npm registry 可用；link 依賴本身不需下載。）

3. **完全結束** DSH 桌面版再啟動（profile 層在開機時合成）。

### 停用／移除

- 快速停用：在 GUI Plugins 頁把 `dsh-guard` 關掉，或把 `package.json` 的
  `bundles` 拿掉 `@local/dsh-guard`，重啟。
- 完全移除：拿掉 `bundles` 與 `dependencies` 兩處、重跑上面的 `pnpm install`、
  重啟。三個 `.bak` 檔可原樣還原。
- 本插件不寫 profile、不寫 `.dsh`（預設只寫 `%TEMP%\dsh-guard\audit.jsonl`），
  移除時不需要清 profile 以外的东西。

## 載入後的驗證（照做即可）

階段 1–2 不需要安裝、不會碰到 DSH；階段 3 才需要安裝。**全部用假路徑或
`%TEMP%`，不要拿真實資料路徑測試。**

### 1. 規則單元測試（在 `dsh-guard/plugin/`）

```powershell
node --test --test-isolation=none test/rules.test.mjs test/contract.test.mjs
```

預期：`pass 27 / fail 0`。DSH 內建 runtime 的 Node 24.21.0 也可跑（本機已用
`...\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe` 驗證）。

### 2. 真 Cordis 整合驗證（在 `guard/tools/`，可選但建議）

依 `tools/README.md` 從 `app.asar` 抽出 4 個 DSH 內部套件到
`tools/node_modules/`，再跑：

```powershell
node verify-cordis.mjs
```

它用 **真的 Cordis 4.1.0**（DSH 0.2.2-rc.1 內建版本）mount 這個 plugin，透過
與 DSH 相同的 `scopeTarget(...)` 載具派發 `tools/pre-execute`，並檢查
plugin 卸載後 listener 會消失。預期：7 個 case 全 PASS。

### 3. 安裝後在 app 裡的驗證

> 先在 **workspace-write 權限模式**（approval policy = `ask`）驗證，才看得到
> 批准提示；`danger-full-access` 模式的 approval policy 是 `never`，`ask` 會
> 直接被判 deny（見下面「行為語義」）。

| # | 動作 | 預期 |
|---|---|---|
| 1 | 叫 agent 跑 `Get-ChildItem $env:TEMP` | 正常執行（allow） |
| 2 | 建一個假目錄：`New-Item -ItemType Directory $env:TEMP\dsh-guard-e2e`，然後叫 agent 跑 `Remove-Item -Recurse -Force "$env:TEMP\dsh-guard-e2e"` | 跳出**批准**提示；拒絕就不執行 |
| 3 | 叫 agent 跑 `Remove-Item -Recurse -Force "C:\work\__dsh_guard_probe_does_not_exist__"` | **直接被擋**（deny），錯誤訊息含 `dsh-guard blocked`；因為路徑不存在，即使萬一沒擋也只會報錯，不會刪資料 |
| 4 | 檢查 audit：`Get-Content "$env:TEMP\dsh-guard\audit.jsonl" -Tail 5` | 看得到第 2、3 步的 `action` |
| 5 | 叫 agent 跑 `Remove-Item -Recurse -Force "C:\work\__dsh_guard_probe_does_not_exist__" -WhatIf` | 放行（dry-run）——證明規則不是無腦全擋 |

若第 2、3 步沒有預期行為，先確認 plugin 真的有載入：GUI Plugins 頁應該看得到
`dsh-guard`；開機 log 會有 `dsh-guard: active (...)`。

## 設定（`cordis.patch.yml`）

| 欄位 | 預設 | 說明 |
|---|---|---|
| `mode` | `ask` | 一般遞迴刪除的動作：`ask` 要批准、`deny` 直接擋、`audit` 只記錄 |
| `protectAction` | `deny` | 受保護路徑的動作：`deny` 或 `ask` |
| `unresolvedAction` | `ask` | 無法解析目標時的動作：`ask` 或 `deny` |
| `failClosed` | `true` | 規則引擎自己出錯時暫停呼叫（`false` = 放行） |
| `protectedPaths` | `["C:\\work"]` | 額外受保護的資料根（支援前綴子路徑） |
| `allowedRoots` | `[]` | 這些根底下的遞迴刪除直接放行（例：`["C:\\Temp"]`） |
| `auditPath` | `%TEMP%\dsh-guard\audit.jsonl` | audit 檔；`false` = 關閉 |
| `auditAllow` | `false` | 是否也記錄被放行的呼叫 |
| `toolNames` | `pwsh`,`bash`,`terminal`… | 要檢查 `command` 參數的工具名 |
| `inspectCodeTools` | `["run_code"]` | 要掃 `code` 參數的工具名 |
| `inspectUnknownTools` | `true` | 其他工具若也有 `command` 字串參數也檢查 |

`danger-full-access` 常用組合（不會有批准提示、但允許 temp 清理）：

```yaml
config:
  mode: deny
  allowedRoots: ['C:\\Temp']
```

## 行為語義（重要）

- **`ask` 不是保證有提示**：DSH 的 approvals 有 policy。`never` 政策（內建
  `danger-full-access` preset 就是）會直接把請求判 `rejected`；沒有 answerer
  時判 `unavailable`。本插件會先讀 `approval` 服務的有效政策，這兩種情況直接
  回 `deny` 並附明確理由（不會讓模型誤以為「使用者拒絕了」）。
- **fail-closed**：插件內部規則錯誤預設讓呼叫進入 `ask`（在 `never` 下即
  deny）。這是刻意的：寧可誤擋，不要誤放。
- **不改寫參數**：管線明文禁止 `tools/pre-execute` 改 `exec.arguments`（否則
  log/顯示會與實際執行不一致），所以本插件只能 allow/deny/ask，不會幫你把
  `rd /s /q C:\` 改寫成別的命令。
- **只看得到工具參數**：`pwsh`／`bash` 的 `command`、`run_code` 的 `code`。
  若命令是 `python cleanup.py`、`Start-Process ...`、或 PTC 程式直接呼叫 Node
  檔案 API，守門看不到它真正刪什麼。
- **受保護清單是「預設值」不是「完整清單」**：請把自己的資料根加進
  `protectedPaths`（本原型已預設 `C:\work`）。

## 已知限制（不影響「能用」，但影響「能靠它多安全」）

1. 文字規則可被繞過：變數展開、`iex`、Base64、`cmd /c` 嵌套、把命令寫進
   `.ps1`／`.bat` 再執行、用外部程式刪除。守門是**減速丘**，不是沙箱。
2. 只覆蓋「模型透過工具發出的刪除」；使用者自己在終端跑的東西不經 DSH。
3. 沒有內建檔案快照／VSS checkpoint；需要真正的還原能力請靠 Windows 系統
   保護或備份（DSH 的 `dsh-session-checkpoint-policy` 只保證 session log
   耐久，不做檔案快照）。
4. Plugin 在 host process 內以完整權限執行：安裝第三方 plugin 等於信任它的
   程式碼（本 plugin 只讀 args、寫 audit，不 spawn 任何程序）。
5. 尚未做「安裝進真 profile 後」的端到端實測（本次任務限制不能改 profile）；
   上面階段 1–2 已實測，階段 3 是給你的驗收步驟。

## 與其他交付物的關係

- `../safedelete/`：PowerShell 端的 `Assert-SafePath` / `Remove-SafeItem`，擋
  **腳本自己**的刪除路徑。兩者互補：SafeDelete 保護「你寫的腳本」，dsh-guard
  保護「agent 臨時下的命令」。
- `../docs/agent-safety-notes.md`：給使用者與 agent 的操作準則。
