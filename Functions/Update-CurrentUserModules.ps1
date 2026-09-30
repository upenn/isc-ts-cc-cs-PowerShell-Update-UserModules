# Shared implementation for the exported CurrentUser and AllUsers commands.
function Invoke-ModuleMaintenance {
    [CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]$Scope,

    [Parameter(Mandatory)]
    [string]$CommandName,

    [Parameter(Mandatory)]
    [System.Management.Automation.PSCmdlet]$CallerPSCmdlet,

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
$failureCount = 0

#region Logging ---------------------------------------------------------------------------------

$defaultLogName = '{0}_{1}.log' -f $CommandName, (Get-Date -Format 'yyyyMMdd-HHmmss')
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
#   2026-09-21T08:57:08-04:00 hostname Update-CurrentUserModules[4242]: <severity>: message
$logHost = ([Environment]::MachineName -split '\.')[0]
$logTag  = '{0}[{1}]' -f $CommandName, $PID
$invariant = [Globalization.CultureInfo]::InvariantCulture

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
    $stamp = $now.ToString('yyyy-MM-ddTHH:mm:sszzz', $invariant)
    $line  = '{0} {1} {2}: {3}: {4}' -f $stamp, $logHost, $logTag, $severity, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -WhatIf:$false -Confirm:$false
    Write-Verbose $line
}

#endregion

#region Helpers ---------------------------------------------------------------------------------

