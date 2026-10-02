BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\Modules\InventorySync\InventorySync.psd1'
    Import-Module $modulePath -Force
}

Describe 'Inventory sync configuration' {
    It 'reports every missing required app setting' {
        $settings = @{
            INVENTORY_TENANT_ID = 'tenant-id'
        }

        {
            Get-InventorySyncConfiguration -Settings $settings
        } | Should -Throw '*INVENTORY_CLIENT_ID*INVENTORY_CLIENT_SECRET*INVENTORY_TARGET_DATAVERSE_URL*APPLICATIONINSIGHTS_CONNECTION_STRING*'
    }

    It 'returns normalized required settings from app settings' {
        $settings = @{
            INVENTORY_TENANT_ID                       = ' tenant-id '
            INVENTORY_CLIENT_ID                       = ' client-id '
            INVENTORY_CLIENT_SECRET                   = ' secret '
            INVENTORY_TARGET_DATAVERSE_URL            = 'https://example.crm.dynamics.com/'
            APPLICATIONINSIGHTS_CONNECTION_STRING     = 'InstrumentationKey=test'
        }

        $configuration = Get-InventorySyncConfiguration -Settings $settings

        $configuration.TenantId | Should -Be 'tenant-id'
        $configuration.ClientId | Should -Be 'client-id'
        $configuration.ClientSecret | Should -Be 'secret'
        $configuration.TargetDataverseUrl | Should -Be 'https://example.crm.dynamics.com'
        $configuration.ApplicationInsightsConnectionString | Should -Be 'InstrumentationKey=test'
    }
}
