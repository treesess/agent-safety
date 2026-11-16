# SafeDelete

> 給 PowerShell 5.1+ 的「先驗證、再刪除」模組。所有刪除／鏡像操作都先通過 fail-closed（預設拒絕）的路徑政策，junction 只刪連結不動目標，預設會要求確認或支援 `-WhatIf`。

## 這個模組解決什麼問題

刪除類指令最危險的地方不是 `rd /s /q` 本身，而是**目標路徑沒有被正規化就餵進去**。

真實事故（2026-11）的根因可以簡化成：

```powershell
# 看起來有防護，其實沒有
if ([System.IO.Path]::GetFullPath($Dest) -eq [System.IO.Path]::GetFullPath($env:USERPROFILE)) { throw }
# GetFullPath("C:\") 回傳 "C:\"（保留尾端反斜線）
# 它不等於使用者目錄，所以 "C:\" 通過了檢查
& cmd /c "rd /s /q `"$Dest`""    # 接著就是災難
```

`SafeDelete` 把這件事變成一個可重複使用的模組：

- **canonicalize 後才比較**：`GetFullPath` + `TrimEnd('\')`，所以 `C:\`、`C:`、`C:\Users\me\`、`C:\Users\me\..\..` 都會先被還原成同一個形式再判斷。
- **明確拒絕清單**：磁碟根目錄、使用者主目錄、`.dsh`、`Windows`／`Program Files*`／`ProgramData`、腳本自身目錄、相對路徑、萬用字元、裝置路徑、ADS。
- **白名單模式**：`-AllowedRoot` 讓呼叫端只能刪某個根目錄底下的東西。
- **只刪連結**：junction／symlink 一律只移除連結本身，遞迴刪除也絕不追進 reparse point。
- **預設安全**：`Remove-SafeItem` 的 `ConfirmImpact` 是 `High`（預設會問），支援 `-WhatIf`；`Invoke-SafeRobocopy` 也一樣。
- **命令字串掃描**：`Test-DangerousCommandLine` 可以給 agent／排程／CI 當守門用。

## 功能一覽

| 函式 | 用途 |
|---|---|
| `Assert-SafePath` | 驗證並回傳 canonical 路徑；不安全就丟出例外（刪除腳本的第一行） |
| `Test-SafePath` | 不丟例外的版本；`-Detailed` 回傳 `IsSafe`／`ReasonCode`／`Reason` |
| `Remove-SafeItem` | 安全刪除檔案／資料夾／連結；junction 只刪 link；支援長路徑；`-WhatIf`／`-Confirm` |
| `Test-SafeMirrorTarget` | 驗證 robocopy `/MIR` 的來源／目標／marker，回傳檢查結果與預計指令 |
| `Invoke-SafeRobocopy` | 通過上面的檢查後才執行 robocopy `/MIR`（固定加 `/XJ`） |
| `Test-DangerousCommandLine` | 掃描命令字串中的破壞性動詞與目標，回傳 `IsDangerous`／`Reasons`／`Matched` |
| `Register-SafeDeleteDeniedPath` | 在模組層加入／移除永久拒絕路徑（例如個人資料根目錄） |
| `Get-SafeDeleteProtectedPath` | 查看目前生效的內建受保護位置 |

## 安裝

需求：Windows PowerShell 5.1 或 PowerShell 7+（`CompatiblePSEditions = Desktop, Core`）。不需要管理員權限，沒有外部相依。

### 方式 A：直接 import（最簡單）

```powershell
Import-Module .\SafeDelete\SafeDelete.psd1
Get-Command -Module SafeDelete
```

### 方式 B：放進模組搜尋路徑

```powershell
$moduleRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules\SafeDelete\0.1.0'
New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
Copy-Item -Path .\SafeDelete\* -Destination $moduleRoot -Recurse -Force
Import-Module SafeDelete
```

### 執行原則（ExecutionPolicy）注意

若系統是預設的 `Restricted`，任何本機 `.psm1` 都無法載入（不是模組的問題）。可用：

```powershell
# 只在本次執行繞過（最不影響系統設定）
powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module .\SafeDelete\SafeDelete.psd1"
```

或（長期）把目前使用者設成 `RemoteSigned`：

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

## 快速開始

```powershell
Import-Module .\SafeDelete\SafeDelete.psd1

# 正常路徑：回傳 canonical 形式（沒有尾端反斜線）
$target = Assert-SafePath -Path 'D:\work\temp-job'
$target

# 危險路徑：丟出例外，訊息含 ReasonCode
Assert-SafePath -Path 'C:\'          # [DriveRoot]
Assert-SafePath -Path 'C:'           # [DriveRoot]
Assert-SafePath -Path $env:USERPROFILE   # [UserProfile]
Assert-SafePath -Path 'rel\path'     # [RelativePath]

# 不想用例外時
(Test-SafePath -Path 'C:\' -Detailed).ReasonCode   # DriveRoot

# 白名單模式：只能動 D:\work 底下的東西
Test-SafePath -Path 'D:\work\job1' -AllowedRoot 'D:\work'   # True
Test-SafePath -Path 'D:\other'     -AllowedRoot 'D:\work'   # False（OutsideAllowedRoot）
```

### ReasonCode 一覽

| ReasonCode | 代表意義 |
|---|---|
| `EmptyPath` | 空字串／只有空白／`$null` |
| `InvalidPath` | 格式無效、不合法字元、ADS（`file.txt:stream`） |
| `Wildcard` | 含 `*` 或 `?` |
| `RelativePath` | 相對路徑（未給 `-AllowRelative`） |
| `DriveRelativePath` | 磁碟相對路徑（`C:foo`），一律拒絕 |
| `DriveRoot` | 磁碟根目錄（`C:\`、`C:`、`Q:\`、`\`） |
| `ShareRoot` | UNC 共享根目錄（`\\server\share`） |
| `DevicePath` | 裝置路徑（`\\.\`、`\??\`） |
| `UserProfile` | 使用者主目錄（含尾端斜線變體） |
| `UsersRoot` | `C:\Users` 這一層 |
| `SystemDirectory` | `Windows`、`Windows.old`、`Program Files*`、`ProgramData`、`$Recycle.Bin` 等 |
| `DshDirectory` | 任何層級的 `.dsh` 目錄 |
| `ScriptDirectory` | 模組自身目錄或呼叫端 `-ScriptRoot` 目錄 |
| `OutsideAllowedRoot` | 不在 `-AllowedRoot` 白名單內 |
| `DeniedPath` | 在 `-DenyPath` 或 `Register-SafeDeleteDeniedPath` 清單內 |
| `UnexpectedLeafName` | 最後一層名稱不符合 `-ExpectedLeafName` |
| `InvalidAllowedRoot` / `InvalidDenyPath` / `InvalidScriptRoot` | 呼叫端參數本身無效（fail closed） |
| `Ok` | 通過 |

## 在刪除腳本裡「第一步先 Assert-SafePath」

把驗證放在**任何**檔案系統操作之前，並且限定白名單與資料夾名稱：

```powershell
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$Dest,

    # 只允許刪這個根目錄底下的東西；請依實際需求修改
    [string[]]$AllowedRoot = @("$env:TEMP\safe-jobs"),

    # 最後一層資料夾名稱必須符合（支援 -like 萬用字元）
    [string]$ExpectedLeafName = 'job-*'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 1) 第一步：canonicalize + 政策檢查。不符就直接結束，什麼都不刪。
