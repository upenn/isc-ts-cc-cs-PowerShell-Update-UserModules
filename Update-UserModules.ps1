<#
.SYNOPSIS
    Updates PowerShell modules installed in the CurrentUser scope, then removes older versions.

.DESCRIPTION
    Phase 1 - Update: finds every module installed (via PowerShellGet) under the current user's
    module path, checks the gallery for a newer version, and updates it.

    Phase 2 - Cleanup: for each of those modules, keeps the newest version plus the number of
    older versions given by -KeepVersions, and uninstalls the rest.

    Every action is written to a log file. By default the script writes nothing to the console;
    use -Verbose to echo log entries to the screen, and -WhatIf to see what would happen without
    changing anything (WhatIf actions are still logged, prefixed "WhatIf:").

    Log lines use a syslog style format with an ISO 8601 (RFC 5424) timestamp:
      2026-09-21T08:57:08-04:00 hostname Update-UserModules[4242]: notice: Updated Pester 5.6.1 -> 5.7.1
    Severities: info, notice (changes made / WhatIf), warning, err.

.PARAMETER LogPath
    Log file path. Defaults to Update-UserModules_<yyyyMMdd-HHmmss>.log in the current directory.
    If a directory is given, the default file name is created inside it.

.PARAMETER KeepVersions
    Number of older versions to keep in addition to the current (newest) version.
    Default 1 = keep version n and n-1. Use 0 to keep only the newest.

.PARAMETER Name
    Optional module name filter (wildcards allowed). Defaults to all user-scope modules.

.PARAMETER Repository
    Repository to check for updates. Defaults to PSGallery.

.PARAMETER CleanupOnly
    Skip the update phase and only remove old versions (no repository access needed).

.EXAMPLE
    .\Update-UserModules.ps1
    Updates all user modules, keeps n and n-1, logs to the current directory, no console output.

.EXAMPLE
    .\Update-UserModules.ps1 -WhatIf -Verbose
    Shows and logs what would be updated and removed, without making changes.

.EXAMPLE
    .\Update-UserModules.ps1 -KeepVersions 0 -LogPath C:\Logs
    Keeps only the newest version of each module and logs to C:\Logs.

.EXAMPLE
    .\Update-UserModules.ps1 -CleanupOnly -WhatIf -Verbose
    Shows which old versions would be removed, without checking for or installing updates.

.EXAMPLE
    .\Update-UserModules.ps1 -Name Microsoft.Graph*, ExchangeOnlineManagement -Verbose

.NOTES
    Requires PowerShellGet (Get-InstalledModule / Update-Module / Uninstall-Module).
    Runs on Windows (Windows PowerShell 5.1 and PowerShell 7+), macOS, and Linux (PowerShell 7+).
    User-scope module locations:
      Windows : <Documents>\WindowsPowerShell\Modules and <Documents>\PowerShell\Modules
      macOS/Linux : $XDG_DATA_HOME/powershell/Modules (default ~/.local/share/powershell/Modules)
    On macOS/Linux, don't run with sudo - $HOME becomes root's and root's modules are targeted.
    Only modules installed with Install-Module in the CurrentUser scope are touched.
    A module version that is loaded in any running session may fail to uninstall; run from a
    fresh session (pwsh -NoProfile) for best results. Failures are logged and the script
    exits with code 1 if any action failed.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [string]$LogPath,

    [Parameter()]
    [ValidateRange(0, 100)]
    [int]$KeepVersions = 1,

    [Parameter()]
    [string[]]$Name = '*',

    [Parameter()]
    [string]$Repository = 'PSGallery',

    [Parameter()]
    [switch]$CleanupOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:FailureCount = 0

#region Logging ---------------------------------------------------------------------------------

$defaultLogName = 'Update-UserModules_{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path -Path (Get-Location).ProviderPath -ChildPath $defaultLogName
}
elseif (Test-Path -LiteralPath $LogPath -PathType Container) {
    $LogPath = Join-Path -Path $LogPath -ChildPath $defaultLogName
}
$LogPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)

