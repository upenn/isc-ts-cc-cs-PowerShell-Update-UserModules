@{
    RootModule        = 'Update-UserModules.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '8d7f39fb-bcff-4d6d-a9f7-8f42a28d321e'
    Author            = 'isc-ts-cc-cs'
    Description       = 'Updates CurrentUser or AllUsers PowerShell modules and removes older versions.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Update-CurrentUserModules', 'Update-AllUsersModules')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('PowerShell', 'ModuleManagement', 'PowerShellGet')
        }
    }
}
