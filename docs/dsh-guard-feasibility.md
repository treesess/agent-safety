# DSH 工具呼叫守門可行性研究

- 研究對象：DeepSeek Harness 桌面版 `0.2.2-rc.1`（app 44.7.0，Windows 11）
- 研究問題：**能不能在 DSH 這一層，於工具呼叫（特別是 shell 命令）執行前檢查參數並阻止／要求批准？**
- 證據來源：安裝目錄 `C:\Users\user\AppData\Local\Programs\DeepSeek Harness\resources\app.asar`
  內的原始碼與套件 README（以 `node` 解析 asar header 抽出，工具見
  `../dsh-guard/tools\asar-extract.mjs`）、profile `C:\Users\user\.dsh\profiles\desktop`、
  以及本機 CLI 實際輸出。文中「文件:行號」皆指 asar 內的實際行號。
- 對應原型：`../dsh-guard/`（`@local/dsh-guard` 插件）
- 撰寫日期：2026-11-16

---

## 1. 結論

**判定：部分可行（攔截機制本身可行；「靠 DSH 這層擋住所有危險 shell」不可行）。**

一句話：**可以**寫一個 DSH host plugin，掛在工具管線的 `tools/pre-execute`
事件上，在 shell 工具本體執行**之前**看到完整命令字串，並回傳 `deny`（直接
阻止）或 `ask`（要求使用者批准）；本機已用 DSH 內建的 Cordis 4.1.0 實測
原型可行。但這是**安裝後才生效的插件層防護**，不是 DSH 的預設能力，而且只能
看得到「模型送進工具參數的東西」，命令用變數組出來、寫進 `.ps1` 再執行、或
用外部程式刪除時看不到——所以它是**減速丘**，不是沙箱；要「出廠即安全」必須
DSH 核心預設加入規則，或使用者自己啟用官方（實驗性）Auto review。

給決策者的三句話：

1. **要不要做這個守門插件？值得做**：成本低（一個 host plugin，不改核心、不
   改 profile 結構），能精準擋掉 2026-11-16 事故那種「`rd /s /q "C:\"`」與
   「遞迴刪 `C:\work`」的字面命令，且可用 `ask` 接上既有審批 UI。
2. **不能只靠它**：它救不了「變數／外部程式／PTC 直接 Node 刪檔」；仍需
   Windows 還原點／備份作為最後防線，並建議不要長時間使用
   `danger-full-access` 權限模式。
3. **DSH 應該內建**：官方已有 `tools/pre-execute` 擴充點與 Auto review 先例，
   把「破壞性命令預設 ask、受保護路徑預設 deny」做成核心規則，比每個使用者
   自己裝插件可靠。

---

## 2. 盤點：DSH 有哪些擴充點

### 2.1 工具註冊與執行流程（`@deepseek-ai/dsh-tools`）

DSH 每個工具呼叫都走同一條固定管線，順序寫在套件 README 與實作裡：

```
tools/pre-execute（可擴充 waterfall：allow / deny / ask）
  → ctx.tools.guard() 註冊的 monotonic guards
  → tools/execute（around-dispatch 包裝：timeout/retry；工具本體在這之後才跑）
  → tools/post-execute（可替換/封鎖結果）
  → tools/result（唯讀觀察）
```

證據：

