#Requires -Version 5.1
<#
    SafeDelete.Tests.ps1

    Pester 5 style tests for the SafeDelete module.

    How to run:
      - On a machine with Pester 5:  Invoke-Pester -Path .\tests\SafeDelete.Tests.ps1
      - On a machine with only PowerShell 5.1 (no Pester 5, e.g. Pester 3.4 only):
            powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
        run-tests.ps1 ships a minimal pure PowerShell shim for
        Describe/Context/It/BeforeAll/AfterAll/BeforeEach/Should and executes this
        exact file, so the same assertions are the single source of truth.

    Safety rules for these tests:
      - every fixture is created below %TEMP% and removed afterwards,
      - no test deletes or overwrites anything outside %TEMP%,
      - real paths such as C:\ or $env:USERPROFILE are only passed through the
        policy functions / command scanner, never to a filesystem operation.
#>

Describe 'SafeDelete module contract' {

    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:ModulePath = Join-Path (Join-Path $script:RepoRoot 'SafeDelete') 'SafeDelete.psd1'
        Import-Module $script:ModulePath -Force
    }

    It 'imports the module manifest' {
        $module = Get-Module -Name SafeDelete
        $module | Should -Not -BeNullOrEmpty
        $module.Version.ToString() | Should -Be '0.1.0'
    }

    It 'exports all documented functions' {
        $expected = @(
            'Assert-SafePath'
            'Test-SafePath'
            'Remove-SafeItem'
            'Test-SafeMirrorTarget'
            'Invoke-SafeRobocopy'
            'Test-DangerousCommandLine'
            'Register-SafeDeleteDeniedPath'
            'Get-SafeDeleteProtectedPath'
        )
        foreach ($name in $expected) {
            $command = Get-Command -Name $name -Module SafeDelete -ErrorAction SilentlyContinue
            $command | Should -Not -BeNullOrEmpty
        }
        @($expected).Count | Should -Be 8
    }

    It 'has a valid module manifest' {
        $manifest = Test-ModuleManifest -Path $script:ModulePath
        $manifest.Version.ToString() | Should -Be '0.1.0'
        $manifest.PowerShellVersion.ToString() | Should -Be '5.1'
        @($manifest.ExportedFunctions.Keys).Count | Should -Be 8
    }

    It 'reports the built-in protected locations' {
        $report = Get-SafeDeleteProtectedPath
        $report.UserProfile | Should -Be $env:USERPROFILE
        $report.ModuleRoot | Should -Match 'SafeDelete$'
        @($report.ProtectedDirectoryNames) | Should -Contain 'Windows'
        @($report.ProtectedDirectoryNames) | Should -Contain 'Program Files'
        @($report.DshSegments) | Should -Contain '.dsh'
    }

    It 'exposes only the intended public functions' {
        $publicFunctions = @(Get-Command -Module SafeDelete -CommandType Function | Select-Object -ExpandProperty Name)
        $publicFunctions.Count | Should -Be 8
        $publicFunctions | Should -Contain 'Remove-SafeItem'
        $publicFunctions | Should -Not -Contain 'Get-SafeDeleteCanonical'
    }
}

