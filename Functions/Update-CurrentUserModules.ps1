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