| 項目 | 位置 |
|---|---|
| 管線順序（README 明列五段） | `dsh-tools/README.md:112`、`:137` |
| pre-execute 派發 | `dsh-tools/lib/pipeline.js:386`：`this.ctx.waterfall(carrier, "tools/pre-execute", exec, () => Promise.resolve({ kind: "allow" }))` |
| `ask` 轉 approval | 同檔 `:387`（`gate.kind === "ask"` → `serviceAsk`） |
| `deny` 變成工具錯誤結果、本體不執行 | 同檔 `:402`、`:412`（`isError: true`）；決策 `:612–653` |
| tools/execute（工具本體唯一入口） | 同檔 `:492`：`waterfall(carrier, "tools/execute", …, () => this.dispatchToolBody(...))` |
| 參數在 policy 之前被快照並凍結 | 同檔 `:331`：`arguments: deepFreeze(detached)` |
| 正式的 monotonic guard | `dsh-tools/lib/index.js:649`（`guard()`）、`:657`（`checkGuards`）；README `:92` |
| **不能改寫參數** | `dsh-tools/README.md:197`：「`tools/pre-execute` deliberately cannot rewrite `exec.arguments`」 |
| 事件是「可擴充 waterfall」 | `dsh-tools/README.md:137`：`tools/pre-execute` is the reorderable allow/deny/ask gate |

**關鍵**：`tools/pre-execute` 的 listener 收到 `(exec, next)`，回傳值就是決策：

- 呼叫 `next()` → 繼續（最後是 `{ kind: 'allow' }`）
- 回 `{ kind: 'deny', reason }` → 呼叫被擋，工具本體永不執行
- 回 `{ kind: 'ask', reason?, displayReason? }` → 走 approval 服務，批准後
  「原樣」執行（`dsh-tools/lib/pipeline.js:608` 起 `serviceAsk`）
- 回 `{ kind: 'cancel' }` → 視為取消
- listener 拋錯 → `prepare()` 的 try/catch 把該次呼叫判為錯誤結果（fail closed）

`exec` 物件含 `name`、`arguments`（凍結的 JSON 快照）、`callId`、`agent`、
`toolSet`、`signal` 等（`pipeline.js:296–330` 區域）；`ask` 由
`approval.request({ agent, toolName, callId, reason, displayReason, signal })`
處理（`:608` 起）。

### 2.2 審批（approvals）

- 服務名 `approval`，套件 `@deepseek-ai/dsh-user-approval`；tools 管線用
  `ctx.get('approval')` 取得（`dsh-tools/lib/pipeline.js:610`）。
- 政策只有 `ask` / `never` 兩種（`dsh-user-approval/lib/index.js:37`）。`ask`
  會把請求丟給 `approval/request` waterfall 的 answerer（人類 UI 或機器
  answerer）；`never` **在派發前**就回 `rejected`（同檔 `:200`），沒有 answerer
  則回 `unavailable`（`:201`）。
- `ask` 沒有 answerer／agent 不存在 → `rejected` / `unavailable`，管線一律
  變成 deny（fail closed，`dsh-tools/lib/pipeline.js:612–653`）。README：
  「Missing or failed answerers return `unavailable`, so the action fails closed」
  （`dsh-user-approval/README.md:12`）。
- 內建權限 preset 直接決定政策（`dsh-base/cordis.patch.yml:264–276`）：
  `read-only` / `workspace-write` → `approval: ask`；**`danger-full-access` →
  `approval: never`**。本次事故用的就是這種模式——也就是說，事故當下「要求
  批准」這條路本來就不存在。

### 2.3 沙箱（sandbox）

- 沙箱只管**檔案效果**，而且是在 process token／ACL 層（Windows ACL
  restricted token）：`read-only` / `workspace-write` / `danger-full-access`
  （`dsh-sandbox/README.md:54–62`）。
- `danger-full-access` 明文「Bypasses confinement; the consumer spawns its
  original argv」（`dsh-sandbox/README.md:60`）——它不會解析命令字串。