# Platform detection that also works on Windows PowerShell 5.1 (where $IsWindows doesn't exist).
$onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or
                    ((Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
$onMacOS   = (Get-Variable -Name IsMacOS -ValueOnly -ErrorAction SilentlyContinue) -eq $true
# Windows and (default) macOS file systems are case-insensitive; Linux is case-sensitive.
$pathComparison = if ($onWindows -or $onMacOS) {
    [StringComparison]::OrdinalIgnoreCase
} else {
    [StringComparison]::Ordinal
}

function Get-ScopedModuleRoots {
    # Resolve the standard module folder(s) for the requested scope and platform/edition.
    $roots = [System.Collections.Generic.List[string]]::new()

    if ($Scope -eq 'CurrentUser') {
        if ($onWindows) {
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

        # Custom user module paths under the home directory also count as CurrentUser scope.
        foreach ($p in ($env:PSModulePath -split [IO.Path]::PathSeparator)) {
            if ($p -and $p.StartsWith($HOME, $pathComparison)) { $roots.Add($p) }
        }
    }
    else {
        if ($onWindows) {
            if ($env:ProgramFiles) {
                $roots.Add((Join-Path (Join-Path $env:ProgramFiles 'WindowsPowerShell') 'Modules'))
                $roots.Add((Join-Path (Join-Path $env:ProgramFiles 'PowerShell') 'Modules'))
            }
        }
        else {
            $roots.Add('/usr/local/share/powershell/Modules')
        }
    }

    $roots | ForEach-Object { $_.TrimEnd('\', '/') } | Where-Object { $_ } | Select-Object -Unique
}

function Test-IsRequestedScope {
    param([string]$Path, [string[]]$Roots)
    foreach ($r in $Roots) {
        if (-not $Path) { continue }

        $normalizedRoot = $r.TrimEnd('\', '/')
        if ($Path.Equals($normalizedRoot, $pathComparison) -or
            $Path.StartsWith("$normalizedRoot$([IO.Path]::DirectorySeparatorChar)", $pathComparison) -or
            $Path.StartsWith("$normalizedRoot$([IO.Path]::AltDirectorySeparatorChar)", $pathComparison)) {
            return $true
        }
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
Write-Log "===== $CommandName started (Scope: $Scope, Mode: $modeText, CleanupOnly: $([bool]$CleanupOnly), KeepVersions: $KeepVersions, Name: $($Name -join ', ')) ====="
Write-Log "Log file: $LogPath"
$platform = if ($onWindows) { 'Windows' } elseif ($onMacOS) { 'macOS' } else { 'Linux' }
Write-Log "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) on $platform as $([Environment]::UserName)"

$requiredCommands = if ($CleanupOnly) { 'Get-InstalledModule', 'Uninstall-Module' }
                    else { 'Get-InstalledModule', 'Find-Module', 'Update-Module', 'Uninstall-Module' }
foreach ($cmd in $requiredCommands) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Log "Required command '$cmd' not found. Install/import PowerShellGet and retry." -Level ERROR
        throw "Required command '$cmd' not found. Install/import PowerShellGet and retry."
    }
}

$scopeRoots = @(Get-ScopedModuleRoots)
Write-Log "$Scope module roots: $($scopeRoots -join '; ')"

# Gather every installed version, then keep only those under a path for the requested scope.
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
    throw "$CommandName could not enumerate installed modules. See the log at '$LogPath'."
}

$scopeInstalled = @($allInstalled | Where-Object { Test-IsRequestedScope -Path $_.InstalledLocation -Roots $scopeRoots })
if ($scopeInstalled.Count -eq 0) {
    Write-Log "No $Scope modules installed via PowerShellGet matched the filter. Nothing to do."
    Write-Log '===== Finished ====='
    return
}

# Map: module name -> list of installed version strings
$versionMap = @{}
foreach ($m in $scopeInstalled) {
    if (-not $versionMap.ContainsKey($m.Name)) { $versionMap[$m.Name] = [System.Collections.Generic.List[string]]::new() }
    $versionMap[$m.Name].Add([string]$m.Version)
}
$moduleNames = @($versionMap.Keys | Sort-Object)
Write-Log "Found $($moduleNames.Count) $Scope module(s) ($($scopeInstalled.Count) installed version(s))."

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
        if ($CallerPSCmdlet.ShouldProcess($target, "Update $Scope module")) {
            try {
                $params = @{
                    Name            = $modName
                    RequiredVersion = $latest
                    Force           = $true
                    Confirm         = $false
                    ErrorAction     = 'Stop'
                    Verbose         = $false
                }
                if ($updateSupportsScope) { $params.Scope = $Scope }
                Update-Module @params | Out-Null
                Write-Log "Updated $target" -Level ACTION
                $versionMap[$modName].Add($latest)
                $updated++
            }
            catch {
                Write-Log "Failed to update $target : $($_.Exception.Message)" -Level ERROR
                $failureCount++
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
        if ($CallerPSCmdlet.ShouldProcess($target, "Uninstall $Scope module version")) {
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
                $failureCount++
            }
        }
        else {
            Write-Log "Would remove $target" -Level WHATIF
            $removed++
        }
    }
}
Write-Log "Cleanup phase complete: $removed version(s) $(if ($WhatIfPreference) { 'would be ' })removed."

Write-Log "===== Finished. Updated: $updated, Removed: $removed, Failures: $failureCount ====="

if ($failureCount -gt 0) {
    throw "$CommandName completed with $failureCount failure(s). See the log at '$LogPath'."
}

#endregion
}

function Update-CurrentUserModules {
    <#
    .SYNOPSIS
        Updates CurrentUser PowerShell modules and removes older versions.
    .DESCRIPTION
        Updates modules installed via PowerShellGet in the CurrentUser scope, then keeps the
        newest version plus the number of older versions selected with KeepVersions.
    .PARAMETER LogPath
        Log file path. Defaults to Update-CurrentUserModules_<yyyyMMdd-HHmmss>.log in the current
        directory. If a directory is given, the default file name is created inside it.
    .PARAMETER KeepVersions
        Number of older versions to keep in addition to the newest version. Defaults to 1.
    .PARAMETER Name
        Optional module name filter. Wildcards are supported. Defaults to all modules.
    .PARAMETER Repository
        Repository to check for updates. Defaults to PSGallery.
    .PARAMETER CleanupOnly
        Skips repository checks and only removes old versions.
    .EXAMPLE
        Update-CurrentUserModules -WhatIf -Verbose
        Previews CurrentUser module updates and removals.
    .EXAMPLE
        Update-CurrentUserModules -CleanupOnly -KeepVersions 0
        Keeps only the newest CurrentUser version of each module.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter()][string]$LogPath,
        [Parameter()][ValidateRange(0, 100)][int]$KeepVersions = 1,
        [Parameter()][string[]]$Name = '*',
        [Parameter()][string]$Repository = 'PSGallery',
        [Parameter()][switch]$CleanupOnly
    )

    Invoke-ModuleMaintenance -Scope CurrentUser -CommandName $MyInvocation.MyCommand.Name `
        -CallerPSCmdlet $PSCmdlet -LogPath $LogPath -KeepVersions $KeepVersions -Name $Name `
        -Repository $Repository -CleanupOnly:$CleanupOnly
}