$logDir = Split-Path -Path $LogPath -Parent
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    # -WhatIf:$false so logging still happens in WhatIf mode
    New-Item -ItemType Directory -Path $logDir -Force -WhatIf:$false -Confirm:$false | Out-Null
}

# Syslog-style log lines with an RFC 5424 (ISO 8601) timestamp:
#   2026-09-21T08:57:08-04:00 hostname Update-UserModules[4242]: <severity>: message
$script:LogHost = ([Environment]::MachineName -split '\.')[0]
$script:LogTag  = '{0}[{1}]' -f [IO.Path]::GetFileNameWithoutExtension($PSCommandPath), $PID
$script:Invariant = [Globalization.CultureInfo]::InvariantCulture

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'WHATIF', 'ACTION')][string]$Level = 'INFO'
    )
    # Map to syslog severity names; WhatIf entries are notices prefixed with "WhatIf:".
    $severity = switch ($Level) {
        'INFO'   { 'info' }
        'ACTION' { 'notice' }
        'WHATIF' { 'notice' }
        'WARN'   { 'warning' }
        'ERROR'  { 'err' }
    }
    if ($Level -eq 'WHATIF') { $Message = "WhatIf: $Message" }

    $now = Get-Date
    # ISO 8601 / RFC 5424 timestamp with UTC offset, e.g. 2026-09-21T08:58:44-04:00
    $stamp = $now.ToString('yyyy-MM-ddTHH:mm:sszzz', $script:Invariant)
    $line  = '{0} {1} {2}: {3}: {4}' -f $stamp, $script:LogHost, $script:LogTag, $severity, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -WhatIf:$false -Confirm:$false
    Write-Verbose $line
}

#endregion

#region Helpers ---------------------------------------------------------------------------------

