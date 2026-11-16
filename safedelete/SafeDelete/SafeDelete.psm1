#Requires -Version 5.1
<#
.SYNOPSIS
    SafeDelete - a fail-closed path guard and safe delete helper for PowerShell 5.1+.

.DESCRIPTION
    SafeDelete exists because of a real incident (2026-11-16): a PowerShell script
    received -Dest "C:\", did not canonicalize it, and executed
    `cmd /c rd /s /q "C:\"`.  The path checks compared GetFullPath("C:\") (which keeps
    the trailing backslash) with GetFullPath($env:USERPROFILE), so the drive root
    slipped through and a whole data tree was deleted.

    This module fixes that class of bug by making every destructive operation start
    from a canonical path and a fail-closed policy check:

      1. Assert-SafePath / Test-SafePath
           canonicalize (GetFullPath + TrimEnd('\')) and reject, with a machine
           readable reason code, empty paths, drive roots, user home directories,
           .dsh directories, Windows / Program Files* / ProgramData, the script's own
           directory, relative paths (unless explicitly allowed), wildcards, device
           paths and alternate data streams.  -AllowedRoot turns the check into a
           strict allowlist mode; -DenyPath / Register-SafeDeleteDeniedPath add
           explicit denials; -ExpectedLeafName enforces the expected leaf name.

      2. Remove-SafeItem
           [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')].  Asserts the
           path first, then deletes.  Junctions and directory symlinks are removed as
           links only (`cmd /c rmdir`); the link target is never touched.  Recursion is
           implemented in managed code and treats every reparse point as a link, so a
           junction inside a tree is never traversed.  Long paths (> MAX_PATH) are
           handled with the \\?\ extended prefix.  The whole operation is a single
           ShouldProcess target, so -WhatIf / -Confirm work as expected.

      3. Test-SafeMirrorTarget / Invoke-SafeRobocopy
           Validate a robocopy /MIR source and destination before anything runs:
           source must exist, destination must be a marker-bearing folder
           (.backup-target by default), and destination must not be a drive root, a
           protected path, the source itself or a folder inside the source.

      4. Test-DangerousCommandLine
           Static scanner for command strings that contain destructive verbs
           (rd /s, del /s, Remove-Item -Recurse, robocopy /MIR, rm -rf,
           Format-Volume, vssadmin delete shadows, ...).  It extracts candidate
           target paths and reports whether they pass the same SafeDelete policy.
           If a target cannot be determined it reports the command as dangerous
           (`TargetKnown = $false`).  It is a heuristic for agent/scheduler gates,
           not a security boundary.

    Design rules:
      - fail closed: unknown/ambiguous input is rejected, never guessed.
      - canonicalize before comparing: GetFullPath + TrimEnd('\') always.
      - never string-concatenate a user path into cmd.exe unless it was asserted.
      - never call Remove-Item -Recurse on a caller supplied path.
      - deleting a link never deletes the link target.

    All user facing messages are Traditional Chinese; code comments are English.

.NOTES
    PowerShell 5.1 (Desktop) and PowerShell 7 (Core) compatible.
    MIT License.  See README.md for usage and known limitations.
#>

Set-StrictMode -Version 2.0

$script:ModuleRoot = $PSScriptRoot

# Names of top level directories that are always protected when they are the first
# directory below a drive root (or below a UNC share root).
$script:ProtectedDirectoryNames = @(
    'Windows'
    'Windows.old'
    'Program Files'
    'Program Files (x86)'
    'ProgramData'
    'System Volume Information'
    '$Recycle.Bin'
    'Recovery'
    'PerfLogs'
    'Documents and Settings'
    'MSOCache'
    'Config.Msi'
)

$script:ReasonTexts = @{
    EmptyPath           = '路徑是空字串或只有空白；請傳入明確的絕對路徑。'
    InvalidPath         = '路徑格式無效或含有不合法字元。'
    Wildcard            = '路徑含萬用字元（* 或 ?）；刪除類操作一律不接受萬用字元。'
    RelativePath        = '不接受相對路徑；請改傳入絕對路徑，或在確認過解析結果後使用 -AllowRelative。'
    DriveRelativePath   = '不接受磁碟相對路徑（例如 C:foo）；請改傳入完整絕對路徑。'
    DriveRoot           = '拒絕操作磁碟根目錄（例如 C:\ 或 C:）；這是 2026-11-16 事故的起點，請改用系統工具並人工確認。'
    ShareRoot           = '拒絕操作網路共享根目錄（\\server\share）；請指定共享下的子資料夾。'
    DevicePath          = '拒絕裝置路徑（\\.\、\??\ 等）語法。'
    UserProfile         = '拒絕操作使用者主目錄（$env:USERPROFILE 或 C:\Users\<自己>）。'
    UsersRoot           = '拒絕操作使用者主目錄的上一層（例如 C:\Users）。'
    SystemDirectory     = '拒絕操作系統／程式目錄（Windows、Windows.old、Program Files、ProgramData、$Recycle.Bin 等）。'
    DshDirectory        = '拒絕操作 .dsh 目錄（其底下有 DSH 的 session 與 profile 資料）。'
    ScriptDirectory     = '拒絕操作腳本／模組自身所在目錄。'
    OutsideAllowedRoot  = '路徑不在 -AllowedRoot 白名單之內。'
    DeniedPath          = '路徑在明確拒絕清單（-DenyPath 或 Register-SafeDeleteDeniedPath）內。'
    UnexpectedLeafName  = '路徑最後一層名稱不符合 -ExpectedLeafName 的預期。'
    InvalidAllowedRoot  = 'AllowedRoot 本身無效、不存在，或指向受保護路徑。'
    InvalidDenyPath     = 'DenyPath 本身無效（無法正規化）。'
    InvalidScriptRoot   = 'ScriptRoot 本身無效（無法正規化）。'
    Ok                  = '路徑安全。'
}

# Module wide deny list, configurable with Register-SafeDeleteDeniedPath.
$script:RegisteredDeniedPaths = New-Object System.Collections.ArrayList

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

function ConvertTo-SafeDeleteExtendedPath {
    <#
    .SYNOPSIS
        Prefix an absolute path with \\?\ (or \\?\UNC\) so .NET accepts long paths.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Path.StartsWith('\\?\', [StringComparison]::Ordinal)) { return $Path }
    if ($Path.StartsWith('\\', [StringComparison]::Ordinal)) { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}

function ConvertFrom-SafeDeleteExtendedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Path.StartsWith('\\?\UNC\', [StringComparison]::Ordinal)) { return '\\' + $Path.Substring(8) }
    if ($Path.StartsWith('\\?\', [StringComparison]::Ordinal)) { return $Path.Substring(4) }
    return $Path
}

function Get-SafeDeleteSegments {
    <#
    .SYNOPSIS
        Split a canonical path into its root (C: or \\server\share) and relative segments.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CanonicalPath
    )

    $root = $null
    $rest = $null

    if ($CanonicalPath -match '^([A-Za-z]:)(\\|$)') {
        $root = $Matches[1]
        $rest = $CanonicalPath.Substring(2)
    }
    elseif ($CanonicalPath -match '^(\\\\[^\\]+\\[^\\]+)(\\|$)') {
        $root = $Matches[1]
        $rest = $CanonicalPath.Substring($root.Length)
    }
    else {
        return [pscustomobject]@{
            IsValid  = $false
            Root     = $null
            Segments = @()
        }
    }

    $rest = $rest.TrimStart('\')
    $segments = @()
    if ($rest.Length -gt 0) {
        $segments = @($rest -split '\\+')
    }

    return [pscustomobject]@{
        IsValid  = $true
        Root     = $root
        Segments = $segments
    }
}

function Test-SafeDeletePathWithin {
    <#
    .SYNOPSIS
        True when Child equals Parent or is below Parent (case insensitive, segment safe).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Child,
        [Parameter(Mandatory)]
        [string]$Parent
    )

    $childCanonical = $Child.TrimEnd('\', '/')
    $parentCanonical = $Parent.TrimEnd('\', '/')

    if ([string]::Equals($childCanonical, $parentCanonical, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return $childCanonical.StartsWith($parentCanonical + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-SafeDeleteCanonical {
    <#
    .SYNOPSIS
        Canonicalize a path string: validate syntax, resolve . and .., trim trailing separators.
    .DESCRIPTION
        Canonical form never ends with a backslash (except that drive roots are rejected
        with ReasonCode DriveRoot instead of being returned).  Returns an object with
        Ok / CanonicalPath / ReasonCode.  This function never touches the file system.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path,
        [switch]$AllowRelative
    )

    $result = [pscustomobject]@{
        Ok            = $false
        CanonicalPath = $null
        ReasonCode    = 'EmptyPath'
    }

    if ($null -eq $Path) { return $result }

    $raw = $Path.Trim()
    if ($raw.Length -eq 0) { return $result }

    # Strip extended path prefixes before doing any analysis; remember the original form.
    $work = $raw
    if ($work.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        $work = '\\' + $work.Substring(8)
    }
    elseif ($work.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
        $work = $work.Substring(4)
    }

    if ($work.StartsWith('\\.\', [StringComparison]::Ordinal) -or $work.StartsWith('\??\', [StringComparison]::Ordinal)) {
        $result.ReasonCode = 'DevicePath'
        return $result
    }

    if ($work -match '[*?]') {
        $result.ReasonCode = 'Wildcard'
        return $result
    }

    if ($work -match '[\x00-\x1F]') {
        $result.ReasonCode = 'InvalidPath'
        return $result
    }

    # Drive roots and root-relative paths are rejected before any resolution.
    if ($work -match '^[A-Za-z]:[\\/]+$' -or $work -match '^[A-Za-z]:$') {
        $result.ReasonCode = 'DriveRoot'
        $result.CanonicalPath = $work.Substring(0, 2)
        return $result
    }

    if ($work -match '^[\\/]+$') {
        $result.ReasonCode = 'DriveRoot'
        return $result
    }

    # Drive relative paths (C:foo) are ambiguous: always rejected, even with -AllowRelative.
    if ($work -match '^[A-Za-z]:(?![\\/])') {
        $result.ReasonCode = 'DriveRelativePath'
        return $result
    }

    $isAbsolute = ($work -match '^[A-Za-z]:[\\/]') -or ($work -match '^\\\\')
    if (-not $isAbsolute) {
        if (-not $AllowRelative) {
            $result.ReasonCode = 'RelativePath'
            return $result
        }

        # Resolve against the caller's PowerShell location (Push-Location / Set-Location),
        # not the process working directory, which .NET GetFullPath would use.
        try {
            $resolvedRelative = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($work)
        }
        catch {
            $result.ReasonCode = 'InvalidPath'
            return $result
        }
        if (-not $resolvedRelative -or $resolvedRelative -notmatch '^[A-Za-z]:[\\/]') {
            $result.ReasonCode = 'InvalidPath'
            return $result
        }
        $work = $resolvedRelative
    }

    # Long paths need the extended prefix even for GetFullPath on .NET Framework.
    $forFullPath = $work
    if ($forFullPath.Length -ge 240) {
        $forFullPath = '\\?\' + $forFullPath
    }

    try {
        $full = [System.IO.Path]::GetFullPath($forFullPath)
    }
    catch {
        $result.ReasonCode = 'InvalidPath'
        return $result
    }

    $full = ConvertFrom-SafeDeleteExtendedPath -Path $full
    $canonical = $full.TrimEnd('\', '/')

    if ($canonical -match '^[A-Za-z]:$') {
        $result.ReasonCode = 'DriveRoot'
        $result.CanonicalPath = $canonical
        return $result
    }

    if ($canonical -match '^\\\\[^\\]+$') {
        $result.ReasonCode = 'InvalidPath'
        return $result
    }

    if ($canonical -match '^\\\\[^\\]+\\[^\\]+$') {
        $result.ReasonCode = 'ShareRoot'
        $result.CanonicalPath = $canonical
        return $result
    }

    # Alternate data streams (a colon after the drive prefix) are not supported.
    if ($canonical -match '^[A-Za-z]:') {
        $remainder = $canonical.Substring(2)
        if ($remainder -match ':') {
            $result.ReasonCode = 'InvalidPath'
            return $result
        }
    }

    $result.Ok = $true
    $result.CanonicalPath = $canonical
    $result.ReasonCode = 'Ok'
    return $result
}

function Get-SafeDeleteReasonText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ReasonCode
    )

    if ($script:ReasonTexts.ContainsKey($ReasonCode)) {
        return $script:ReasonTexts[$ReasonCode]
    }

    return '未知原因代碼：' + $ReasonCode
}

function Set-SafeDeleteAssessmentReason {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Assessment,
        [Parameter(Mandatory)]
        [string]$ReasonCode
    )

    $Assessment.ReasonCode = $ReasonCode
    $Assessment.Reason = Get-SafeDeleteReasonText -ReasonCode $ReasonCode
    return $Assessment
}

function Get-SafeDeleteItemInfo {
    <#
    .SYNOPSIS
        Existence / type / reparse point information that also works for long paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $extended = ConvertTo-SafeDeleteExtendedPath -Path $Path
    $exists = $false
    $isDirectory = $false
    $isReparsePoint = $false
    $attributes = $null

    try {
        $attributes = [System.IO.File]::GetAttributes($extended)
        $exists = $true
        $isDirectory = (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0)
        $isReparsePoint = (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    }
    catch {
        # Broken junctions / symlinks can make the attribute call fail; fall back to
        # Get-Item for short paths (Get-Item does not resolve the link target).
        if ($Path.Length -lt 240) {
            try {
                $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
                $exists = $true
                $isDirectory = [bool]$item.PSIsContainer
                $isReparsePoint = (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
                $attributes = $item.Attributes
            }
            catch {
                $exists = $false
            }
        }
    }

    return [pscustomobject]@{
        Path           = $Path
        Exists         = $exists
        IsDirectory    = $isDirectory
        IsReparsePoint = $isReparsePoint
        Attributes     = $attributes
    }
}

function Test-SafeDeletePathExists {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $extended = ConvertTo-SafeDeleteExtendedPath -Path $Path
    if ([System.IO.File]::Exists($extended)) { return $true }
    if ([System.IO.Directory]::Exists($extended)) { return $true }
    return $false
}

function Test-SafeDeleteProtectedCanonical {
    <#
    .SYNOPSIS
        Policy check on an already canonical path.  Returns a reason code or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CanonicalPath,
        [string[]]$DenyPath,
        [string]$ScriptRootCanonical
    )

    $segments = Get-SafeDeleteSegments -CanonicalPath $CanonicalPath
    if (-not $segments.IsValid) { return 'InvalidPath' }
    $relative = @($segments.Segments)

    # .dsh anywhere in the tree (DSH sessions and profiles live there).
    foreach ($segment in $relative) {
        if ([string]::Equals($segment, '.dsh', [StringComparison]::OrdinalIgnoreCase)) {
            return 'DshDirectory'
        }
    }

    # The module's own directory.
    foreach ($root in @($script:ModuleRootCanonical)) {
        if ($root -and (Test-SafeDeletePathWithin -Child $CanonicalPath -Parent $root)) {
            return 'ScriptDirectory'
        }
    }

    # The caller's own script directory, when supplied.
    if ($ScriptRootCanonical) {
        if (Test-SafeDeletePathWithin -Child $CanonicalPath -Parent $ScriptRootCanonical) {
            return 'ScriptDirectory'
        }
    }

    # Explicit denies (parameter and module level).
    foreach ($root in @($DenyPath)) {
        if ($root -and (Test-SafeDeletePathWithin -Child $CanonicalPath -Parent $root)) {
            return 'DeniedPath'
        }
    }
    foreach ($root in $script:RegisteredDeniedPaths) {
        if ($root -and (Test-SafeDeletePathWithin -Child $CanonicalPath -Parent $root)) {
            return 'DeniedPath'
        }
    }

    if ($relative.Count -gt 0) {
        $first = $relative[0]

        # C:\Users, C:\Users\<name> (any drive letter) are protected; deeper user
        # folders (Downloads, AppData\..., project folders) remain usable.
        if ([string]::Equals($first, 'Users', [StringComparison]::OrdinalIgnoreCase)) {
            if ($relative.Count -eq 1) { return 'UsersRoot' }
            if ($relative.Count -eq 2) { return 'UserProfile' }
        }

        foreach ($name in $script:ProtectedDirectoryNames) {
            if ([string]::Equals($first, $name, [StringComparison]::OrdinalIgnoreCase)) {
                return 'SystemDirectory'
            }
        }
    }

    if ($script:UserProfileCanonical) {
        if ([string]::Equals($CanonicalPath.TrimEnd('\'), $script:UserProfileCanonical, [StringComparison]::OrdinalIgnoreCase)) {
            return 'UserProfile'
        }
    }

    # Defence in depth: roots should already have been rejected by Get-SafeDeleteCanonical.
    if ($CanonicalPath.TrimEnd('\') -match '^[A-Za-z]:$') { return 'DriveRoot' }
    if ($CanonicalPath.TrimEnd('\') -match '^\\\\[^\\]+\\[^\\]+$') { return 'ShareRoot' }

    return $null
}

function Get-SafeDeletePathAssessment {
    <#
    .SYNOPSIS
        Full policy assessment for a path.  Never touches the file system except for
        AllowedRoot validation (an allowlisted root must be an existing directory).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path,
        [string[]]$AllowedRoot,
        [string[]]$DenyPath,
        [string[]]$ExpectedLeafName,
        [string]$ScriptRoot,
        [switch]$AllowRelative
    )

    $canonical = Get-SafeDeleteCanonical -Path $Path -AllowRelative:$AllowRelative
    $assessment = [pscustomobject]@{
        Path          = $Path
        CanonicalPath = $canonical.CanonicalPath
        IsSafe        = $false
        ReasonCode    = $canonical.ReasonCode
        Reason        = ''
        LeafName      = $null
    }

    if (-not $canonical.Ok) {
        $assessment.Reason = Get-SafeDeleteReasonText -ReasonCode $canonical.ReasonCode
        return $assessment
    }

    $canonicalPath = $canonical.CanonicalPath
    $segments = Get-SafeDeleteSegments -CanonicalPath $canonicalPath
    if ($segments.IsValid -and @($segments.Segments).Count -gt 0) {
        $segmentList = @($segments.Segments)
        $assessment.LeafName = $segmentList[$segmentList.Count - 1]
    }

    # Caller script directory (optional, but validated when supplied).
    $scriptRootCanonical = $null
    if ($ScriptRoot) {
        $scriptRootInfo = Get-SafeDeleteCanonical -Path $ScriptRoot
        if (-not $scriptRootInfo.Ok) {
            return (Set-SafeDeleteAssessmentReason -Assessment $assessment -ReasonCode 'InvalidScriptRoot')
        }
        $scriptRootCanonical = $scriptRootInfo.CanonicalPath
    }

    # Explicit deny paths.
    $denyCanonical = New-Object System.Collections.ArrayList
    if ($DenyPath) {
        foreach ($denyEntry in $DenyPath) {
            $denyInfo = Get-SafeDeleteCanonical -Path $denyEntry
            if (-not $denyInfo.Ok) {
                return (Set-SafeDeleteAssessmentReason -Assessment $assessment -ReasonCode 'InvalidDenyPath')
            }
            [void]$denyCanonical.Add($denyInfo.CanonicalPath)
        }
    }

    # Allowlist mode: every allowlisted root must itself be valid and exist.
    $allowedCanonical = New-Object System.Collections.ArrayList
    $allowlistMode = $false
    if ($AllowedRoot -and @($AllowedRoot).Count -gt 0) {
        $allowlistMode = $true
        foreach ($rootEntry in $AllowedRoot) {
            $rootInfo = Get-SafeDeleteCanonical -Path $rootEntry
            if (-not $rootInfo.Ok) {
                return (Set-SafeDeleteAssessmentReason -Assessment $assessment -ReasonCode 'InvalidAllowedRoot')
            }
            $rootPolicy = Test-SafeDeleteProtectedCanonical -CanonicalPath $rootInfo.CanonicalPath -DenyPath $denyCanonical -ScriptRootCanonical $scriptRootCanonical
            if ($rootPolicy) {
                return (Set-SafeDeleteAssessmentReason -Assessment $assessment -ReasonCode 'InvalidAllowedRoot')
            }
            $rootItem = Get-SafeDeleteItemInfo -Path $rootInfo.CanonicalPath
            if (-not $rootItem.Exists -or -not $rootItem.IsDirectory) {
                return (Set-SafeDeleteAssessmentReason -Assessment $assessment -ReasonCode 'InvalidAllowedRoot')
            }
            [void]$allowedCanonical.Add($rootInfo.CanonicalPath)
        }
    }

    # Protected path policy.
    $protectedReason = Test-SafeDeleteProtectedCanonical -CanonicalPath $canonicalPath -DenyPath $denyCanonical -ScriptRootCanonical $scriptRootCanonical
    if ($protectedReason) {
        return (Set-SafeDeleteAssessmentReason -Assessment $assessment -ReasonCode $protectedReason)
    }

    # Allowlist containment.
    if ($allowlistMode) {
        $insideAllowedRoot = $false
        foreach ($rootCanonical in $allowedCanonical) {
            if (Test-SafeDeletePathWithin -Child $canonicalPath -Parent $rootCanonical) {
                $insideAllowedRoot = $true
                break
            }
        }
        if (-not $insideAllowedRoot) {
            return (Set-SafeDeleteAssessmentReason -Assessment $assessment -ReasonCode 'OutsideAllowedRoot')
        }
    }

    # Expected leaf name (supports -like wildcards such as 'dsh-*').
    if ($ExpectedLeafName -and @($ExpectedLeafName).Count -gt 0) {
        $leafMatched = $false
        foreach ($pattern in $ExpectedLeafName) {
            if ($assessment.LeafName -like $pattern) {
                $leafMatched = $true
                break
            }
        }
        if (-not $leafMatched) {
            return (Set-SafeDeleteAssessmentReason -Assessment $assessment -ReasonCode 'UnexpectedLeafName')
        }
    }

    $assessment.IsSafe = $true
    $assessment.ReasonCode = 'Ok'
    $assessment.Reason = Get-SafeDeleteReasonText -ReasonCode 'Ok'
    return $assessment
}

function Remove-SafeDeleteLink {
    <#
    .SYNOPSIS
        Remove a junction / directory symlink / file symlink itself, never its target.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $info = Get-SafeDeleteItemInfo -Path $Path
    $extended = ConvertTo-SafeDeleteExtendedPath -Path $Path
    $errors = New-Object System.Collections.ArrayList

    if (-not $info.Exists) { return }

    if ($info.IsDirectory) {
        if ($Path.Length -ge 240) {
            # cmd.exe builtins are not reliable with \\?\ paths; use .NET for long paths.
            try { [System.IO.Directory]::Delete($extended, $false) }
            catch { $errors.Add($_.Exception.Message) }
        }
        else {
            # Requirement from the incident review: remove junctions with `cmd /c rmdir`
            # so that only the link is deleted.
            $commandLine = 'rmdir /q "' + $Path + '"'
            & cmd.exe /d /c $commandLine 2>&1 | Out-Null
            if (Test-SafeDeletePathExists -Path $Path) {
                try { [System.IO.Directory]::Delete($extended, $false) }
                catch { $errors.Add($_.Exception.Message) }
            }
        }
    }
    else {
        try {
            $attributes = [System.IO.File]::GetAttributes($extended)
            if (($attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                [System.IO.File]::SetAttributes($extended, [System.IO.FileAttributes]::Normal)
            }
            [System.IO.File]::Delete($extended)
        }
        catch {
            $errors.Add($_.Exception.Message)
        }
    }

    if (Test-SafeDeletePathExists -Path $Path) {
        throw [System.ArgumentException]::new(('SafeDelete: 無法移除連結「{0}」{1}' -f $Path, ($errors -join '；')))
    }
}

function Remove-SafeDeleteFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $extended = ConvertTo-SafeDeleteExtendedPath -Path $Path
    try {
        $attributes = [System.IO.File]::GetAttributes($extended)
        if (($attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
            [System.IO.File]::SetAttributes($extended, [System.IO.FileAttributes]::Normal)
        }
        [System.IO.File]::Delete($extended)
    }
    catch [System.IO.FileNotFoundException] {
        return
    }
    catch [System.IO.DirectoryNotFoundException] {
        return
    }
}

function Remove-SafeDeleteDirectoryTree {
    <#
    .SYNOPSIS
        Recursively delete a directory tree.  Reparse points are removed as links only.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [switch]$KeepRoot
    )

    $removed = 0
    $extended = ConvertTo-SafeDeleteExtendedPath -Path $Path

    try {
        $entries = [System.IO.Directory]::GetFileSystemEntries($extended)
    }
    catch {
        throw [System.ArgumentException]::new(('SafeDelete: 無法列出資料夾「{0}」：{1}' -f $Path, $_.Exception.Message))
    }

    foreach ($entry in $entries) {
        $childPath = ConvertFrom-SafeDeleteExtendedPath -Path $entry
        $childInfo = Get-SafeDeleteItemInfo -Path $childPath
        if (-not $childInfo.Exists) { continue }

        if ($childInfo.IsReparsePoint) {
            Remove-SafeDeleteLink -Path $childPath
            $removed++
        }
        elseif ($childInfo.IsDirectory) {
            $removed += (Remove-SafeDeleteDirectoryTree -Path $childPath)
        }
        else {
            Remove-SafeDeleteFile -Path $childPath
            $removed++
        }
    }

    if (-not $KeepRoot) {
        try {
            [System.IO.Directory]::Delete($extended, $false)
            $removed++
        }
        catch {
            throw [System.ArgumentException]::new(('SafeDelete: 無法刪除資料夾「{0}」：{1}' -f $Path, $_.Exception.Message))
        }
    }

    return $removed
}

# ---------------------------------------------------------------------------
# Public: path policy
# ---------------------------------------------------------------------------

function Assert-SafePath {
    <#
    .SYNOPSIS
        Canonicalize a path and throw if the SafeDelete policy rejects it.

    .DESCRIPTION
        Returns the canonical path (absolute, no trailing backslash, . and .. resolved)
        when the path is safe; throws System.ArgumentException with a message that
        contains the reason code otherwise.

        Call this as the very first line of any script that deletes or mass-overwrites:
            $target = Assert-SafePath -Path $Dest -AllowedRoot "$env:TEMP" -ScriptRoot $PSScriptRoot

    .PARAMETER Path
        Path to validate.  Relative paths are rejected unless -AllowRelative is used.

    .PARAMETER AllowedRoot
        Strict allowlist mode.  When supplied, the path must be equal to, or below, one
        of these existing directories.  Allowlisted roots themselves must not be
        protected paths (a drive root or the user profile cannot be allowlisted).

    .PARAMETER DenyPath
        Extra denied roots for this call (equal or below = denied).

    .PARAMETER ExpectedLeafName
        Require the last path segment to match one of these names; -like wildcards are
        allowed (for example 'dsh-*').

    .PARAMETER ScriptRoot
        The calling script's own directory (normally $PSScriptRoot).  Paths equal to or
        below it are rejected.

    .PARAMETER AllowRelative
        Explicitly allow relative paths.  They are resolved against the current
        directory and then policy checked.

    .EXAMPLE
        $target = Assert-SafePath -Path 'C:\Temp\work' -AllowedRoot 'C:\Temp'

    .EXAMPLE
        Assert-SafePath -Path 'C:\'          # throws, ReasonCode DriveRoot
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path,
        [string[]]$AllowedRoot,
        [string[]]$DenyPath,
        [string[]]$ExpectedLeafName,
        [string]$ScriptRoot,
        [switch]$AllowRelative
    )

    process {
        $assessment = Get-SafeDeletePathAssessment -Path $Path -AllowedRoot $AllowedRoot -DenyPath $DenyPath -ExpectedLeafName $ExpectedLeafName -ScriptRoot $ScriptRoot -AllowRelative:$AllowRelative
        if (-not $assessment.IsSafe) {
            $message = 'SafeDelete: 不安全的路徑「{0}」[{1}]：{2}（canonical={3}）' -f $Path, $assessment.ReasonCode, $assessment.Reason, $assessment.CanonicalPath
            throw [System.ArgumentException]::new($message)
        }
        return $assessment.CanonicalPath
    }
}

function Test-SafePath {
    <#
    .SYNOPSIS
        Test whether a path passes the SafeDelete policy without throwing.

    .DESCRIPTION
        Returns $true/$false by default.  With -Detailed it returns an object with
        IsSafe, CanonicalPath, ReasonCode, Reason and LeafName.

    .EXAMPLE
        Test-SafePath -Path 'C:\'            # False

    .EXAMPLE
        (Test-SafePath -Path 'C:\Temp\x' -Detailed).ReasonCode
    #>
    [CmdletBinding()]
    [OutputType([bool], [pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path,
        [string[]]$AllowedRoot,
        [string[]]$DenyPath,
        [string[]]$ExpectedLeafName,
        [string]$ScriptRoot,
        [switch]$AllowRelative,
        [switch]$Detailed
    )

    process {
        $assessment = Get-SafeDeletePathAssessment -Path $Path -AllowedRoot $AllowedRoot -DenyPath $DenyPath -ExpectedLeafName $ExpectedLeafName -ScriptRoot $ScriptRoot -AllowRelative:$AllowRelative
        if ($Detailed) { return $assessment }
        return [bool]$assessment.IsSafe
    }
}

function Register-SafeDeleteDeniedPath {
    <#
    .SYNOPSIS
        Add or remove a module wide denied path (for example C:\work in a profile).

    .EXAMPLE
        Register-SafeDeleteDeniedPath -Path 'C:\work'
        Register-SafeDeleteDeniedPath -Path 'C:\work' -Remove
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Path,
        [switch]$Remove
    )

    process {
        $canonical = Get-SafeDeleteCanonical -Path $Path
        if (-not $canonical.Ok) {
            throw [System.ArgumentException]::new(('SafeDelete: 無法將「{0}」加入拒絕清單：{1}' -f $Path, (Get-SafeDeleteReasonText -ReasonCode $canonical.ReasonCode)))
        }

        $existing = $null
        foreach ($registered in $script:RegisteredDeniedPaths) {
            if ([string]::Equals($registered, $canonical.CanonicalPath, [StringComparison]::OrdinalIgnoreCase)) {
                $existing = $registered
                break
            }
        }

        if ($Remove) {
            if ($existing) { [void]$script:RegisteredDeniedPaths.Remove($existing) }
        }
        elseif (-not $existing) {
            [void]$script:RegisteredDeniedPaths.Add($canonical.CanonicalPath)
        }
    }
}

function Get-SafeDeleteProtectedPath {
    <#
    .SYNOPSIS
        Inspect the built-in protected locations currently in effect.
    #>
    [CmdletBinding()]
    param()

    $programFiles = @()
    foreach ($candidate in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432)) {
        if ($candidate -and -not ($programFiles -contains $candidate)) {
            $programFiles += $candidate
        }
    }

    return [pscustomobject]@{
        ModuleRoot              = $script:ModuleRoot
        UserProfile             = $env:USERPROFILE
        UsersRoot               = $(if ($env:USERPROFILE) { Split-Path -Parent $env:USERPROFILE } else { $null })
        SystemRoot              = $env:SystemRoot
        ProgramFiles            = $programFiles
        ProgramData             = $env:ProgramData
        ProtectedDirectoryNames = @($script:ProtectedDirectoryNames)
        DshSegments             = @('.dsh')
        RegisteredDeniedPaths   = @($script:RegisteredDeniedPaths)
    }
}

# ---------------------------------------------------------------------------
# Public: deletion
# ---------------------------------------------------------------------------

function Remove-SafeItem {
    <#
    .SYNOPSIS
        Delete a file, directory or link after the SafeDelete path policy has passed.

    .DESCRIPTION
        Unlike Remove-Item -Recurse this function:
          - canonicalizes and policy checks the path first (fail closed),
          - refuses drive roots, user profiles, .dsh, Windows / Program Files* /
            ProgramData, the script's own directory and relative paths,
          - removes junctions / symlinks as links only (cmd /c rmdir) and never
            traverses them, even inside a tree,
          - handles long paths with the \\?\ prefix,
          - is a single ShouldProcess target with ConfirmImpact High, so -WhatIf and
            -Confirm work and interactive use asks for confirmation by default,
          - throws when the target does not exist instead of silently doing nothing.

        Automated callers should implement their own ShouldProcess and then call this
        with -Confirm:$false (or set $ConfirmPreference = 'None' for the process).

    .PARAMETER Path
        File, directory or link to delete.  Must pass the SafeDelete policy.

    .PARAMETER AllowedRoot
        Strict allowlist roots; strongly recommended for every caller.

    .PARAMETER DenyPath
        Extra denied roots for this call.

    .PARAMETER ExpectedLeafName
        Require the last path segment to match (supports -like wildcards).

    .PARAMETER ScriptRoot
        Calling script's own directory (normally $PSScriptRoot); protected.

    .PARAMETER AllowRelative
        Explicitly allow relative paths.

    .PARAMETER KeepRoot
        Delete the directory contents but keep the directory itself.

    .PARAMETER PassThru
        Return a summary object (Path, Removed, IsReparsePoint, KeptRoot).

    .EXAMPLE
        Remove-SafeItem -Path 'C:\Temp\mywork' -AllowedRoot 'C:\Temp' -WhatIf

    .EXAMPLE
        Remove-SafeItem -Path 'C:\Temp\mywork' -AllowedRoot 'C:\Temp' -Confirm:$false -PassThru
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path,
        [string[]]$AllowedRoot,
        [string[]]$DenyPath,
        [string[]]$ExpectedLeafName,
        [string]$ScriptRoot,
        [switch]$AllowRelative,
        [switch]$KeepRoot,
        [switch]$PassThru
    )

    process {
        $assessment = Get-SafeDeletePathAssessment -Path $Path -AllowedRoot $AllowedRoot -DenyPath $DenyPath -ExpectedLeafName $ExpectedLeafName -ScriptRoot $ScriptRoot -AllowRelative:$AllowRelative
        if (-not $assessment.IsSafe) {
            $message = 'SafeDelete: 拒絕刪除「{0}」[{1}]：{2}（canonical={3}）' -f $Path, $assessment.ReasonCode, $assessment.Reason, $assessment.CanonicalPath
            throw [System.ArgumentException]::new($message)
        }

        $canonical = $assessment.CanonicalPath
        $item = Get-SafeDeleteItemInfo -Path $canonical
        if (-not $item.Exists) {
            throw [System.IO.FileNotFoundException]::new(('SafeDelete: 找不到目標「{0}」；Remove-SafeItem 不會略過不存在的路徑（fail closed）。' -f $canonical))
        }

        $actionText = '刪除'
        if ($item.IsReparsePoint) {
            if ($item.IsDirectory) { $actionText = '移除目錄連結（只刪 link，不動目標）' }
            else { $actionText = '移除檔案連結（只刪 link，不動目標）' }
        }
        elseif ($item.IsDirectory) {
            if ($KeepRoot) { $actionText = '清空資料夾內容（保留資料夾本身；連結只刪 link）' }
            else { $actionText = '遞迴刪除資料夾（連結只刪 link，不追入目標）' }
        }

        if (-not $PSCmdlet.ShouldProcess($canonical, $actionText)) {
            return
        }

        $removed = 0
        if ($item.IsReparsePoint) {
            Remove-SafeDeleteLink -Path $canonical
            $removed = 1
        }
        elseif ($item.IsDirectory) {
            $removed = Remove-SafeDeleteDirectoryTree -Path $canonical -KeepRoot:$KeepRoot
        }
        else {
            Remove-SafeDeleteFile -Path $canonical
            $removed = 1
        }

        if (-not $KeepRoot) {
            if (Test-SafeDeletePathExists -Path $canonical) {
                throw [System.ArgumentException]::new(('SafeDelete: 刪除後目標仍存在「{0}」；請檢查權限或鎖定中的檔案。' -f $canonical))
            }
        }
        else {
            if (-not (Test-SafeDeletePathExists -Path $canonical)) {
                throw [System.ArgumentException]::new(('SafeDelete: -KeepRoot 模式下目標資料夾應該保留，但「{0}」不見了。' -f $canonical))
            }
        }

        if ($PassThru) {
            return [pscustomobject]@{
                Path           = $canonical
                Removed        = $removed
                IsReparsePoint = [bool]$item.IsReparsePoint
                KeptRoot       = [bool]($item.IsDirectory -and $KeepRoot.IsPresent)
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Public: robocopy /MIR guard
# ---------------------------------------------------------------------------

function Test-SafeMirrorTarget {
    <#
    .SYNOPSIS
        Validate the source and destination of a robocopy /MIR before it runs.

    .DESCRIPTION
        Checks:
          - source passes the SafeDelete policy and exists as a directory,
          - destination passes the SafeDelete policy (never a drive root, user
            profile, .dsh, Windows / Program Files* / ProgramData),
          - destination is not the source and not inside / above it,
          - destination either already contains a marker file (.backup-target or
            .safedelete-mirror) or the caller explicitly passed -AllowUnmarked /
            -AllowCreate.

        Returns an object with IsSafe, Reasons, MarkerFound, canonical source and
        destination, and the robocopy command line it would run.

    .EXAMPLE
        Test-SafeMirrorTarget -Source 'D:\data' -Destination 'E:\backup\data'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Source,
        [Parameter(Mandatory, Position = 1)]
        [string]$Destination,
        [string[]]$AllowedRoot,
        [string[]]$DenyPath,
        [string[]]$MarkerFile = @('.backup-target', '.safedelete-mirror'),
        [string]$ScriptRoot,
        [switch]$AllowUnmarked,
        [switch]$AllowCreate
    )

    $reasons = New-Object System.Collections.ArrayList
    $marker = @($MarkerFile)
    $sourceCanonical = $null
    $destinationCanonical = $null
    $markerFound = $false
    $commandLine = $null

    $sourceAssessment = Get-SafeDeletePathAssessment -Path $Source -AllowedRoot $AllowedRoot -DenyPath $DenyPath -ScriptRoot $ScriptRoot
    if (-not $sourceAssessment.IsSafe) {
        $reasons.Add(('來源路徑未通過安全檢查 [{0}]：{1}' -f $sourceAssessment.ReasonCode, $sourceAssessment.Reason))
    }
    else {
        $sourceCanonical = $sourceAssessment.CanonicalPath
        $sourceItem = Get-SafeDeleteItemInfo -Path $sourceCanonical
        if (-not $sourceItem.Exists) {
            $reasons.Add('來源資料夾不存在（來源必須存在）。')
        }
        elseif (-not $sourceItem.IsDirectory) {
            $reasons.Add('來源不是資料夾（robocopy /MIR 需要來源資料夾）。')
        }
    }

    $destinationAssessment = Get-SafeDeletePathAssessment -Path $Destination -AllowedRoot $AllowedRoot -DenyPath $DenyPath -ScriptRoot $ScriptRoot
    if (-not $destinationAssessment.IsSafe) {
        $reasons.Add(('目標路徑未通過安全檢查 [{0}]：{1}' -f $destinationAssessment.ReasonCode, $destinationAssessment.Reason))
    }
    else {
        $destinationCanonical = $destinationAssessment.CanonicalPath
        $destinationItem = Get-SafeDeleteItemInfo -Path $destinationCanonical
        if ($destinationItem.Exists) {
            if (-not $destinationItem.IsDirectory) {
                $reasons.Add('目標已存在但不是資料夾。')
            }
            else {
                foreach ($markerName in $marker) {
                    if ($markerName -and (Test-SafeDeletePathExists -Path (Join-Path $destinationCanonical $markerName))) {
                        $markerFound = $true
                        break
                    }
                }
                if (-not $markerFound -and -not $AllowUnmarked) {
                    $reasons.Add(('目標資料夾缺少 marker 檔（{0}）；請先建立 marker，或明確使用 -AllowUnmarked。' -f ($marker -join ' / ')))
                }
            }
        }
        elseif (-not $AllowCreate) {
            $reasons.Add('目標資料夾不存在；robocopy /MIR 會建立它，請明確使用 -AllowCreate。')
        }
    }

    if ($sourceCanonical -and $destinationCanonical) {
        if ([string]::Equals($sourceCanonical, $destinationCanonical, [StringComparison]::OrdinalIgnoreCase)) {
            $reasons.Add('來源與目標是同一個資料夾。')
        }
        elseif (Test-SafeDeletePathWithin -Child $destinationCanonical -Parent $sourceCanonical) {
            $reasons.Add('目標位於來源之下（會互相覆蓋）。')
        }
        elseif (Test-SafeDeletePathWithin -Child $sourceCanonical -Parent $destinationCanonical) {
            $reasons.Add('來源位於目標之下（會互相覆蓋）。')
        }

        $commandLine = 'robocopy "{0}" "{1}" /MIR /XJ /R:2 /W:2 /NP /NFL /NDL /NJH /NJS' -f $sourceCanonical, $destinationCanonical
    }

    return [pscustomobject]@{
        IsSafe               = ($reasons.Count -eq 0)
        Reasons              = @($reasons)
        Source               = $Source
        Destination          = $Destination
        SourceCanonical      = $sourceCanonical
        DestinationCanonical = $destinationCanonical
        MarkerFound          = $markerFound
        MarkerFile           = $marker
        CommandLine          = $commandLine
    }
}

function Invoke-SafeRobocopy {
    <#
    .SYNOPSIS
        Run robocopy /MIR only after Test-SafeMirrorTarget has validated both sides.

    .DESCRIPTION
        Always adds /XJ (exclude junctions and directory symlinks) so a mirror never
        follows a junction into another volume; /R:2 /W:2 limit retries.  The whole
        operation is a single ShouldProcess target (ConfirmImpact High), so -WhatIf
        and -Confirm work.

    .EXAMPLE
        Invoke-SafeRobocopy -Source 'D:\data' -Destination 'E:\backup\data' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Source,
        [Parameter(Mandatory, Position = 1)]
        [string]$Destination,
        [string[]]$AllowedRoot,
        [string[]]$DenyPath,
        [string[]]$MarkerFile,
        [string]$ScriptRoot,
        [switch]$AllowUnmarked,
        [switch]$AllowCreate,
        [string[]]$RobocopyArgument,
        [switch]$PassThru
    )

    $checkParameters = @{
        Source       = $Source
        Destination  = $Destination
        AllowedRoot  = $AllowedRoot
        DenyPath     = $DenyPath
        ScriptRoot   = $ScriptRoot
        AllowUnmarked = $AllowUnmarked
        AllowCreate  = $AllowCreate
    }
    if ($MarkerFile) { $checkParameters.MarkerFile = $MarkerFile }

    $check = Test-SafeMirrorTarget @checkParameters
    if (-not $check.IsSafe) {
        throw [System.ArgumentException]::new(('SafeDelete: 拒絕 robocopy /MIR：' + (@($check.Reasons) -join '；')))
    }

    $robocopy = Get-Command robocopy.exe -ErrorAction SilentlyContinue
    if (-not $robocopy) {
        throw [System.ArgumentException]::new('SafeDelete: 找不到 robocopy.exe。')
    }

    $arguments = @(
        $check.SourceCanonical,
        $check.DestinationCanonical,
        '/MIR',
        '/XJ',
        '/R:2',
        '/W:2',
        '/NP',
        '/NFL',
        '/NDL',
        '/NJH',
        '/NJS'
    )
    if ($RobocopyArgument) { $arguments += @($RobocopyArgument) }

    $targetText = 'robocopy /MIR {0} -> {1}' -f $check.SourceCanonical, $check.DestinationCanonical
    if (-not $PSCmdlet.ShouldProcess($targetText, 'robocopy /MIR')) {
        return
    }

    & $robocopy.Source @arguments | Out-Null
    $exitCode = $LASTEXITCODE

    if ($PassThru) {
        return [pscustomobject]@{
            ExitCode    = $exitCode
            Source      = $check.SourceCanonical
            Destination = $check.DestinationCanonical
            Arguments   = $arguments
        }
    }

    if ($exitCode -ge 8) {
        throw [System.ArgumentException]::new(('SafeDelete: robocopy 失敗（exit code {0}）；robocopy 8 以上代表複製錯誤。' -f $exitCode))
    }
}

# ---------------------------------------------------------------------------
# Public: dangerous command line scanner
# ---------------------------------------------------------------------------

$script:DangerRules = @(
    [pscustomobject]@{
        Id     = 'RecursiveDirectoryDelete'
        Name   = 'rd /s 或 rmdir /s'
        Reason = '偵測到遞迴目錄刪除（rd /s、rmdir /s）。'
        Regex  = '(?i)\b(?:rd|rmdir)\b[^&|;\r\n]*?/s\b'
    }
    [pscustomobject]@{
        Id     = 'RecursiveFileDelete'
        Name   = 'del /s 或 erase /s'
        Reason = '偵測到遞迴檔案刪除（del /s、erase /s）。'
        Regex  = '(?i)\b(?:del|erase)\b[^&|;\r\n]*?/s\b'
    }
    [pscustomobject]@{
        Id     = 'ForceQuietFileDelete'
        Name   = 'del /f /q'
        Reason = '偵測到強制且不詢問的檔案刪除（del /f /q）。'
        Regex  = '(?i)\b(?:del|erase)\b[^&|;\r\n]*?(?:/f\b[^&|;\r\n]*?/q\b|/q\b[^&|;\r\n]*?/f\b)'
    }
    [pscustomobject]@{
        Id     = 'RemoveItemRecurse'
        Name   = 'Remove-Item -Recurse'
        Reason = '偵測到 Remove-Item -Recurse（PowerShell 遞迴刪除）。'
        Regex  = '(?i)\bRemove-Item\b[^&|;\r\n]*?-(?:Recurse|r)\b'
    }
    [pscustomobject]@{
        Id     = 'RobocopyMirror'
        Name   = 'robocopy /MIR 或 /PURGE'
        Reason = '偵測到 robocopy /MIR 或 /PURGE（鏡像會刪除目標端多出來的檔案）。'
        Regex  = '(?i)\brobocopy(?:\.exe)?\b[^&|;\r\n]*?/(?:MIR|PURGE)\b'
    }
    [pscustomobject]@{
        Id     = 'UnixRmRecursiveForce'
        Name   = 'rm -rf'
        Reason = '偵測到 rm -rf（Unix 風格遞迴強制刪除）。'
        Regex  = '(?i)(?:^|[\s;&|(])(?:sudo\s+)?rm\s+[^&|;\r\n]*?(?:-[a-z]*r[a-z]*f|-[a-z]*f[a-z]*r|--recursive[^&|;\r\n]*--force|--force[^&|;\r\n]*--recursive)'
    }
    [pscustomobject]@{
        Id     = 'FormatVolume'
        Name   = 'format / Format-Volume'
        Reason = '偵測到磁碟格式化或分割區操作（format、Format-Volume、Clear-Disk、Initialize-Disk、Remove-Partition）。'
        Regex  = '(?i)(?:\bformat(?:\.com)?\s+[A-Za-z]:|\b(?:Format-Volume|Clear-Disk|Initialize-Disk|Remove-Partition)\b)'
    }
    [pscustomobject]@{
        Id     = 'DiskPartClean'
        Name   = 'diskpart clean'
        Reason = '偵測到 diskpart clean（會清除磁碟分割表）。'
        Regex  = '(?i)\bdiskpart\b[^&|;\r\n]*?\bclean\b'
    }
    [pscustomobject]@{
        Id     = 'VssDeleteShadows'
        Name   = 'vssadmin delete shadows'
        Reason = '偵測到刪除 VSS 影子複本（會毀掉誤刪後的還原機會）。'
        Regex  = '(?i)\bvssadmin\b[^&|;\r\n]*?\bdelete\s+shadows?'
    }
    [pscustomobject]@{
        Id     = 'CipherWipe'
        Name   = 'cipher /w'
        Reason = '偵測到 cipher /w（抹除磁碟可用空間）。'
        Regex  = '(?i)\bcipher\s+/w\b'
    }
)

function Get-SafeDeleteCommandTargets {
    <#
    .SYNOPSIS
        Extract candidate path tokens from a command line (internal helper).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$CommandLine
    )

    $candidates = New-Object System.Collections.ArrayList

    $patterns = @(
        '"([^"]+)"'
        "'([^']+)'"
        '(?:[A-Za-z]:[\\/][^\s"'']*)'
        '(?:\\\\[^\s"'',;|&]*)'
        '(?:\.{1,2}[\\/][^\s"'']*)'
    )

    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($CommandLine, $pattern)) {
            if ($match.Groups.Count -gt 1) {
                $token = $match.Groups[1].Value
            }
            else {
                $token = $match.Value
            }
            $token = $token.Trim()
            if ($token.Length -eq 0) { continue }
            if ($token -match '^[/-]') { continue }
            if (-not ($candidates -contains $token)) {
                [void]$candidates.Add($token)
            }
        }
    }

    return @($candidates)
}

function Resolve-SafeDeleteCandidateToken {
    <#
    .SYNOPSIS
        Best effort expansion of %VAR% and $env:VAR in a candidate token (internal).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Token
    )

    $expanded = $Token

    $expanded = [regex]::Replace($expanded, '%([A-Za-z_][A-Za-z0-9_]*(?:\([A-Za-z0-9_]+\))?)%', {
        param($match)
        $value = [System.Environment]::GetEnvironmentVariable($match.Groups[1].Value)
        if ($null -eq $value) { return $match.Value }
        return $value
    })

    $expanded = [regex]::Replace($expanded, '\$\{env:([A-Za-z_][A-Za-z0-9_]*(?:\([A-Za-z0-9_]+\))?)\}', {
        param($match)
        $value = [System.Environment]::GetEnvironmentVariable($match.Groups[1].Value)
        if ($null -eq $value) { return $match.Value }
        return $value
    })

    $expanded = [regex]::Replace($expanded, '\$env:([A-Za-z_][A-Za-z0-9_]*(?:\([A-Za-z0-9_]+\))?)', {
        param($match)
        $value = [System.Environment]::GetEnvironmentVariable($match.Groups[1].Value)
        if ($null -eq $value) { return $match.Value }
        return $value
    })

    return $expanded
}

function Test-DangerousCommandLine {
    <#
    .SYNOPSIS
        Static analysis of a command string for destructive delete/format patterns.

    .DESCRIPTION
        Returns an object per command line with:
          IsDangerous       - at least one destructive pattern matched (High risk class),
          RiskLevel         - 'High' when IsDangerous, otherwise 'None',
          RequiresApproval  - same as IsDangerous (convenience for gates),
          Matched           - matched rule ids,
          Reasons           - human readable Traditional Chinese reasons,
          Targets           - candidate target path tokens found in the command,
          TargetKnown       - $false when no target could be extracted
                              (unknown target is reported as dangerous),
          TargetSafe        - all extracted targets pass the SafeDelete path policy,
          TargetAssessments - per target objects (Path, CanonicalPath, IsSafe, ReasonCode, Reason).

        Important semantics: a destructive verb always sets IsDangerous, even when its
        target currently looks safe, because the command class itself requires
        confirmation.  IsDangerous = $false means "no destructive verb detected".
        This is a heuristic, not a security boundary: obfuscation, variables assembled
        at runtime and aliases can bypass it.  Use it as one gate among several.

    .PARAMETER CommandLine
        Command string to inspect.  Accepts pipeline input.

    .EXAMPLE
        Test-DangerousCommandLine -CommandLine 'cmd /c rd /s /q "C:\"'

    .EXAMPLE
        'rd /s /q' | Test-DangerousCommandLine
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$CommandLine
    )

    process {
        $line = $CommandLine

        $matchedRules = New-Object System.Collections.ArrayList
        $matchedReasons = New-Object System.Collections.ArrayList

        foreach ($rule in $script:DangerRules) {
            $matches = [regex]::Matches($line, $rule.Regex)
            if ($matches.Count -gt 0) {
                [void]$matchedRules.Add($rule.Id)
                [void]$matchedReasons.Add($rule.Reason)
            }
        }

        $targets = @(Get-SafeDeleteCommandTargets -CommandLine $line)
        $targetAssessments = New-Object System.Collections.ArrayList
        $targetSafe = $true
        $knownTargets = New-Object System.Collections.ArrayList

        foreach ($token in $targets) {
            $resolved = Resolve-SafeDeleteCandidateToken -Token $token
            if ([string]::IsNullOrWhiteSpace($resolved)) { continue }
            [void]$knownTargets.Add($resolved)
            $assessment = Get-SafeDeletePathAssessment -Path $resolved -AllowRelative
            [void]$targetAssessments.Add($assessment)
            if (-not $assessment.IsSafe) {
                $targetSafe = $false
                [void]$matchedReasons.Add(('目標路徑未通過安全檢查「{0}」[{1}]：{2}' -f $resolved, $assessment.ReasonCode, $assessment.Reason))
            }
        }

        $targetKnown = ($knownTargets.Count -gt 0)
        if ($matchedRules.Count -gt 0 -and -not $targetKnown) {
            $targetSafe = $false
            [void]$matchedReasons.Add('無法判定刪除目標（找不到可解析的路徑）＝視為危險。')
        }

        $isDangerous = ($matchedRules.Count -gt 0)

        return [pscustomobject]@{
            CommandLine       = $line
            IsDangerous       = $isDangerous
            RiskLevel         = $(if ($isDangerous) { 'High' } else { 'None' })
            RequiresApproval  = $isDangerous
            Matched           = @($matchedRules)
            Reasons           = @($matchedReasons)
            Targets           = @($knownTargets)
            TargetKnown       = $targetKnown
            TargetSafe        = $targetSafe
            TargetAssessments = @($targetAssessments)
        }
    }
}

# ---------------------------------------------------------------------------
# Module initialisation
# ---------------------------------------------------------------------------

$script:ModuleRootCanonical = $null
$moduleRootInfo = Get-SafeDeleteCanonical -Path $script:ModuleRoot
if ($moduleRootInfo.Ok) {
    $script:ModuleRootCanonical = $moduleRootInfo.CanonicalPath
}

$script:UserProfileCanonical = $null
if ($env:USERPROFILE) {
    $profileInfo = Get-SafeDeleteCanonical -Path $env:USERPROFILE
    if ($profileInfo.Ok) {
        $script:UserProfileCanonical = $profileInfo.CanonicalPath
    }
}

Export-ModuleMember -Function @(
    'Assert-SafePath'
    'Test-SafePath'
    'Remove-SafeItem'
    'Test-SafeMirrorTarget'
    'Invoke-SafeRobocopy'
    'Test-DangerousCommandLine'
    'Register-SafeDeleteDeniedPath'
    'Get-SafeDeleteProtectedPath'
)
