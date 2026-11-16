#Requires -Version 5.1
<#
    Module manifest for SafeDelete.

    SafeDelete is a fail-closed path guard plus safe delete / robocopy /MIR helper for
    PowerShell 5.1+.  It exists because of the 2026-11-16 incident where an
    un-canonicalized -Dest "C:\" was fed to `cmd /c rd /s /q "C:\"`.
#>
@{
    RootModule           = 'SafeDelete.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '7f3c2a1e-9b4d-4f6a-8c2e-1d5b7a9c3e21'
    Author               = 'treesess'
    CompanyName          = 'SafeDelete contributors'
    Copyright            = '(c) 2026 treesess. MIT License.'
    Description          = 'Fail-closed path guard and safe delete helper for PowerShell 5.1+. Canonicalizes paths, rejects drive roots / user profiles / .dsh / system directories, deletes junctions as links only, guards robocopy /MIR targets and scans command lines for destructive verbs.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport = @(
        'Assert-SafePath'
        'Test-SafePath'
        'Remove-SafeItem'
        'Test-SafeMirrorTarget'
        'Invoke-SafeRobocopy'
        'Test-DangerousCommandLine'
        'Register-SafeDeleteDeniedPath'
        'Get-SafeDeleteProtectedPath'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Safety', 'Delete', 'FileSystem', 'Guard', 'PowerShell', 'Windows')
            LicenseUri   = 'https://opensource.org/licenses/MIT'
            ProjectUri   = 'https://github.com/treesess'
            ReleaseNotes = @'
0.1.0 - Initial release.
- Assert-SafePath / Test-SafePath: canonicalization + fail-closed policy (drive roots,
  user profiles, .dsh, Windows / Program Files* / ProgramData, script directory,
  relative paths, wildcards, device paths, ADS), allowlist mode, deny lists,
  expected leaf name.
- Remove-SafeItem: SupportsShouldProcess + ConfirmImpact High, junction/symlink link-only
  removal, managed recursion that never follows reparse points, long path (\\?\) support.
- Test-SafeMirrorTarget / Invoke-SafeRobocopy: source/destination validation and marker
  file requirement before robocopy /MIR.
- Test-DangerousCommandLine: destructive command heuristic for agent/scheduler gates.
'@
        }
    }
}
