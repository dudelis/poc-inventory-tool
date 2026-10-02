@{
    RootModule        = 'InventorySync.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '89d605f0-44cb-497c-a664-96c6c13d2bfc'
    Author            = 'PALP inventory sync'
    PowerShellVersion = '7.6'
    FunctionsToExport = @(
        'Get-InventorySyncConfiguration'
        'Get-InventoryAccessToken'
        'Clear-InventoryTokenCache'
        'Invoke-InventoryHttpRequest'
        'Get-DataversePagedRecords'
        'Invoke-ResourceGraphPagedQuery'
        'Write-InventoryTrace'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
