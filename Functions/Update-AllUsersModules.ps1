function Update-AllUsersModules {
    <#
    .SYNOPSIS
        Updates AllUsers PowerShell modules and removes older versions.
    .DESCRIPTION
        Updates modules installed via PowerShellGet in the AllUsers scope, then keeps the newest
        version plus the number of older versions selected with KeepVersions. Run this command in
        an elevated PowerShell session so system-wide module files can be changed.
    .PARAMETER LogPath
        Log file path. Defaults to Update-AllUsersModules_<yyyyMMdd-HHmmss>.log in the current
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
        Update-AllUsersModules -WhatIf -Verbose
        Previews system-wide module updates and removals.
    .EXAMPLE
        Update-AllUsersModules -CleanupOnly -KeepVersions 0
        Keeps only the newest system-wide version of each module.
    .NOTES
        AllUsers module locations are Program Files on Windows and
        /usr/local/share/powershell/Modules on macOS and Linux.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter()][string]$LogPath,
        [Parameter()][ValidateRange(0, 100)][int]$KeepVersions = 1,
        [Parameter()][string[]]$Name = '*',
        [Parameter()][string]$Repository = 'PSGallery',
        [Parameter()][switch]$CleanupOnly
    )

    Invoke-ModuleMaintenance -Scope AllUsers -CommandName $MyInvocation.MyCommand.Name `
        -CallerPSCmdlet $PSCmdlet -LogPath $LogPath -KeepVersions $KeepVersions -Name $Name `
        -Repository $Repository -CleanupOnly:$CleanupOnly
}
