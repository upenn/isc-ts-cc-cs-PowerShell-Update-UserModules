$functionFiles = Get-ChildItem -Path (Join-Path $PSScriptRoot 'Functions') -Filter '*.ps1' -File

foreach ($functionFile in $functionFiles) {
    . $functionFile.FullName
}

Export-ModuleMember -Function 'Update-CurrentUserModules', 'Update-AllUsersModules'
