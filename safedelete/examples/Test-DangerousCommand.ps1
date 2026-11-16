#Requires -Version 5.1
<#
.SYNOPSIS
    範例：用 Test-DangerousCommandLine 幫一段命令字串守門。

.DESCRIPTION
    適合放在 agent／排程／CI 的「工具呼叫執行前」關卡：把要執行的 shell 命令
    丟進來，只要偵測到破壞性動詞或目標不安全，就以非 0 離開碼結束，讓外層決定
    要人工確認或直接阻止。

    離開碼：
      0 = 未偵測到破壞性命令
      3 = 偵測到破壞性命令（需要人工確認／拒絕執行）
      4 = 參數錯誤

.PARAMETER CommandLine
    要檢查的命令字串。

.EXAMPLE
    .\Test-DangerousCommand.ps1 -CommandLine 'cmd /c rd /s /q "C:\"'
    # -> 偵測到危險，離開碼 3

.EXAMPLE
    .\Test-DangerousCommand.ps1 -CommandLine 'Get-ChildItem -Path D:\data'
    # -> 安全，離開碼 0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CommandLine
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'SafeDelete\SafeDelete.psd1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Error "找不到 SafeDelete 模組：$modulePath"
    exit 4
}
Import-Module $modulePath -Force

$result = Test-DangerousCommandLine -CommandLine $CommandLine

if ($result.IsDangerous) {
    Write-Host 'DANGEROUS'
    Write-Host ('Matched      : ' + (@($result.Matched) -join ', '))
    Write-Host ('TargetKnown  : ' + $result.TargetKnown)
    Write-Host ('TargetSafe   : ' + $result.TargetSafe)
    foreach ($reason in @($result.Reasons)) {
        Write-Host ('Reason       : ' + $reason)
    }
    if (-not $result.TargetSafe) {
        Write-Host '建議：要求人工確認，並附上上面列出的原因與目標。'
    }
    exit 3
}

Write-Host 'OK: 未偵測到破壞性命令。'
exit 0
