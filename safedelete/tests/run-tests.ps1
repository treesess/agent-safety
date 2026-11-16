#Requires -Version 5.1
<#
    run-tests.ps1 - minimal pure PowerShell 5.1 test runner for SafeDelete.

    Why this file exists:
      The repository's tests are written in Pester 5 style, but many Windows machines
      only have PowerShell 5.1 and the legacy Pester 3.4 (or no Pester at all).  This
      runner detects Pester 5 and uses it when present; otherwise it provides a small
      shim for Describe / Context / It / BeforeAll / AfterAll / BeforeEach / AfterEach
      and a useful subset of Should, then executes the exact same
      SafeDelete.Tests.ps1 file.  That keeps one source of truth for the assertions.

    Supported Should operators (when running with the shim):
      -Be, -BeExactly, -BeTrue, -BeFalse, -BeNullOrEmpty, -Match, -NotMatch,
      -Contain, -HaveCount, -BeGreaterThan, -BeGreaterOrEqual, -BeLessThan,
      -BeOfType, -Throw, -NotThrow, -ExpectedMessage, -Not

    Usage:
      powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
      powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1 -NoLog

    Exit code: 0 when every test passed, 1 otherwise.
#>

[CmdletBinding()]
param(
    [string]$Path,
    [string]$LogPath,
    [switch]$NoLog
)

$ErrorActionPreference = 'Stop'

if (-not $Path) { $Path = Join-Path $PSScriptRoot 'SafeDelete.Tests.ps1' }
if (-not $LogPath) { $LogPath = Join-Path $PSScriptRoot 'test-output.txt' }

$script:LogLines = New-Object System.Collections.ArrayList

function Write-RunnerLine {
    param(
        [AllowEmptyString()]
        [string]$Text
    )
    [void]$script:LogLines.Add($Text)
    Write-Host $Text
}