# Platform detection that also works on Windows PowerShell 5.1 (where $IsWindows doesn't exist).
$script:OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or
                    ((Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
$script:OnMacOS   = (Get-Variable -Name IsMacOS -ValueOnly -ErrorAction SilentlyContinue) -eq $true
# Windows and (default) macOS file systems are case-insensitive; Linux is case-sensitive.
$script:PathComparison = if ($script:OnWindows -or $script:OnMacOS) {
    [StringComparison]::OrdinalIgnoreCase
} else {
    [StringComparison]::Ordinal
}

function Get-UserModuleRoots {
    # Resolve the CurrentUser module folder(s) for the current platform/edition.
    $roots = [System.Collections.Generic.List[string]]::new()

    if ($script:OnWindows) {
        $docs = [Environment]::GetFolderPath('MyDocuments')   # honours OneDrive/folder redirection
        if ($docs) {
            $roots.Add((Join-Path (Join-Path $docs 'WindowsPowerShell') 'Modules'))  # Windows PowerShell 5.1
            $roots.Add((Join-Path (Join-Path $docs 'PowerShell') 'Modules'))         # PowerShell 7+
        }
    }
    else {
        # macOS / Linux: PowerShell follows XDG_DATA_HOME, defaulting to ~/.local/share
        $dataHome = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path (Join-Path $HOME '.local') 'share' }
        $roots.Add((Join-Path (Join-Path $dataHome 'powershell') 'Modules'))
    }

    # Anything in PSModulePath that lives under the user's home directory also counts as user scope.
    foreach ($p in ($env:PSModulePath -split [IO.Path]::PathSeparator)) {
        if ($p -and $p.StartsWith($HOME, $script:PathComparison)) { $roots.Add($p) }
    }
    $roots | ForEach-Object { $_.TrimEnd('\', '/') } | Where-Object { $_ } | Select-Object -Unique
}

function Test-IsUserScope {
    param([string]$Path, [string[]]$Roots)
    foreach ($r in $Roots) {
        if ($Path -and $Path.StartsWith($r, $script:PathComparison)) { return $true }
    }
    return $false
}

function Get-VersionSortKey {
    # Returns an object that sorts correctly: numeric version, then stable above prerelease.
    param([string]$Version)
    $parts = $Version -split '-', 2
    $base = $null
    if (-not [version]::TryParse($parts[0], [ref]$base)) { $base = [version]'0.0' }
    [pscustomobject]@{
        Base       = $base
        IsStable   = ($parts.Count -eq 1)
        Prerelease = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    }
}

function Sort-VersionsDescending {
    param([string[]]$Versions)
    $Versions |
        ForEach-Object { $k = Get-VersionSortKey $_; [pscustomobject]@{ Version = $_; Base = $k.Base; IsStable = $k.IsStable; Pre = $k.Prerelease } } |
        Sort-Object -Property @{ Expression = 'Base'; Descending = $true },
                              @{ Expression = 'IsStable'; Descending = $true },
                              @{ Expression = 'Pre'; Descending = $true } |
        Select-Object -ExpandProperty Version
}

function Compare-ModuleVersion {
    # Returns $true if $Candidate is newer than $Current.
    param([string]$Candidate, [string]$Current)
    $sorted = @(Sort-VersionsDescending -Versions @($Candidate, $Current))
    return ($sorted[0] -eq $Candidate -and $Candidate -ne $Current)
}

#endregion

#region Main ------------------------------------------------------------------------------------

$modeText = if ($WhatIfPreference) { 'WhatIf' } else { 'Live' }
Write-Log "===== Update-UserModules started (Mode: $modeText, CleanupOnly: $([bool]$CleanupOnly), KeepVersions: $KeepVersions, Name: $($Name -join ', ')) ====="
Write-Log "Log file: $LogPath"
$platform = if ($script:OnWindows) { 'Windows' } elseif ($script:OnMacOS) { 'macOS' } else { 'Linux' }
Write-Log "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) on $platform as $([Environment]::UserName)"

$requiredCommands = if ($CleanupOnly) { 'Get-InstalledModule', 'Uninstall-Module' }
                    else { 'Get-InstalledModule', 'Find-Module', 'Update-Module', 'Uninstall-Module' }
foreach ($cmd in $requiredCommands) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Log "Required command '$cmd' not found. Install/import PowerShellGet and retry." -Level ERROR
        exit 1
    }
}

$userRoots = @(Get-UserModuleRoots)
Write-Log "User module roots: $($userRoots -join '; ')"

# Gather every installed version, then keep only those under a user-scope path.
try {
    # -AllVersions can't be combined with wildcards, so get names first, then versions per module.
    $installedNames = @(Get-InstalledModule -Name $Name -ErrorAction SilentlyContinue -Verbose:$false |
        Select-Object -ExpandProperty Name -Unique)
    $allInstalled = @(foreach ($n in $installedNames) {
        Get-InstalledModule -Name $n -AllVersions -ErrorAction SilentlyContinue -Verbose:$false
    })
}
catch {
    Write-Log "Failed to enumerate installed modules: $($_.Exception.Message)" -Level ERROR
    exit 1
}

$userInstalled = @($allInstalled | Where-Object { Test-IsUserScope -Path $_.InstalledLocation -Roots $userRoots })
if ($userInstalled.Count -eq 0) {
    Write-Log 'No user-scope modules installed via PowerShellGet matched the filter. Nothing to do.'
    Write-Log '===== Finished ====='
    exit 0
}

# Map: module name -> list of installed version strings
$versionMap = @{}
foreach ($m in $userInstalled) {
    if (-not $versionMap.ContainsKey($m.Name)) { $versionMap[$m.Name] = [System.Collections.Generic.List[string]]::new() }
    $versionMap[$m.Name].Add([string]$m.Version)
}
$moduleNames = @($versionMap.Keys | Sort-Object)
Write-Log "Found $($moduleNames.Count) user-scope module(s) ($($userInstalled.Count) installed version(s))."

# ---- Phase 1: Update ---------------------------------------------------------------------------
$updated = 0
if ($CleanupOnly) {
    Write-Log '----- Phase 1: Update (skipped: -CleanupOnly) -----'
}
else {
    Write-Log '----- Phase 1: Update -----'

    $galleryLatest = @{}
    try {
        Find-Module -Name $moduleNames -Repository $Repository -ErrorAction SilentlyContinue -Verbose:$false |
            ForEach-Object { $galleryLatest[$_.Name] = [string]$_.Version }
    }
    catch {
        Write-Log "Gallery lookup failed: $($_.Exception.Message)" -Level WARN
    }

    $updateSupportsScope = (Get-Command Update-Module).Parameters.ContainsKey('Scope')
    foreach ($modName in $moduleNames) {
        $current = @(Sort-VersionsDescending -Versions $versionMap[$modName])[0]

        if (-not $galleryLatest.ContainsKey($modName)) {
            Write-Log "$modName $current - not found in $Repository; skipping update." -Level WARN
            continue
        }
        $latest = $galleryLatest[$modName]

        if (-not (Compare-ModuleVersion -Candidate $latest -Current $current)) {
            Write-Log "$modName $current - up to date."
            continue
        }

        $target = "$modName $current -> $latest"
        if ($PSCmdlet.ShouldProcess($target, 'Update module')) {
            try {
                $params = @{
                    Name            = $modName
                    RequiredVersion = $latest
                    Force           = $true
                    Confirm         = $false
                    ErrorAction     = 'Stop'
                    Verbose         = $false
                }
                if ($updateSupportsScope) { $params.Scope = 'CurrentUser' }
                Update-Module @params | Out-Null
                Write-Log "Updated $target" -Level ACTION
                $versionMap[$modName].Add($latest)
                $updated++
            }
            catch {
                Write-Log "Failed to update $target : $($_.Exception.Message)" -Level ERROR
                $script:FailureCount++
            }
        }
        else {
            Write-Log "Would update $target" -Level WHATIF
            # Treat the new version as installed so the cleanup plan reflects what a real run would do.
            $versionMap[$modName].Add($latest)
            $updated++
        }
    }
    Write-Log "Update phase complete: $updated module(s) $(if ($WhatIfPreference) { 'would be ' })updated."
}

# ---- Phase 2: Remove old versions --------------------------------------------------------------
Write-Log "----- Phase 2: Remove old versions (keeping newest + $KeepVersions) -----"

$keepCount = $KeepVersions + 1
$removed = 0

foreach ($modName in $moduleNames) {
    $sorted = @(Sort-VersionsDescending -Versions ($versionMap[$modName] | Select-Object -Unique))
    if ($sorted.Count -le $keepCount) {
        Write-Log "$modName - $($sorted.Count) version(s) installed ($($sorted -join ', ')); nothing to remove."
        continue
    }

    $keep = $sorted[0..($keepCount - 1)]
    $remove = $sorted[$keepCount..($sorted.Count - 1)]
    Write-Log "$modName - keeping: $($keep -join ', '); removing: $($remove -join ', ')"

    foreach ($ver in $remove) {
        $target = "$modName $ver"
        if ($PSCmdlet.ShouldProcess($target, 'Uninstall module version')) {
            try {
                $params = @{
                    Name            = $modName
                    RequiredVersion = $ver
                    Confirm         = $false
                    ErrorAction     = 'Stop'
                    Verbose         = $false
                }
                if ($ver -match '-' -and (Get-Command Uninstall-Module).Parameters.ContainsKey('AllowPrerelease')) {
                    $params.AllowPrerelease = $true
                }
                Uninstall-Module @params
                Write-Log "Removed $target" -Level ACTION
                $removed++
            }
            catch {
                Write-Log "Failed to remove $target : $($_.Exception.Message)" -Level ERROR
                $script:FailureCount++
            }
        }
        else {
            Write-Log "Would remove $target" -Level WHATIF
            $removed++
        }
    }
}
Write-Log "Cleanup phase complete: $removed version(s) $(if ($WhatIfPreference) { 'would be ' })removed."

Write-Log "===== Finished. Updated: $updated, Removed: $removed, Failures: $($script:FailureCount) ====="

if ($script:FailureCount -gt 0) { exit 1 } else { exit 0 }

#endregion