- 沙箱詞彙「File effects are the whole policy vocabulary」（同檔 `:166`）：
  沒有 network/process/command 語意。所以「擋 `rd /s /q C:\`」不是沙箱的
  職責，也做不到（在 full access 下更沒有東西可擋）。
- 被擋時的升級流程（`sandbox_permissions` + `justification` → `ask`）證明
  DSH 的「執行前要求批准」基礎設施是完整可用的
  （`dsh-sandbox/README.md:64–70`、`dsh-tool-pwsh/README.md:65`）。

### 2.4 Plugin 系統（host／client）

- Host 插件就是 Cordis 4.1 plugin：套件 `exports` 出 `apply(ctx, config)`，
  profile 以 `dsh.profile.bundles` + bundle 自己的 `cordis.patch.yml` 分層合成
  （`profiles\desktop\package.json`、`profiles\desktop\cordis.yml`、
  `cordis.patch.yml`；官方範例 `@deepseek-ai/dsh-experimental-session-search`）。
- 既有第三方/自製 plugin 先例：`C:\work\project\plugins\dsh-tts`
  （`package.json` 的 `dsh.bundle.patch` + `export function apply(ctx)`）。
- 事件監聽：`ctx.on(名稱, listener)`（Cordis `src/events.ts:294–307`）；
  waterfall 的 listener 收 `...args, next`（`src/events.ts:246–261`）。
- **scoped 事件也能收到**：管線派發 pre-execute 時用的 carrier 是
  `scopeTarget(this.tools, exec.agent)`；`@deepseek-ai/dsh-scope` 的
  `scopeTarget` 明寫「admits untagged listeners globally」
  （`dsh-scope/lib/index.js:316–336`）。profile plugin 掛在 root、ctx 沒有
  scope tag，因此能收到所有 agent（含 subagent）的工具呼叫。
- **官方先例**：實驗性 Auto review 就是同一個位置做的：
  `dsh-experimental-auto-review/lib/index.js:565`
  `ctx.on("tools/pre-execute", async (exec, next) => …)`，並在 `:537–544`
  組出 `{ kind: 'ask', reason, displayReason }`、`:522–531` 組出 `deny`。這
  證明「第三方插件在執行前審查並要求批准」是官方支援的路徑。
- Client plugin（`client.js`）只負責 UI；批准對話框由
  `@deepseek-ai/dsh-client-ui-approval` 這類 client 套件呈現，但**能不能執行
  由 host 管線決定**，client plugin 不能代替 host 放行/阻止工具本體。
- Plugin 安裝路徑：GUI 的 Plugins 頁／`plugin_manager` 工具可安裝外部 bundle
  （`dsh-plugin-manager/README.md:31`、`:50`；`plugin_manager` 的動作本身也
  需要 full access 或批准）。Desktop profile 由 Electron app 專屬管理，CLI
  `dsh plugin --profile desktop …` 會被拒絕（本機實測：`error: profile
  "desktop" is managed exclusively by the Electron application`）。

### 2.5 Skill

Skill 是「可載入的指示／工具目錄」（`dsh-skill/README.md:12,28–33`），
`ctx.skills.register` / provider 只提供**內容**，不是執行攔截點
（同檔 `:50–56`）。Skill 可以寫「刪除前先檢查」，但那是模型自律，**沒有
強制力**，不能算守門機制。

### 2.6 現成的官方方案：Auto review（實驗性）

`@deepseek-ai/dsh-experimental-auto-review` 會在**每個工具呼叫前**用當前模型
審查風險，低風險放行、需要授權的呼叫改成 `ask`、高風險直接 deny
（`README.md:12,66`）。它：
- 出廠關閉（「The dsh installation ships this layer switched off」`README.md:12`），
  可由 Web Plugins 頁／`/permission` 選擇啟用；
- 是**模型判斷**，會誤判、每次呼叫多一次 LLM 請求（`README.md:105–109`）；
- 不提供檔案沙箱，PTC 程式內直接 Node 效果不在審查範圍
  （`README.md:135–137`）。

也就是說：**DSH 目前唯一「執行前審查工具呼叫」的官方功能，是機率式的、且
預設關閉；沒有內建的確定性危險命令守門。** 這正是本研究的切入點。

### 2.7 各層能力對照

| 層 | 執行前可攔？ | 看得到命令字串？ | 可阻止／要求批准？ | 備註 |
|---|---|---|---|---|
| `tools/pre-execute`（plugin） | ✅ 是 | ✅ `exec.arguments`（凍結快照） | ✅ `deny`／`ask` | 本原型所用；不能改參數 |
| `ctx.tools.guard()` | ✅ 是 | ✅ | ⚠️ 只能 deny（無 ask） | monotonic、晚於 pre-execute |
| `tools/post-execute` | ❌ 事後 | ✅（含結果） | ❌ 只能改/擋結果 | 太晚 |
| approval 政策／preset | ❌ 不是規則引擎 | ❌ | ✅（ask/never 開關） | `danger-full-access` = never |
| sandbox（ACL） | 執行中 | ❌（不解析命令） | ✅ 只限檔案效果 | full access 下無效 |
| Auto review（實驗） | ✅ 是 | ✅ | ✅（模型判斷） | 預設關閉、機率式 |
| skill | ❌ | ❌ | ❌（只有指示） | 無強制力 |
| client plugin | ❌ | ❌ | ❌（只渲染 UI） | host 才有執行權 |
| 改 DSH 核心 | ✅ 是 | ✅ | ✅ | 唯一能「出廠預設安全」的路 |

---

## 3. 對 shell 命令做檢查：可行性的具體判斷

### 3.1 模型下的 `pwsh` 命令長什麼樣

Windows 桌面 profile 掛的是 `@deepseek-ai/dsh-tool-pwsh`（`dsh-base/cordis.patch.yml:285–287`；
`dsh-tool-bash` 在 win32 被 disable，`:281–283`）。工具名 `pwsh`，參數包含
`command`（PowerShell 字串）、`description`、`timeoutMs`、`workdir`、
`run_in_background`、`sandbox_permissions`、`justification`
（`dsh-tool-pwsh/lib/index.js:466–500`）。執行方式是 `pwsh -Command <command>`
（README `:57`），本體組 spec 後交給 `ctx.shell`（`lib/index.js:631–645`）。

所以守門要檢查的字串就是 **`exec.arguments.command`**，在
`tools/pre-execute` 階段**完整存在**，且尚未 spawn 任何 process。這就是
「執行前檢查參數」在技術上成立的原因。

### 3.2 PTC（`run_code`）的情況

PTC 模式把工具呼叫包進程式：`run_code` 參數是 `code` + `description`
（`dsh-tool-executor-ptc/README.md:95`）。程式內呼叫工具會**重用同一條
invocation pipeline**（同檔 `:52`），所以程式內 `tools.pwsh({...})` 的**內層
呼叫也會經過 `tools/pre-execute`**，守門看得到。但程式可以直接 import Node
檔案 API 繞過內層工具——官方 Auto review 文件也承認「direct Node effects in PTC
remain outside it」（`dsh-experimental-auto-review/README.md:56,135`）。因此
原型同時掃 `run_code.code` 內的破壞性 API 字樣，把無法解析目標的呼叫升為
`ask`，並在限制清單中明列這個盲區。

### 3.3 審批在事故模式下會怎樣

`danger-full-access` preset 的 approval policy 是 `never`
（`dsh-base/cordis.patch.yml:274–276`），`never` 在請求送達 answerer 前就回
`rejected`（`dsh-user-approval/lib/index.js:200`），管線把它變成 deny、訊息是
「the user rejected tool …」。也就是說：**在事故那種模式下，`ask` 其實等於
deny、而且不會有人被詢問。** 原型因此先讀 `approval.effectivePolicy(session)`
／`approval.config.policy`（同檔 `:177–178,91–99`），若政策是 `never`（或沒有
agent/approval 服務）就直接回**明確的 deny 訊息**，避免誤導模型以為使用者拒絕。
若使用者切到 `workspace-write`（`ask`），才會看到真正的批准提示。

### 3.4 可行性小結

- **可攔截的**：工具參數中的命令字串（`pwsh` / `bash`），包含 `rd /s /q`、
  `Remove-Item -Recurse`、`robocopy /MIR`、`rm -rf`、`format` 等；可在執行前
  判 deny／ask。PTC 內層工具呼叫同樣可攔。
- **攔不到／不可靠的**：變數／`iex`／Base64／`cmd /c` 嵌套拼出的命令、寫在
  `.ps1`／`.bat` 再執行、`python cleanup.py` 之類外部程式的內部刪除、PTC 直接
  Node 檔案 API。文字比對永遠可以繞過。
- **不能做的**：在 plugin 層「改寫」命令（管線明文禁止，`README.md:197`）；
  也不能保證使用者一定看到提示（policy = never 時不會有）。
- **唯一能「預設就安全」的**：DSH 核心內建同樣的 pre-execute 規則，或把
  Auto review 的 deterministic 子集變成預設。

---

## 4. 建議方案（優先級）

| 優先級 | 方案 | 成本 | 效果 | 備註 |
|---|---|---|---|---|
| **P0** | 不要長時間用 `danger-full-access`；工作用 `workspace-write`（approval = ask） | 0 | 高 | 事故模式正是 full access + never；見 `dsh-base/cordis.patch.yml:274–276` |
| **P1** | 安裝本原型 `@local/dsh-guard`（見 `../dsh-guard/README.md`） | 低（一個 plugin） | 中高：擋字面破壞性命令；可 ask/deny | 不改核心；本機以真 Cordis 驗證 |
| **P2** | 啟用官方 Auto review（實驗性，GUI Plugins 頁或 `/permission`） | 中（每呼叫一次 LLM） | 中：補文字規則的盲區，但會誤判 | 與 P1 互補；`README.md:12,105–109,135–137` |
| **P2.5** | 用 OS 層兜底：Windows 系統保護／還原點、定期備份、VSS | 中 | 高（災難復原） | 事故就是靠 VSS 救回；見 `agent-safety-notes.md` |
| **P3** | 重要資料根加檔案 ACL（deny delete） | 中高（可能影響日常工作） | 高 | 要逐案設計，不建議全域套用 |
| **P4** | 對 DSH 開發者提案內建（見第 7 節） | — | 最高（出廠即安全） | 治本 |

原型單獨的定位：**P1「減速丘」**，不是 P4 的替代品。若只能做一件事，選 P0+P2.5
（不開 full access＋確保可還原）；若能安裝 plugin，P1 明顯值得。

---

## 5. 原型與驗證

### 5.1 原型內容

`../dsh-guard/`：`@local/dsh-guard` host plugin（ESM、零相依、不 spawn 程序）：

- `rules.js`：純函式規則引擎。破壞性動詞（`rd/rmdir /s`、`Remove-Item
  -Recurse`、`rm -rf`、`robocopy /MIR|/PURGE|/MOVE`、`del /s`、`git clean
  -fdx`、`format`、`vssadmin delete shadows`、`reg delete`）＋目標正規化與
  受保護判定（磁碟根、`\`、`$env:USERPROFILE`／`~`、`.dsh`、
  `protectedPaths`（預設含 `C:\work`）、Windows/Program Files/ProgramData…）。
  無法解析的目標（`$var`、`*`、pipeline、`run_code` code）→ 升為 `ask`。
  單一檔案刪除、`-WhatIf`／`/L` dry-run → 放行。
- `index.js`：`ctx.on('tools/pre-execute', async (exec, next) => …)`；`deny`
  直接阻止、`ask` 走 approval；`never` 政策時轉明確 deny；audit JSONL；規則
  例外時 fail closed；不做任何檔案操作。
- 設定（`cordis.patch.yml`）：`mode`、`protectAction`、`unresolvedAction`、
  `failClosed`、`protectedPaths`、`allowedRoots`、`auditPath` 等。

### 5.2 已實際跑過的驗證

| 驗證 | 方式 | 結果 |
|---|---|---|
| 規則＋插件契約 | `node --test --test-isolation=none test/rules.test.mjs test/contract.test.mjs` | **27/27 pass**（Node 26.13.0 與 DSH runtime Node 24.21.0 皆過） |
| 真 Cordis 整合 | `guard\tools\`：從 asar 抽 `cordis`/`dsh-scope`/`cosmokit`/`@standard-schema/spec`，用 **Cordis 4.1.0** mount plugin，以 `scopeTarget(...)` 載具派發 `tools/pre-execute` | **7/7 case PASS**，含：根目錄遞迴刪除 → deny；保護路徑 → deny；普通讀取 → allow；scratch 遞迴刪 → ask；PTC code → ask；unmount 後 listener 消失；`never` 政策下 ask 轉 deny |
| 端到端（裝進真 profile） | **未執行** | 本任務限制不得修改 `.dsh` profile；`guard\README.md` 提供安裝後 5 步安全驗收（含一條「受保護路徑但不存在」的 deny 測試，不會刪到任何東西） |

限制說明：以上驗證證明「插件掛得上、事件收得到、決策詞彙正確、卸載會移除
listener」，但沒有在活的 DSH app 裡實際觸發一次 `ask` 對話框（需要安裝＋重啟）。
這是本次唯一未實測的環節。

---

## 6. 風險與限制（實作／部署）

| 風險 | 說明 | 緩解 |
|---|---|---|
| 文字規則可繞過 | 變數、`iex`、Base64、`cmd /c` 嵌套、`.ps1`／`.bat`、外部程式 | 規則只當減速丘；搭配 Auto review／還原點；不要把「已裝 guard」當免死金牌 |
| 盲區：外部程式刪除 | 命令是 `python cleanup.py` 時守門只看得到字串 | 可擴充規則（`python|node|bash` 腳本名 → ask）；最終仍靠沙箱／備份 |
| 盲區：PTC 直接 Node | 程式內 `fs.rm`／`spawn` 不經內層工具 | 原型掃 `run_code.code` 字樣 → ask；官方文件承認此盲區（`auto-review README:135–137`） |
| `ask` 可能沒有提示 | policy = `never`（full access preset）→ 直接 deny；無 answerer → deny | 原型先讀政策，轉成**明確 deny 訊息**；文件寫清楚 |
| 誤擋合法清理 | 遞迴刪 scratch 目錄會被 ask（full access 下被 deny） | `allowedRoots`（例：`C:\Temp`）、`mode: audit`、`-WhatIf` 放行 |
| plugin 信任邊界 | Host plugin 在 app process 內以完整權限執行 | 只安裝看得到原始碼的 plugin；本原型只讀 args＋寫 audit |
| 插件未載入＝無保護 | profile 改動失敗、bundle 停用 | 安裝後依 README 驗證；audit 檔／log 確認 `dsh-guard: active` |
| 效能 | 每次工具呼叫數個 regex | 可忽略（微秒級） |
| audit 檔含敏感內容 | 會記錄命令（截斷前 200 字元） | 記錄檔在 `%TEMP%`；可 `auditPath: false`；文件註明 |
| 只影響 DSH 發出的呼叫 | 使用者自己在終端機跑的、其他程式跑的不受管 | 搭配 OS 層保護 |

另外兩個「不是風險但要知道」的點：

- `tools/pre-execute` **故意不能改寫參數**（`dsh-tools/README.md:197`；也有
  一份 proposed Agent Note 在討論 pre-tool input rewrite）。所以守門只能
  allow/deny/ask，不能幫你把命令「安全化」。
- `dsh-session-checkpoint-policy` 的 checkpoint 是**session log 耐久性**，
  不是檔案快照（`dsh-session-checkpoint-policy/README.md:12,48–52`）。「刪除前
  自動 checkpoint 檔案」在 DSH 目前沒有現成機制，要自己做 VSS／備份。

---

## 7. 對 DSH 開發者的建議清單（依優先級）

1. **內建確定性危險命令守門**：在 `tools/pre-execute` 之前或之內，對 shell
   工具（`pwsh`/`bash`/`terminal`）做 canonicalize＋破壞性動詞＋受保護路徑
   檢查；預設 `ask`、受保護路徑 `deny`，且規則可配置。這是唯一能讓「出廠即
   安全」的做法。
2. **`danger-full-access` 的 approval policy 不要是 `never`**：至少讓「破壞性
   工具呼叫」能升級為明確的 deny 訊息，而不是一律「user rejected」；或在
   文件／UI 明示 full access 下不會有任何提示。
3. **支援參數改寫／遮罩**（已有 proposed Agent Note）：讓守門能「安全化」
   （例如把可疑路徑換成拒絕）而不是只能整通呼叫擋掉。
4. **破壞性呼叫前自動檔案 checkpoint**：VSS 快照或工作區快照，而不只是
   session log flush（`dsh-session-checkpoint-policy` 目前不含檔案）。
5. **官方安全刪除工具**：`delete` / `move` 類型工具內建 canonicalize＋受保護
   路徑＋預設 `-WhatIf`，讓模型有「安全的路」可走，而不是只能下 `rd /s /q`。
6. **把 `ctx.tools.guard()` 升級成可 ask**（目前只能 deny），並補公開文件／
   範例；現階段唯一能做 ask 的擴充點是 pre-execute waterfall。
7. **審計與可觀測性**：把 pre-execute 的 deny/ask 決策寫進 session log（目前
   approval 有 audit，但 pre-execute 決策沒有統一落點），方便事故後追。
8. **在 plugin 商店／Plugins 頁標示「host 全權」風險**：安裝第三方 host
   plugin 等於在 app process 內執行任意程式碼。
9. **把 Auto review 的 deterministic 子集預設化**：模型式審查可以留給模糊
   地帶，字面規則（`rd /s /q C:\`）不需要 LLM 也該擋。

---

## 8. 交付物清單

| 路徑 | 內容 |
|---|---|
| `dsh-guard-feasibility.md` | 本文件（結論／證據／方案／風險／建議） |
| `../dsh-guard/README.md` | 安裝、載入驗證、設定、限制、解除安裝 |
| `../dsh-guard/dsh-guard\` | 可運作原型（`index.js`、`rules.js`、`cordis.patch.yml`、`package.json`、`test\`） |
| `../dsh-guard/tools\` | 離線 Cordis 整合驗證腳本（不內含 DSH 程式碼） |
| `agent-safety-notes.md` | 給使用者與 agent 的實務守則（引用事故記錄） |

## 9. 未解問題

1. 安裝進活的 DSH desktop profile 後的端到端 `ask` 對話框行為未實測（本任務
   禁止改 `.dsh`）；需要使用者依 `guard\README.md` 驗收。
2. Desktop profile 只能由 Electron app 管理，GUI 是否接受「絕對路徑 bundle」
   未實測（`plugin_manager` 的 `inspect` 支援絕對路徑，但安裝流程未驗）；
   README 提供手動 `link:` 依賴的備援（同 `@local/dsh-tts` 做法）。
3. 若 DSH 改版把 `tools/pre-execute` 的 event 名稱／決策詞彙改掉，插件需要跟
   版本更新；目前以 0.2.2-rc.1 為準。
4. 是否要把守門擴到 `terminal`、persistent shell 等尚未在本 profile 掛載的
   工具，取決於之後啟用哪些 bundle（原型以工具名 + `command` 參數啟發式覆蓋）。
5. Profile 的 `plugin_manager` 安裝動作本身要求 full access 或批准；在
   approval 皆被拒的 session 內要由人操作 GUI。