function Write-RunnerHeader {
    param(
        [string]$RunnerName,
        [string]$ModuleVersion
    )

    $powerShellVersion = $PSVersionTable.PSVersion.ToString()
    $edition = 'Desktop'
    if ($PSVersionTable.ContainsKey('PSEdition')) { $edition = [string]$PSVersionTable.PSEdition }

    Write-RunnerLine 'SafeDelete PowerShell module - test run'
    Write-RunnerLine '========================================='
    Write-RunnerLine ('Started        : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
    Write-RunnerLine ('PowerShell     : ' + $powerShellVersion + ' (' + $edition + ')')
    Write-RunnerLine ('Host           : ' + (Get-Host).Name)
    Write-RunnerLine ('Runner         : ' + $RunnerName)
    Write-RunnerLine ('Module         : .\SafeDelete\SafeDelete.psd1 (version ' + $ModuleVersion + ')')
    Write-RunnerLine ('Test file      : .\tests\' + (Split-Path -Leaf $Path))
    Write-RunnerLine ('Test data root : %TEMP% (fixtures are created there and removed afterwards)')
    Write-RunnerLine ''
}

function Write-RunnerSummary {
    param(
        [int]$Passed,
        [int]$Failed,
        [int]$Skipped,
        [double]$DurationSeconds
    )

    $total = $Passed + $Failed + $Skipped
    Write-RunnerLine ''
    Write-RunnerLine ('Summary: {0} passed, {1} failed, {2} skipped (total {3}) in {4:n2}s' -f $Passed, $Failed, $Skipped, $total, $DurationSeconds)
    if ($Failed -gt 0) {
        Write-RunnerLine 'Result : FAIL'
    }
    else {
        Write-RunnerLine 'Result : PASS'
    }
}

function Save-RunnerLog {
    if ($NoLog -or -not $LogPath) { return }
    try {
        Set-Content -LiteralPath $LogPath -Value $script:LogLines -Encoding UTF8
        Write-Host ''
        Write-Host ('Log written to: .\tests\' + (Split-Path -Leaf $LogPath))
    }
    catch {
        Write-Host ('WARNING: could not write log file: ' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# Shim: enough of Pester 5 to execute the Pester style test file
# ---------------------------------------------------------------------------

$script:Shim = @{
    ScopeStack = New-Object System.Collections.Stack
    Results    = New-Object System.Collections.ArrayList
}

function Assert-SdCondition {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw [System.Exception]::new('SafeDelete test assertion failed: ' + $Message)
    }
}

function Format-SdValue {
    param([object]$Value)

    if ($null -eq $Value) { return '$null' }
    if ($Value -is [string]) {
        if ($Value.Length -gt 300) { return "'" + $Value.Substring(0, 300) + "...'" }
        return "'" + $Value + "'"
    }
    if ($Value -is [bool]) {
        if ($Value) { return '$true' }
        return '$false'
    }
    try {
        $text = $Value | ConvertTo-Json -Compress -Depth 3
    }
    catch {
        $text = [string]$Value
    }
    if ($null -eq $text) { $text = [string]$Value }
    if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '...' }
    return $text
}

function Should {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [object]$ActualValue,
        [object]$Be,
        [object]$BeExactly,
        [string]$Match,
        [string]$NotMatch,
        [object]$Contain,
        [int]$HaveCount,
        [object]$BeGreaterThan,
        [object]$BeGreaterOrEqual,
        [object]$BeLessThan,
        [object]$BeOfType,
        [switch]$Not,
        [switch]$BeTrue,
        [switch]$BeFalse,
        [switch]$BeNullOrEmpty,
        [switch]$Throw,
        [switch]$NotThrow,
        [string]$ExpectedMessage
    )

    begin {
        $script:ShouldItems = New-Object System.Collections.ArrayList
    }
    process {
        [void]$script:ShouldItems.Add($ActualValue)
    }
    end {
        $items = @($script:ShouldItems)
        if ($items.Count -eq 0) { $actual = $null }
        elseif ($items.Count -eq 1) { $actual = $items[0] }
        else { $actual = $items }

        # --- exception assertions -------------------------------------------
        if ($Throw -or $NotThrow) {
            Assert-SdCondition ($actual -is [scriptblock]) ('Should -Throw 需要 scriptblock 輸入，例如 { Get-Item C:\ } | Should -Throw；實際值：' + (Format-SdValue $actual))

            $expectThrow = [bool]$Throw
            if ($Not) { $expectThrow = -not $expectThrow }
            if ($NotThrow) { $expectThrow = $false }

            $didThrow = $false
            $caught = $null
            try {
                & $actual | Out-Null
            }
            catch {
                $didThrow = $true
                $caught = $_
            }

            if ($expectThrow) {
                Assert-SdCondition $didThrow '預期會丟出例外，但沒有丟出。'
                if ($ExpectedMessage -and $caught) {
                    Assert-SdCondition ($caught.Exception.Message -like ('*' + $ExpectedMessage + '*')) ('例外訊息不含預期文字；實際：' + $caught.Exception.Message)
                }
            }
            else {
                Assert-SdCondition (-not $didThrow) ('不預期丟出例外，但丟出了：' + $caught.Exception.Message)
            }
            return
        }

        # --- value assertions -----------------------------------------------
        $ok = $false
        $expectedText = ''

        if ($PSBoundParameters.ContainsKey('Be')) {
            $ok = [bool]($actual -eq $Be)
            $expectedText = '等於 ' + (Format-SdValue $Be)
        }
        elseif ($PSBoundParameters.ContainsKey('BeExactly')) {
            $ok = [string]::Equals([string]$actual, [string]$BeExactly, [StringComparison]::Ordinal)
            $expectedText = '完全等於 ' + (Format-SdValue $BeExactly)
        }
        elseif ($PSBoundParameters.ContainsKey('Match')) {
            $ok = [bool]([string]$actual -match $Match)
            $expectedText = '符合正則 ' + $Match
        }
        elseif ($PSBoundParameters.ContainsKey('NotMatch')) {
            $ok = -not [bool]([string]$actual -match $NotMatch)
            $expectedText = '不符合正則 ' + $NotMatch
        }
        elseif ($PSBoundParameters.ContainsKey('Contain')) {
            $ok = [bool](@($actual) -contains $Contain)
            $expectedText = '包含 ' + (Format-SdValue $Contain)
        }
        elseif ($PSBoundParameters.ContainsKey('HaveCount')) {
            $ok = (@($actual).Count -eq $HaveCount)
            $expectedText = ('數量等於 ' + $HaveCount)
        }
        elseif ($PSBoundParameters.ContainsKey('BeGreaterThan')) {
            $ok = [bool]($actual -gt $BeGreaterThan)
            $expectedText = '大於 ' + (Format-SdValue $BeGreaterThan)
        }
        elseif ($PSBoundParameters.ContainsKey('BeGreaterOrEqual')) {
            $ok = [bool]($actual -ge $BeGreaterOrEqual)
            $expectedText = '大於或等於 ' + (Format-SdValue $BeGreaterOrEqual)
        }
        elseif ($PSBoundParameters.ContainsKey('BeLessThan')) {
            $ok = [bool]($actual -lt $BeLessThan)
            $expectedText = '小於 ' + (Format-SdValue $BeLessThan)
        }
        elseif ($PSBoundParameters.ContainsKey('BeOfType')) {
            $ok = ($actual -is $BeOfType)
            $expectedText = '型別是 ' + [string]$BeOfType
        }
        elseif ($BeTrue) {
            $ok = [bool]$actual
            $expectedText = '是 $true'
        }
        elseif ($BeFalse) {
            $ok = -not [bool]$actual
            $expectedText = '是 $false'
        }
        elseif ($BeNullOrEmpty) {
            $ok = ($null -eq $actual) -or (($actual -is [string]) -and ($actual.Length -eq 0)) -or (@($actual).Count -eq 0)
            $expectedText = '是 $null 或空'
        }
        else {
            throw [System.Exception]::new('SafeDelete test assertion failed: Should 沒有指定任何運算子（例如 -Be / -BeTrue / -Throw）。')
        }

        if ($Not) { $ok = -not $ok }

        $negation = ''
        if ($Not) { $negation = '不' }
        Assert-SdCondition $ok ('預期' + $negation + $expectedText + '，實際值：' + (Format-SdValue $actual))
    }
}

function Invoke-SdContainer {
    param(
        [string]$ContainerName,
        [string]$Kind,
        [scriptblock]$Fixture
    )

    $scope = [pscustomobject]@{
        Name       = $ContainerName
        Kind       = $Kind
        BeforeEach = @()
        AfterEach  = @()
        AfterAll   = @()
    }
    $script:Shim.ScopeStack.Push($scope)

    $containerError = $null
    try {
        & $Fixture
    }
    catch {
        $containerError = $_
    }
    finally {
        $popped = $script:Shim.ScopeStack.Pop()
        foreach ($block in $popped.AfterAll) {
            try { & $block }
            catch { Write-RunnerLine ('[WARN] AfterAll failed: ' + $_.Exception.Message) }
        }
    }

    if ($containerError) {
        $message = $containerError.Exception.Message
        [void]$script:Shim.Results.Add([pscustomobject]@{
            Name     = $ContainerName
            Outcome  = 'Failed'
            Message  = '容器執行失敗（BeforeAll / 最上層程式碼）：' + $message
            Duration = 0.0
        })
        Write-RunnerLine ('FAIL  ' + $ContainerName + ' (container setup)')
        Write-RunnerLine ('      ' + ($message -replace "`r?`n", ' | '))
    }
}

function Describe {
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,
        [Parameter(Mandatory, Position = 1)]
        [scriptblock]$Fixture
    )
    Invoke-SdContainer -ContainerName $Name -Kind 'Describe' -Fixture $Fixture
}

function Context {
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,
        [Parameter(Mandatory, Position = 1)]
        [scriptblock]$Fixture
    )
    Invoke-SdContainer -ContainerName $Name -Kind 'Context' -Fixture $Fixture
}

function BeforeAll {
    param([Parameter(Mandatory)][scriptblock]$Script)
    & $Script
}

function AfterAll {
    param([Parameter(Mandatory)][scriptblock]$Script)
    $scope = $script:Shim.ScopeStack.Peek()
    $scope.AfterAll += $Script
}

function BeforeEach {
    param([Parameter(Mandatory)][scriptblock]$Script)
    $scope = $script:Shim.ScopeStack.Peek()
    $scope.BeforeEach += $Script
}

function AfterEach {
    param([Parameter(Mandatory)][scriptblock]$Script)
    $scope = $script:Shim.ScopeStack.Peek()
    $scope.AfterEach += $Script
}

function It {
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,
        [Parameter(Mandatory, Position = 1)]
        [scriptblock]$Test
    )

    $scopes = @($script:Shim.ScopeStack.ToArray())
    [array]::Reverse($scopes)
    $fullName = ((@($scopes | ForEach-Object { $_.Name })) + $Name) -join ' > '

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $outcome = 'Passed'
    $message = $null
    $stackTrace = $null

    try {
        foreach ($scope in $scopes) {
            foreach ($block in $scope.BeforeEach) { & $block }
        }
        & $Test
    }
    catch {
        $outcome = 'Failed'
        $message = $_.Exception.Message
        $stackTrace = $_.ScriptStackTrace
    }
    finally {
        foreach ($scope in $scopes) {
            foreach ($block in $scope.AfterEach) {
                try { & $block }
                catch { Write-RunnerLine ('[WARN] AfterEach failed: ' + $_.Exception.Message) }
            }
        }
    }

    $stopwatch.Stop()
    [void]$script:Shim.Results.Add([pscustomobject]@{
        Name     = $fullName
        Outcome  = $outcome
        Message  = $message
        Duration = $stopwatch.Elapsed.TotalSeconds
    })

    if ($outcome -eq 'Passed') {
        Write-RunnerLine ('PASS  ' + $fullName)
    }
    else {
        Write-RunnerLine ('FAIL  ' + $fullName)
        Write-RunnerLine ('      ' + ($message -replace "`r?`n", ' | '))
        if ($stackTrace) {
            foreach ($stackLine in @($stackTrace -split "`r?`n")) {
                if ($stackLine.Trim().Length -gt 0) {
                    Write-RunnerLine ('      at ' + $stackLine.Trim())
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'SafeDelete\SafeDelete.psd1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Host ('ERROR: module manifest not found: ' + $modulePath)
    exit 1
}

Import-Module $modulePath -Force
$moduleVersion = (Get-Module -Name SafeDelete).Version.ToString()

$pester5 = $null
try {
    $pester5 = Get-Module -ListAvailable -Name Pester |
        Where-Object { $_.Version.Major -ge 5 } |
        Sort-Object Version -Descending |
        Select-Object -First 1
}
catch {
    $pester5 = $null
}

$overallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

if ($pester5) {
    Write-RunnerHeader -RunnerName ('Pester ' + $pester5.Version.ToString()) -ModuleVersion $moduleVersion

    Import-Module Pester -MinimumVersion 5.0 -Force
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = $Path
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Detailed'
    $result = Invoke-Pester -Configuration $configuration

    $passed = [int]$result.PassedCount
    $failed = [int]$result.FailedCount
    $skipped = [int]$result.SkippedCount

    foreach ($failure in @($result.Failed)) {
        $failureName = $failure.ExpandedName
        if (-not $failureName) { $failureName = [string]$failure }
        Write-RunnerLine ('FAIL  ' + $failureName)
        if ($failure.ErrorRecord) {
            Write-RunnerLine ('      ' + ($failure.ErrorRecord.Exception.Message -replace "`r?`n", ' | '))
        }
    }

    $overallStopwatch.Stop()
    Write-RunnerSummary -Passed $passed -Failed $failed -Skipped $skipped -DurationSeconds $overallStopwatch.Elapsed.TotalSeconds
    Save-RunnerLog

    if ($failed -gt 0) { exit 1 }
    exit 0
}

# No Pester 5 available: use the built-in shim and run the same Pester style file.
Write-RunnerHeader -RunnerName 'plain PowerShell 5.1 shim (Pester 5 not installed)' -ModuleVersion $moduleVersion

if (-not (Test-Path -LiteralPath $Path)) {
    Write-RunnerLine ('ERROR: test file not found: ' + $Path)
    Save-RunnerLog
    exit 1
}

try {
    . $Path
}
catch {
    [void]$script:Shim.Results.Add([pscustomobject]@{
        Name     = '(test file)'
        Outcome  = 'Failed'
        Message  = $_.Exception.Message
        Duration = 0.0
    })
    Write-RunnerLine ('FAIL  (test file execution)')
    Write-RunnerLine ('      ' + ($_.Exception.Message -replace "`r?`n", ' | '))
}

$overallStopwatch.Stop()

$passed = @($script:Shim.Results | Where-Object { $_.Outcome -eq 'Passed' }).Count
$failed = @($script:Shim.Results | Where-Object { $_.Outcome -eq 'Failed' }).Count
$skipped = 0

Write-RunnerSummary -Passed $passed -Failed $failed -Skipped $skipped -DurationSeconds $overallStopwatch.Elapsed.TotalSeconds
Save-RunnerLog

if ($failed -gt 0) { exit 1 }
exit 0