Describe 'Assert-SafePath / Test-SafePath - canonicalization' {

    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        Import-Module (Join-Path $script:RepoRoot 'SafeDelete\SafeDelete.psd1') -Force
        $script:TempRoot = Join-Path $env:TEMP ('sd-policy-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:Allowed = Join-Path $script:TempRoot 'allowed'
        New-Item -ItemType Directory -Path $script:Allowed -Force | Out-Null
    }

    AfterAll {
        if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) {
            try {
                Remove-SafeItem -Path $script:TempRoot -AllowedRoot $env:TEMP -Confirm:$false -ErrorAction Stop
            }
            catch {
                try { [System.IO.Directory]::Delete('\\?\' + $script:TempRoot, $true) }
                catch { Write-Warning ('無法清除測試資料夾：' + $_.Exception.Message) }
            }
        }
    }

    It 'returns the canonical absolute path for a normal folder' {
        $canonical = Assert-SafePath -Path $script:Allowed
        $canonical | Should -Be $script:Allowed.TrimEnd('\')
        ($canonical -is [string]) | Should -BeTrue
    }

    It 'trims trailing separators and resolves dot segments' {
        $withTrailingSlash = $script:Allowed + '\'
        (Assert-SafePath -Path $withTrailingSlash) | Should -Be $script:Allowed

        $withDot = $script:Allowed + '\.\child'
        (Assert-SafePath -Path $withDot) | Should -Be (Join-Path $script:Allowed 'child')

        $withParent = $script:Allowed + '\child\..'
        (Assert-SafePath -Path $withParent) | Should -Be $script:Allowed
    }

    It 'accepts a normal %TEMP% folder and reports reason Ok' {
        $result = Test-SafePath -Path $script:Allowed -Detailed
        $result.IsSafe | Should -BeTrue
        $result.ReasonCode | Should -Be 'Ok'
        $result.CanonicalPath | Should -Be $script:Allowed
        (Test-SafePath -Path $script:Allowed) | Should -BeTrue
    }

    It 'rejects drive root C:\' {
        { Assert-SafePath -Path 'C:\' } | Should -Throw
        (Test-SafePath -Path 'C:\' -Detailed).ReasonCode | Should -Be 'DriveRoot'
        (Test-SafePath -Path 'C:\') | Should -BeFalse
    }

    It 'rejects drive root without backslash C:' {
        { Assert-SafePath -Path 'C:' } | Should -Throw
        (Test-SafePath -Path 'C:' -Detailed).ReasonCode | Should -Be 'DriveRoot'
    }

    It 'rejects any other drive root' {
        (Test-SafePath -Path 'Q:\' -Detailed).ReasonCode | Should -Be 'DriveRoot'
        (Test-SafePath -Path 'D:\' -Detailed).ReasonCode | Should -Be 'DriveRoot'
    }

    It 'rejects an empty path' {
        { Assert-SafePath -Path '' } | Should -Throw
        (Test-SafePath -Path '' -Detailed).ReasonCode | Should -Be 'EmptyPath'
        { Assert-SafePath -Path $null } | Should -Throw
        (Test-SafePath -Path $null -Detailed).ReasonCode | Should -Be 'EmptyPath'
    }

    It 'rejects a whitespace-only path' {
        { Assert-SafePath -Path '   ' } | Should -Throw
        (Test-SafePath -Path '   ' -Detailed).ReasonCode | Should -Be 'EmptyPath'
    }

    It 'rejects the user profile' {
        { Assert-SafePath -Path $env:USERPROFILE } | Should -Throw
        (Test-SafePath -Path $env:USERPROFILE -Detailed).ReasonCode | Should -Be 'UserProfile'
    }

    It 'rejects the user profile with a trailing slash' {
        { Assert-SafePath -Path ($env:USERPROFILE + '\') } | Should -Throw
        (Test-SafePath -Path ($env:USERPROFILE + '\') -Detailed).ReasonCode | Should -Be 'UserProfile'
    }

    It 'rejects the users root' {
        $usersRoot = Split-Path -Parent $env:USERPROFILE
        (Test-SafePath -Path $usersRoot -Detailed).ReasonCode | Should -Be 'UsersRoot'
    }

    It 'rejects .dsh directories at any depth' {
        $dshRoot = Join-Path $env:USERPROFILE '.dsh'
        (Test-SafePath -Path $dshRoot -Detailed).ReasonCode | Should -Be 'DshDirectory'
        (Test-SafePath -Path (Join-Path $dshRoot 'profiles') -Detailed).ReasonCode | Should -Be 'DshDirectory'
    }

    It 'rejects Windows and Windows subdirectories' {
        (Test-SafePath -Path $env:SystemRoot -Detailed).ReasonCode | Should -Be 'SystemDirectory'
        (Test-SafePath -Path (Join-Path $env:SystemRoot 'System32') -Detailed).ReasonCode | Should -Be 'SystemDirectory'
    }

    It 'rejects Program Files and ProgramData' {
        (Test-SafePath -Path ${env:ProgramFiles} -Detailed).ReasonCode | Should -Be 'SystemDirectory'
        if (${env:ProgramFiles(x86)}) {
            (Test-SafePath -Path ${env:ProgramFiles(x86)} -Detailed).ReasonCode | Should -Be 'SystemDirectory'
        }
        (Test-SafePath -Path $env:ProgramData -Detailed).ReasonCode | Should -Be 'SystemDirectory'
    }

    It 'rejects the module own directory' {
        $moduleRoot = (Get-SafeDeleteProtectedPath).ModuleRoot
        (Test-SafePath -Path $moduleRoot -Detailed).ReasonCode | Should -Be 'ScriptDirectory'
        (Test-SafePath -Path (Join-Path $moduleRoot 'SafeDelete.psm1') -Detailed).ReasonCode | Should -Be 'ScriptDirectory'
    }

    It 'rejects paths below the caller script directory' {
        $fakeScriptDir = Join-Path $script:TempRoot 'fake-script-dir'
        New-Item -ItemType Directory -Path $fakeScriptDir -Force | Out-Null
        (Test-SafePath -Path $fakeScriptDir -ScriptRoot $fakeScriptDir -Detailed).ReasonCode | Should -Be 'ScriptDirectory'
        (Test-SafePath -Path (Join-Path $fakeScriptDir 'work') -ScriptRoot $fakeScriptDir -Detailed).ReasonCode | Should -Be 'ScriptDirectory'
    }

    It 'rejects an invalid script root' {
        (Test-SafePath -Path $script:Allowed -ScriptRoot 'C:' -Detailed).ReasonCode | Should -Be 'InvalidScriptRoot'
    }

    It 'rejects relative paths by default' {
        { Assert-SafePath -Path '.' } | Should -Throw
        { Assert-SafePath -Path '.\child' } | Should -Throw
        (Test-SafePath -Path '.\child' -Detailed).ReasonCode | Should -Be 'RelativePath'
        (Test-SafePath -Path '\rooted' -Detailed).ReasonCode | Should -Be 'RelativePath'
    }

    It 'rejects drive relative paths' {
        (Test-SafePath -Path 'C:foo' -Detailed).ReasonCode | Should -Be 'DriveRelativePath'
        { Assert-SafePath -Path 'C:foo' } | Should -Throw
    }

    It 'resolves a relative path when AllowRelative is explicit' {
        Push-Location -LiteralPath $script:Allowed
        try {
            $resolved = Assert-SafePath -Path '.\child' -AllowRelative
        }
        finally {
            Pop-Location
        }
        $resolved | Should -Be (Join-Path $script:Allowed 'child')
    }

    It 'rejects wildcards' {
        $wildcard = Join-Path $script:Allowed '*'
        (Test-SafePath -Path $wildcard -Detailed).ReasonCode | Should -Be 'Wildcard'
        (Test-SafePath -Path (Join-Path $script:Allowed 'a?b') -Detailed).ReasonCode | Should -Be 'Wildcard'
    }

    It 'rejects device paths' {
        (Test-SafePath -Path '\\.\C:' -Detailed).ReasonCode | Should -Be 'DevicePath'
    }

    It 'rejects alternate data streams' {
        (Test-SafePath -Path (Join-Path $script:Allowed 'file.txt:stream') -Detailed).ReasonCode | Should -Be 'InvalidPath'
    }

    It 'rejects a UNC share root' {
        (Test-SafePath -Path '\\fileserver\backups' -Detailed).ReasonCode | Should -Be 'ShareRoot'
        (Test-SafePath -Path '\\fileserver\backups\' -Detailed).ReasonCode | Should -Be 'ShareRoot'
    }

    It 'supports strict AllowedRoot allowlist mode' {
        $nested = Join-Path $script:Allowed 'nested'
        (Test-SafePath -Path $nested -AllowedRoot $script:Allowed) | Should -BeTrue

        (Test-SafePath -Path $script:TempRoot -AllowedRoot $script:Allowed -Detailed).ReasonCode | Should -Be 'OutsideAllowedRoot'
        { Assert-SafePath -Path $script:TempRoot -AllowedRoot $script:Allowed } | Should -Throw
    }

    It 'rejects an invalid AllowedRoot' {
        (Test-SafePath -Path $script:Allowed -AllowedRoot 'C:\' -Detailed).ReasonCode | Should -Be 'InvalidAllowedRoot'
        (Test-SafePath -Path $script:Allowed -AllowedRoot (Join-Path $script:TempRoot 'does-not-exist') -Detailed).ReasonCode | Should -Be 'InvalidAllowedRoot'
        (Test-SafePath -Path $script:Allowed -AllowedRoot $env:USERPROFILE -Detailed).ReasonCode | Should -Be 'InvalidAllowedRoot'
    }

    It 'supports DenyPath' {
        $denied = Join-Path $script:TempRoot 'deny-param'
        New-Item -ItemType Directory -Path $denied -Force | Out-Null
        (Test-SafePath -Path (Join-Path $denied 'x') -DenyPath $denied -Detailed).ReasonCode | Should -Be 'DeniedPath'
        { Assert-SafePath -Path (Join-Path $denied 'x') -DenyPath $denied } | Should -Throw
    }

    It 'supports Register-SafeDeleteDeniedPath and -Remove' {
        $registered = Join-Path $script:TempRoot 'deny-registered'
        New-Item -ItemType Directory -Path $registered -Force | Out-Null
        Register-SafeDeleteDeniedPath -Path $registered
        try {
            (Test-SafePath -Path (Join-Path $registered 'x') -Detailed).ReasonCode | Should -Be 'DeniedPath'
        }
        finally {
            Register-SafeDeleteDeniedPath -Path $registered -Remove
        }
        (Test-SafePath -Path (Join-Path $registered 'x')) | Should -BeTrue
    }

    It 'supports ExpectedLeafName with exact and wildcard patterns' {
        $work = Join-Path $script:Allowed 'dsh-work'
        (Test-SafePath -Path $work -ExpectedLeafName 'dsh-work') | Should -BeTrue
        (Test-SafePath -Path $work -ExpectedLeafName 'dsh-*') | Should -BeTrue
        (Test-SafePath -Path $work -ExpectedLeafName 'other-*' -Detailed).ReasonCode | Should -Be 'UnexpectedLeafName'
        { Assert-SafePath -Path $work -ExpectedLeafName 'other-*' } | Should -Throw
    }

    It 'compares paths case insensitively' {
        (Test-SafePath -Path $script:Allowed.ToUpperInvariant() -AllowedRoot $env:TEMP) | Should -BeTrue
    }

    It 'treats every path below the user profile as usable (except protected names)' {
        $documents = Join-Path $env:USERPROFILE 'Documents'
        (Test-SafePath -Path $documents) | Should -BeTrue
    }
}

Describe 'Remove-SafeItem' {

    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        Import-Module (Join-Path $script:RepoRoot 'SafeDelete\SafeDelete.psd1') -Force
        $script:TempRoot = Join-Path $env:TEMP ('sd-remove-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:Allowed = Join-Path $script:TempRoot 'allowed'
        New-Item -ItemType Directory -Path $script:Allowed -Force | Out-Null
    }

    AfterAll {
        if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) {
            try {
                Remove-SafeItem -Path $script:TempRoot -AllowedRoot $env:TEMP -Confirm:$false -ErrorAction Stop
            }
            catch {
                try { [System.IO.Directory]::Delete('\\?\' + $script:TempRoot, $true) }
                catch { Write-Warning ('無法清除測試資料夾：' + $_.Exception.Message) }
            }
        }
    }

    It 'supports -WhatIf semantics' {
        $parameters = (Get-Command -Name Remove-SafeItem).Parameters
        $parameters.ContainsKey('WhatIf') | Should -BeTrue
        $parameters.ContainsKey('Confirm') | Should -BeTrue
    }

    It 'deletes a normal folder tree inside %TEMP%' {
        $work = Join-Path $script:Allowed 'work'
        $sub = Join-Path $work 'sub'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $work 'a.txt') -Value 'a' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $sub 'b.txt') -Value 'b' -Encoding ASCII
        $sibling = Join-Path $script:Allowed 'sibling.txt'
        Set-Content -LiteralPath $sibling -Value 'keep' -Encoding ASCII

        Remove-SafeItem -Path $work -AllowedRoot $env:TEMP -Confirm:$false

        (Test-Path -LiteralPath $work) | Should -BeFalse
        (Test-Path -LiteralPath $sibling) | Should -BeTrue
    }

    It 'deletes a single file' {
        $file = Join-Path $script:Allowed 'single.txt'
        Set-Content -LiteralPath $file -Value 'x' -Encoding ASCII
        Remove-SafeItem -Path $file -AllowedRoot $env:TEMP -Confirm:$false
        (Test-Path -LiteralPath $file) | Should -BeFalse
    }

    It 'does not delete anything with -WhatIf' {
        $work = Join-Path $script:Allowed 'whatif'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $work 'file.txt') -Value 'x' -Encoding ASCII

        Remove-SafeItem -Path $work -AllowedRoot $env:TEMP -WhatIf

        (Test-Path -LiteralPath $work) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $work 'file.txt')) | Should -BeTrue
    }

    It 'supports -KeepRoot to empty a folder but keep it' {
        $work = Join-Path $script:Allowed 'keeproot'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $work 'file.txt') -Value 'x' -Encoding ASCII

        Remove-SafeItem -Path $work -AllowedRoot $env:TEMP -KeepRoot -Confirm:$false

        (Test-Path -LiteralPath $work) | Should -BeTrue
        @(Get-ChildItem -LiteralPath $work -Force).Count | Should -Be 0
    }

    It 'removes a junction as a link only and keeps the target' {
        $target = Join-Path $script:Allowed 'junction-target'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'keep.txt') -Value 'keep' -Encoding ASCII
        $link = Join-Path $script:Allowed 'junction-link'
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null

        Remove-SafeItem -Path $link -AllowedRoot $env:TEMP -Confirm:$false

        (Test-Path -LiteralPath $link) | Should -BeFalse
        (Test-Path -LiteralPath $target) | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $target 'keep.txt') -Raw).Trim() | Should -Be 'keep'
    }

    It 'never traverses junctions inside a deleted tree' {
        $outside = Join-Path $script:Allowed 'outside-target'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'must-survive.txt') -Value 'survive' -Encoding ASCII

        $tree = Join-Path $script:Allowed 'tree-with-link'
        New-Item -ItemType Directory -Path $tree -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $tree 'own.txt') -Value 'own' -Encoding ASCII
        $innerLink = Join-Path $tree 'inner-link'
        New-Item -ItemType Junction -Path $innerLink -Target $outside | Out-Null

        Remove-SafeItem -Path $tree -AllowedRoot $env:TEMP -Confirm:$false

        (Test-Path -LiteralPath $tree) | Should -BeFalse
        (Test-Path -LiteralPath $outside) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $outside 'must-survive.txt')) | Should -BeTrue
    }

    It 'deletes hidden and read-only files inside a tree' {
        $work = Join-Path $script:Allowed 'attributes'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $hidden = Join-Path $work 'hidden.txt'
        Set-Content -LiteralPath $hidden -Value 'x' -Encoding ASCII
        (Get-Item -LiteralPath $hidden -Force).Attributes = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::ReadOnly

        Remove-SafeItem -Path $work -AllowedRoot $env:TEMP -Confirm:$false

        (Test-Path -LiteralPath $work) | Should -BeFalse
    }

    It 'refuses the drive root' {
        { Remove-SafeItem -Path 'C:\' -WhatIf } | Should -Throw
        (Test-SafePath -Path 'C:\') | Should -BeFalse
    }

    It 'refuses the user profile' {
        { Remove-SafeItem -Path $env:USERPROFILE -WhatIf } | Should -Throw
    }

    It 'refuses paths outside the allowlist without deleting them' {
        $outside = Join-Path $script:TempRoot 'outside-allowlist'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'file.txt') -Value 'x' -Encoding ASCII

        { Remove-SafeItem -Path $outside -AllowedRoot $script:Allowed -Confirm:$false } | Should -Throw
        (Test-Path -LiteralPath $outside) | Should -BeTrue
    }

    It 'throws for a missing target instead of silently succeeding' {
        $missing = Join-Path $script:Allowed 'missing-folder'
        { Remove-SafeItem -Path $missing -AllowedRoot $env:TEMP -Confirm:$false } | Should -Throw
    }

    It 'returns a PassThru summary' {
        $work = Join-Path $script:Allowed 'passthru'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $work 'one.txt') -Value '1' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $work 'two.txt') -Value '2' -Encoding ASCII

        $summary = Remove-SafeItem -Path $work -AllowedRoot $env:TEMP -Confirm:$false -PassThru

        $summary.Removed | Should -Be 3
        $summary.KeptRoot | Should -BeFalse
        (Test-Path -LiteralPath $work) | Should -BeFalse
    }

    It 'handles paths longer than MAX_PATH' {
        $longRoot = Join-Path $script:Allowed 'longpath'
        [void][System.IO.Directory]::CreateDirectory('\\?\' + $longRoot)
        $current = $longRoot
        $segment = 'd' + ('x' * 40)
        for ($index = 1; $index -le 6; $index++) {
            $current = Join-Path $current ($segment + $index)
            [void][System.IO.Directory]::CreateDirectory('\\?\' + $current)
        }
        [System.IO.File]::WriteAllText('\\?\' + (Join-Path $current 'leaf.txt'), 'long path')

        $current.Length | Should -BeGreaterThan 260
        (Test-SafePath -Path $current -AllowedRoot $env:TEMP) | Should -BeTrue

        Remove-SafeItem -Path $current -AllowedRoot $env:TEMP -Confirm:$false

        [System.IO.Directory]::Exists('\\?\' + $current) | Should -BeFalse
    }
}

Describe 'Test-SafeMirrorTarget / Invoke-SafeRobocopy' {

    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        Import-Module (Join-Path $script:RepoRoot 'SafeDelete\SafeDelete.psd1') -Force
        $script:TempRoot = Join-Path $env:TEMP ('sd-mirror-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

        $script:Source = Join-Path $script:TempRoot 'source'
        New-Item -ItemType Directory -Path $script:Source -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Source 'data.txt') -Value 'payload' -Encoding ASCII

        $script:Destination = Join-Path $script:TempRoot 'destination'
        New-Item -ItemType Directory -Path $script:Destination -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Destination '.backup-target') -Value 'marker' -Encoding ASCII
    }

    AfterAll {
        if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) {
            try {
                Remove-SafeItem -Path $script:TempRoot -AllowedRoot $env:TEMP -Confirm:$false -ErrorAction Stop
            }
            catch {
                try { [System.IO.Directory]::Delete('\\?\' + $script:TempRoot, $true) }
                catch { Write-Warning ('無法清除測試資料夾：' + $_.Exception.Message) }
            }
        }
    }

    It 'accepts a valid mirror target with a marker file' {
        $result = Test-SafeMirrorTarget -Source $script:Source -Destination $script:Destination
        $result.IsSafe | Should -BeTrue
        $result.MarkerFound | Should -BeTrue
        $result.CommandLine | Should -Match '/MIR'
        $result.CommandLine | Should -Match '/XJ'
        @($result.Reasons).Count | Should -Be 0
    }

    It 'rejects the drive root as destination' {
        $result = Test-SafeMirrorTarget -Source $script:Source -Destination 'C:\'
        $result.IsSafe | Should -BeFalse
        ($result.Reasons -join ' ') | Should -Match 'DriveRoot'
    }

    It 'rejects the user profile as destination' {
        $result = Test-SafeMirrorTarget -Source $script:Source -Destination $env:USERPROFILE
        $result.IsSafe | Should -BeFalse
        ($result.Reasons -join ' ') | Should -Match 'UserProfile'
    }

    It 'rejects a destination without marker file' {
        $plain = Join-Path $script:TempRoot 'no-marker'
        New-Item -ItemType Directory -Path $plain -Force | Out-Null
        $result = Test-SafeMirrorTarget -Source $script:Source -Destination $plain
        $result.IsSafe | Should -BeFalse
        ($result.Reasons -join ' ') | Should -Match 'marker'
    }

    It 'accepts an unmarked destination when -AllowUnmarked is explicit' {
        $plain = Join-Path $script:TempRoot 'unmarked-ok'
        New-Item -ItemType Directory -Path $plain -Force | Out-Null
        $result = Test-SafeMirrorTarget -Source $script:Source -Destination $plain -AllowUnmarked
        $result.IsSafe | Should -BeTrue
        $result.MarkerFound | Should -BeFalse
    }

    It 'requires -AllowCreate for a missing destination' {
        $missing = Join-Path $script:TempRoot 'new-destination'
        (Test-SafeMirrorTarget -Source $script:Source -Destination $missing).IsSafe | Should -BeFalse
        (Test-SafeMirrorTarget -Source $script:Source -Destination $missing -AllowCreate).IsSafe | Should -BeTrue
    }

    It 'rejects source equal to destination' {
        $result = Test-SafeMirrorTarget -Source $script:Source -Destination $script:Source -AllowUnmarked
        $result.IsSafe | Should -BeFalse
        ($result.Reasons -join ' ') | Should -Match '同一個'
    }

    It 'rejects a destination inside the source' {
        $inside = Join-Path $script:Source 'mirror-inside'
        New-Item -ItemType Directory -Path $inside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $inside '.backup-target') -Value 'm' -Encoding ASCII
        $result = Test-SafeMirrorTarget -Source $script:Source -Destination $inside
        $result.IsSafe | Should -BeFalse
        ($result.Reasons -join ' ') | Should -Match '來源之下'
    }

    It 'rejects a missing source' {
        $result = Test-SafeMirrorTarget -Source (Join-Path $script:TempRoot 'no-source') -Destination $script:Destination
        $result.IsSafe | Should -BeFalse
        ($result.Reasons -join ' ') | Should -Match '來源'
    }

    It 'refuses to run robocopy against a protected destination' {
        { Invoke-SafeRobocopy -Source $script:Source -Destination 'C:\' -WhatIf } | Should -Throw
    }

    It 'does not run robocopy with -WhatIf' {
        $before = @(Get-ChildItem -LiteralPath $script:Destination -Force).Count
        Invoke-SafeRobocopy -Source $script:Source -Destination $script:Destination -WhatIf
        $after = @(Get-ChildItem -LiteralPath $script:Destination -Force).Count
        $after | Should -Be $before
        (Test-Path -LiteralPath (Join-Path $script:Destination 'data.txt')) | Should -BeFalse
    }

    It 'does not create a missing destination with -WhatIf' {
        $missing = Join-Path $script:TempRoot 'not-created'
        Invoke-SafeRobocopy -Source $script:Source -Destination $missing -AllowCreate -WhatIf
        (Test-Path -LiteralPath $missing) | Should -BeFalse
    }
}

Describe 'Test-DangerousCommandLine' {

    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        Import-Module (Join-Path $script:RepoRoot 'SafeDelete\SafeDelete.psd1') -Force
    }

    It 'detects the incident command rd /s /q "C:\"' {
        $result = Test-DangerousCommandLine -CommandLine 'cmd /c rd /s /q "C:\"'
        $result.IsDangerous | Should -BeTrue
        $result.RiskLevel | Should -Be 'High'
        $result.RequiresApproval | Should -BeTrue
        @($result.Matched) | Should -Contain 'RecursiveDirectoryDelete'
        $result.TargetKnown | Should -BeTrue
        $result.TargetSafe | Should -BeFalse
        ($result.Reasons -join ' ') | Should -Match 'DriveRoot'
    }

    It 'marks rd /s /q without a target as dangerous and unknown' {
        $result = Test-DangerousCommandLine -CommandLine 'rd /s /q'
        $result.IsDangerous | Should -BeTrue
        $result.TargetKnown | Should -BeFalse
        $result.TargetSafe | Should -BeFalse
        ($result.Reasons -join ' ') | Should -Match '無法判定'
    }

    It 'detects Remove-Item -Recurse against the user profile' {
        $result = Test-DangerousCommandLine -CommandLine 'Remove-Item -Recurse -Force "C:\Users\user"'
        $result.IsDangerous | Should -BeTrue
        @($result.Matched) | Should -Contain 'RemoveItemRecurse'
        $result.TargetSafe | Should -BeFalse
        ($result.Reasons -join ' ') | Should -Match 'UserProfile'
    }

    It 'detects robocopy /MIR' {
        $result = Test-DangerousCommandLine -CommandLine 'robocopy C:\source D:\mirror /MIR'
        $result.IsDangerous | Should -BeTrue
        @($result.Matched) | Should -Contain 'RobocopyMirror'
    }

    It 'detects del /f /s /q with a wildcard target' {
        $result = Test-DangerousCommandLine -CommandLine 'del /f /s /q "C:\work\*"'
        $result.IsDangerous | Should -BeTrue
        @($result.Matched) | Should -Contain 'RecursiveFileDelete'
        @($result.Matched) | Should -Contain 'ForceQuietFileDelete'
        $result.TargetSafe | Should -BeFalse
    }

    It 'detects rm -rf' {
        $result = Test-DangerousCommandLine -CommandLine 'rm -rf /'
        $result.IsDangerous | Should -BeTrue
        @($result.Matched) | Should -Contain 'UnixRmRecursiveForce'
        $result.TargetKnown | Should -BeFalse
    }

    It 'detects Format-Volume' {
        $result = Test-DangerousCommandLine -CommandLine 'Format-Volume -DriveLetter D -Confirm:$false'
        $result.IsDangerous | Should -BeTrue
        @($result.Matched) | Should -Contain 'FormatVolume'
    }

    It 'detects vssadmin delete shadows' {
        $result = Test-DangerousCommandLine -CommandLine 'vssadmin delete shadows /all /quiet'
        $result.IsDangerous | Should -BeTrue
        @($result.Matched) | Should -Contain 'VssDeleteShadows'
    }

    It 'does not flag a plain read only command' {
        $result = Test-DangerousCommandLine -CommandLine 'Get-ChildItem -Path C:\data -File'
        $result.IsDangerous | Should -BeFalse
        $result.RiskLevel | Should -Be 'None'
        @($result.Matched).Count | Should -Be 0
    }

    It 'does not flag Remove-Item without -Recurse' {
        $result = Test-DangerousCommandLine -CommandLine 'Remove-Item -Path "$env:TEMP\scan-only" -Force'
        $result.IsDangerous | Should -BeFalse
    }

    It 'does not flag robocopy without /MIR' {
        $result = Test-DangerousCommandLine -CommandLine 'robocopy C:\source D:\mirror /E'
        $result.IsDangerous | Should -BeFalse
    }

    It 'reports a safe concrete target as TargetSafe' {
        $safeTarget = Join-Path $env:TEMP 'safedelete-scan-target'
        $commandLine = 'rd /s /q "' + $safeTarget + '"'
        $result = Test-DangerousCommandLine -CommandLine $commandLine
        $result.IsDangerous | Should -BeTrue
        $result.TargetKnown | Should -BeTrue
        $result.TargetSafe | Should -BeTrue
    }

    It 'accepts pipeline input and returns one object per command' {
        $results = @(@('rd /s /q "C:\"', 'echo hello') | Test-DangerousCommandLine)
        $results.Count | Should -Be 2
        $results[0].IsDangerous | Should -BeTrue
        $results[1].IsDangerous | Should -BeFalse
    }

    It 'returns target assessments for the drive root' {
        $result = Test-DangerousCommandLine -CommandLine 'rd /s /q "C:\"'
        @($result.TargetAssessments).Count | Should -BeGreaterThan 0
        $unsafe = @($result.TargetAssessments | Where-Object { -not $_.IsSafe })
        $unsafe.Count | Should -BeGreaterThan 0
        $unsafe[0].ReasonCode | Should -Be 'DriveRoot'
    }
}
