#Requires -Version 5.1
<#
.SYNOPSIS
    範例：把「先 Assert-SafePath、再刪除」套進一支刪除腳本。

.DESCRIPTION
    這支範例只會刪除「白名單根目錄」底下的資料夾，而且資料夾名稱必須符合
    -ExpectedLeafName（預設 job-*）。任何一項不符就結束，什麼都不刪。

    這是刻意寫得保守的版本：AllowedRoot 預設是 %TEMP%\safe-jobs（請先自行建立），
    而不是整個 %TEMP%，避免有人把整個暫存資料夾指定成 -Path。

.PARAMETER Path
    要刪除的資料夾路徑。會先經過 SafeDelete 政策檢查。

.PARAMETER AllowedRoot
    白名單根目錄；-Path 必須在此根目錄之下。預設 %TEMP%\safe-jobs。

.PARAMETER ExpectedLeafName
    最後一層資料夾名稱必須符合的樣式（-like 語法）。預設 job-*。

.EXAMPLE
    # 第一次建立示範用根目錄
    New-Item -ItemType Directory (Join-Path $env:TEMP 'safe-jobs') -Force

    # 先看會發生什麼（-WhatIf 不會刪除）
    .\Remove-SafeTempFolder.ps1 -Path (Join-Path $env:TEMP 'safe-jobs\job-1') -WhatIf

    # 確認後才真的刪
    .\Remove-SafeTempFolder.ps1 -Path (Join-Path $env:TEMP 'safe-jobs\job-1') -Confirm
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$Path,

    [string[]]$AllowedRoot = @((Join-Path $env:TEMP 'safe-jobs')),

    [string]$ExpectedLeafName = 'job-*'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'SafeDelete\SafeDelete.psd1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Error -Message "找不到 SafeDelete 模組：$modulePath" -ErrorAction Continue
    exit 2
}
Import-Module $modulePath -Force

# 第一步：canonicalize + 政策檢查。這一步失敗就結束，不做任何檔案系統操作。
try {
    $target = Assert-SafePath -Path $Path `
        -AllowedRoot $AllowedRoot `
        -ExpectedLeafName $ExpectedLeafName `
        -ScriptRoot $PSScriptRoot
}
catch {
    Write-Error -Message "拒絕刪除：$($_.Exception.Message)" -ErrorAction Continue
    exit 2
}

# 第二步：讓使用者知道會刪什麼（-WhatIf / -Confirm 由 SupportsShouldProcess 處理）。
if (-not $PSCmdlet.ShouldProcess($target, '安全刪除資料夾')) {
    return
}

# 第三步：才真的刪。腳本自己已經問過，所以這裡明確 -Confirm:$false。
Remove-SafeItem -Path $target -AllowedRoot $AllowedRoot -Confirm:$false

Write-Host "已刪除：$target"