try {
    $target = Assert-SafePath -Path $Dest `
        -AllowedRoot $AllowedRoot `
        -ExpectedLeafName $ExpectedLeafName `
        -ScriptRoot $PSScriptRoot
}
catch {
    Write-Error "拒絕刪除：$($_.Exception.Message)"
    exit 2
}

# 2) 先讓使用者看到會發生什麼
Write-Host "將刪除：$target"
if (-not $PSCmdlet.ShouldProcess($target, '安全删除')) { return }

# 3) 才真的刪。呼叫端已經自己 ShouldProcess 過，所以這裡明確 -Confirm:$false
Remove-SafeItem -Path $target -AllowedRoot $AllowedRoot -Confirm:$false
```

同樣的骨架可以直接套在「搬移」「清理快取」「重設 profile」等任何會大量覆寫的腳本上。

## `Remove-SafeItem` 的行為

```powershell
# 先看會做什麼（不會真的刪）
Remove-SafeItem -Path 'D:\work\job1' -AllowedRoot 'D:\work' -WhatIf

# 真的刪（ConfirmImpact = High，互動使用時預設會問；自動化要明確 -Confirm:$false）
Remove-SafeItem -Path 'D:\work\job1' -AllowedRoot 'D:\work' -Confirm:$false

# 只清空內容、保留資料夾本身
Remove-SafeItem -Path 'D:\work\job1' -AllowedRoot 'D:\work' -KeepRoot -Confirm:$false
```

規則：

- 先跑 `Assert-SafePath` 的完整政策檢查；不安全 -> 例外，不動檔案系統。
- 目標不存在 -> 丟出 `FileNotFoundException`（不會默默成功，避免「以為刪了其實沒刪」）。
- 目標是 junction／目錄符號連結 -> 用 `cmd /c rmdir` 只刪連結，**不碰連結目標**。
- 目標是資料夾 -> 自己遞迴走訪（不是 `Remove-Item -Recurse`），每個子項若是 reparse point 也只刪連結。
- 長路徑（超過 `MAX_PATH`）用 `\\?\` 前綴處理。
- 整個操作是單一 `ShouldProcess` 目標：`-WhatIf` 只印一次、`-Confirm` 只問一次。
- `-PassThru` 可拿回 `Path`／`Removed`（刪除項目數）／`IsReparsePoint`／`KeptRoot`。

## robocopy `/MIR` 防護

`robocopy /MIR` 是「讓目標跟來源一樣」，所以目標端多出來的東西會被刪掉。用 marker 檔避免指錯資料夾：

```powershell
# 第一次設定鏡像目標時，放一個 marker（例如在備份碟根目錄）
Set-Content -Path 'E:\backup\data\.backup-target' -Value 'safe to mirror into this folder'

# 先驗證（不會執行任何東西）
Test-SafeMirrorTarget -Source 'D:\data' -Destination 'E:\backup\data'

# 通過才執行；-WhatIf 只顯示，不會跑 robocopy
Invoke-SafeRobocopy -Source 'D:\data' -Destination 'E:\backup\data' -WhatIf
Invoke-SafeRobocopy -Source 'D:\data' -Destination 'E:\backup\data' -Confirm
```

`Test-SafeMirrorTarget` 會檢查：

1. 來源路徑通過 SafeDelete 政策、存在、是資料夾。
2. 目標路徑通過 SafeDelete 政策（不能是磁碟根目錄、使用者主目錄、`.dsh`、系統目錄…）。
3. 目標不是來源本身、不在來源底下、也不是來源的上一層。
4. 目標存在時必須有 marker 檔（預設 `.backup-target` 或 `.safedelete-mirror`）；目標不存在時需要明示 `-AllowCreate`。
5. `Invoke-SafeRobocopy` 固定加 `/XJ`（排除 junction／目錄符號連結，避免 robocopy 跟著連結跑到別的磁碟）、`/R:2 /W:2`（重試上限）。

## 掃描命令字串：`Test-DangerousCommandLine`

給 agent／排程／CI 當守門用，例如「工具呼叫的 shell 命令在執行前先掃一次」：

```powershell
$result = Test-DangerousCommandLine -CommandLine 'cmd /c rd /s /q "C:\"'

$result.IsDangerous         # True
$result.RequiresApproval    # True
$result.Matched             # @('RecursiveDirectoryDelete')
$result.Reasons             # 中文說明，含目標路徑為何不安全
$result.TargetKnown         # True（有抓到目標）
$result.TargetSafe          # False（目標是磁碟根目錄）
```

回傳物件欄位：

| 欄位 | 說明 |
|---|---|
| `IsDangerous` | 是否命中至少一個破壞性規則（`rd /s`、`del /s`、`Remove-Item -Recurse`、`robocopy /MIR`、`rm -rf`、`Format-Volume`、`diskpart clean`、`vssadmin delete shadows`、`cipher /w`…） |
| `RiskLevel` | `High`（命中）或 `None` |
| `RequiresApproval` | 與 `IsDangerous` 相同，方便呼叫端直接判斷 |
| `Matched` | 命中的規則 id 清單 |
| `Reasons` | 繁體中文原因；包含「無法判定目標」與「目標未通過安全檢查」 |
| `Targets` | 從命令字串抓到的候選目標路徑（會展開 `%VAR%` / `$env:VAR`） |
| `TargetKnown` | 是否抓到目標；抓不到時視為危險（`TargetSafe = False`） |
| `TargetSafe` | 所有抓到的目標是否都通過安全路徑政策 |
| `TargetAssessments` | 每個目標的 `Path`／`CanonicalPath`／`IsSafe`／`ReasonCode`／`Reason` |

語義重點：**破壞性動詞一律 `IsDangerous = True`**，即使目標看起來安全（例如 `%TEMP%` 底下的資料夾），因為這一類指令本身就該要求人工確認。`IsDangerous = False` 才代表「沒偵測到破壞性動詞」。

## 模組層拒絕清單

```powershell
# 例如：這個使用者有一個資料根目錄，無論什麼腳本都不該整個刪掉
Register-SafeDeleteDeniedPath -Path 'D:\precious'
Register-SafeDeleteDeniedPath -Path 'D:\precious' -Remove   # 取消

Get-SafeDeleteProtectedPath   # 查看目前生效的內建保護與已註冊清單
```

## 範例腳本

`examples\` 底下有兩個可以直接照抄的骨架：

```powershell
# 1) 安全刪除腳本的完整骨架（先 Assert-SafePath、再 ShouldProcess、最後 Remove-SafeItem）
New-Item -ItemType Directory (Join-Path $env:TEMP 'safe-jobs') -Force | Out-Null
.\examples\Remove-SafeTempFolder.ps1 -Path (Join-Path $env:TEMP 'safe-jobs\job-1') -WhatIf

# 2) 命令字串守門（離開碼 0 = 安全，3 = 需要人工確認）
.\examples\Test-DangerousCommand.ps1 -CommandLine 'cmd /c rd /s /q "C:\"'
```

## 設計原則

1. **Fail closed**：不確定就拒絕，不猜、不自動修正、不「先刪再說」。無效的 `-AllowedRoot`、`-DenyPath`、`-ScriptRoot` 也直接拒絕。
2. **先 canonicalize 再比較**：`[IO.Path]::GetFullPath` + `TrimEnd('\', '/')`；比對一律 case-insensitive，且用「路徑邊界」比對（`C:\ab` 不會被當成 `C:\a` 的子路徑）。
3. **白名單優先**：`-AllowedRoot` 是唯一能真正限制「只能刪哪裡」的機制；拒絕清單永遠不可能窮盡。
4. **只刪連結**：junction／symlink 只移除連結本身；遞迴刪除絕不追進 reparse point。這條在刪除含連結的樹時是硬性規則。
5. **預設安全**：`Remove-SafeItem`／`Invoke-SafeRobocopy` 都是 `SupportsShouldProcess` + `ConfirmImpact = High`，預設要求確認並支援 `-WhatIf`。
6. **不用 `Remove-Item -Recurse`**：模組自己走訪目錄，才能保證每個 reparse point 都被當成連結處理。
7. **不把使用者輸入直接串進命令列**：只有已驗證的 canonical 路徑、且為了刪 junciton 才使用 `cmd /c rmdir`，並以參數方式傳遞。
8. **清楚的原因碼**：每個拒絕都有 `ReasonCode` 與繁體中文 `Reason`，方便記錄與測試。

## 已知限制

- **不是萬用安全機制**：擋的是「明顯錯誤的目標」（根目錄、使用者主目錄、系統目錄…）與「沒有限制範圍的刪除」。它無法知道 `D:\important-project` 對你很重要，所以正式腳本請務必用 `-AllowedRoot`（白名單）。
- **相對路徑預設拒絕**；`-AllowRelative` 時以呼叫端的 PowerShell 目前位置（`Push-Location`／`Set-Location`）解析，不是行程 CWD。
- **硬連結（hardlink）** 無法辨識：刪除硬連結是刪除該目錄項，不會刪到其他連結的內容（這是 Windows 語義），模組不會額外警告。
- **損壞（dangling）的連結**：部分情況下 `[IO.File]::GetAttributes`／`Exists` 無法辨識，可能被當成「不存在」而拒絕；此時可改用 `cmd /c rmdir "<path>"` 或 `Remove-SafeItem -WhatIf` 確認後手動處理。
- **檔案符號連結**只適用於有權限建立連結的使用者（一般使用者建立目錄 junction 不需要管理員，建立 symlink 需要 Developer Mode 或管理員權限）；模組本身不建立連結。
- **`Test-DangerousCommandLine` 是啟發式靜態掃描**：可被變數拼接、`Invoke-Expression`、別名、base64、動態產生的命令繞過；也可能誤判（例如 `echo "rd /s /q"` 這種字串）。它應該只是多層防護的其中一層，不能當唯一防線。
- **不處理 ACL／擁有權／檔案鎖定**：刪不掉時會丟出例外並帶上系統錯誤訊息，請自行檢查權限或鎖定。
- **測試環境**：本專案的 `test-output.txt` 是在 Windows 11 + Windows PowerShell 5.1（build 26100）驗證的；PowerShell 7 也可載入，但未在 CI 上跑過。
- **已知 PowerShell 5.1 特性**：某些 build 對 `@($genericList)` 會丟 `ArgumentException: Argument types do not match`；本模組內部因此使用非泛型 `ArrayList`，不影響公開介面。

## 測試

測試資料**只建立在 `%TEMP%`**，測試結束後刪除；不會碰真實資料路徑。

```powershell
# 沒有 Pester 5 也能跑（內建純 PowerShell 5.1 shim，執行同一份 Pester 5 測試檔）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1

# 有 Pester 5 的話也可以直接用 Pester 5
Invoke-Pester -Path .\tests\SafeDelete.Tests.ps1
```

最近一次本機結果（詳見 [`tests/test-output.txt`](tests/test-output.txt)）：

```
Runner  : plain PowerShell 5.1 shim (Pester 5 not installed)
Module  : .\SafeDelete\SafeDelete.psd1 (version 0.1.0)
Summary : 76 passed, 0 failed, 0 skipped (total 76)
Result  : PASS
```

涵蓋範圍包括：`C:\`、`C:`、使用者主目錄（含尾端斜線）、`.dsh`、空字串、空白、`.`／相對路徑／碟相對路徑、萬用字元、`Windows`／`Program Files`／`ProgramData`、模組與腳本自身目錄、`AllowedRoot` 白名單、`DenyPath`、`ExpectedLeafName`、正常 `%TEMP%` 資料夾、junction 只刪連結不動目標、含 junction 的樹不被追入、隱藏／唯讀檔、超過 `MAX_PATH` 的長路徑、`-WhatIf` 不刪除、robocopy 目標驗證，以及 `Test-DangerousCommandLine` 的各種樣本。

## 授權

MIT，見 [LICENSE](LICENSE)。
