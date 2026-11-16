# tools/ — 離線整合驗證（可選）

這裡的兩支腳本用「真的 Cordis 4.1.0」驗證 `dsh-guard` 的掛載與決策，不需要
安裝進 profile、也不會改任何 DSH 設定。只讀 DSH 安裝目錄；寫入只會發生在本
資料夾的 `.\node_modules\`（腳本會拒絕其他目的地）。

## 步驟

```powershell
# 1) 抽出驗證所需的 4 個套件（cordis、dsh-scope、cosmokit、@standard-schema/spec）
cd "C:\work\agent-safety\dsh-guard\tools"
node asar-extract.mjs

# 2) 跑整合驗證
node verify-cordis.mjs
```

預期輸出（7 個 case 全 PASS）：

```
PASS  drive-root recursive delete: expected=deny got=deny
PASS  protected personal root: expected=deny got=deny
PASS  ordinary read: expected=allow got=allow
PASS  recursive delete of a scratch path: expected=ask got=ask
PASS  unresolved PTC program body: expected=ask got=ask
PASS  listener removed after plugin disposal: expected=allow got=allow
PASS  ask degrades to explicit denial under policy "never": expected=deny got=deny

all cordis integration cases passed
```

## 參數

`asar-extract.mjs` 預設路徑對應本機安裝：

| 選項 | 預設 |
|---|---|
| `--asar` | `C:\Users\user\AppData\Local\Programs\DeepSeek Harness\resources\app.asar` |
| `--profile-modules` | `C:\Users\user\.dsh\profiles\desktop\node_modules` |
| `--dest` | `.\node_modules`（必須在此 `tools` 資料夾內） |

換機器或換 DSH 版本時，用參數覆寫即可（Cordis 版本需與 DSH 內建的一致；
本機為 4.1.0）。

## 清理

`tools\node_modules\` 只是驗證用複本（約 1 MB 的 DSH 內部套件），不再需要時
可自行刪除；`verify-cordis.mjs` 與 `asar-extract.mjs` 不含任何 DSH 程式碼。
