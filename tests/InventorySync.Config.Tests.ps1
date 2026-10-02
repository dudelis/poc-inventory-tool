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
            INVENTORY_AGENT_CREATED_IN                = ' Agent Builder '
            APPLICATIONINSIGHTS_CONNECTION_STRING     = 'InstrumentationKey=test'
        }

        $configuration = Get-InventorySyncConfiguration -Settings $settings

        $configuration.TenantId | Should -Be 'tenant-id'
        $configuration.ClientId | Should -Be 'client-id'
        $configuration.ClientSecret | Should -Be 'secret'
        $configuration.TargetDataverseUrl | Should -Be 'https://example.crm.dynamics.com'
        $configuration.AgentCreatedIn | Should -Be 'Agent Builder'
        $configuration.ApplicationInsightsConnectionString | Should -Be 'InstrumentationKey=test'
    }

    It 'uses a daily Agent schedule by default and accepts an app-setting override' {
        $settings = @{
            INVENTORY_TENANT_ID                   = 'tenant-id'
            INVENTORY_CLIENT_ID                   = 'client-id'
            INVENTORY_CLIENT_SECRET               = 'secret'
            INVENTORY_TARGET_DATAVERSE_URL        = 'https://example.crm.dynamics.com'
            INVENTORY_AGENT_CREATED_IN            = 'Agent Builder'
            APPLICATIONINSIGHTS_CONNECTION_STRING = 'InstrumentationKey=test'
        }

        (Get-InventorySyncConfiguration -Settings $settings).AgentSchedule |
            Should -Be '0 0 0 * * *'
        $settings.INVENTORY_AGENT_SCHEDULE = '0 30 1 * * *'
        (Get-InventorySyncConfiguration -Settings $settings).AgentSchedule |
            Should -Be '0 30 1 * * *'
    }

    It 'uses configurable Dataverse logging table names' {
        $settings = @{
            INVENTORY_TENANT_ID                   = 'tenant-id'
            INVENTORY_CLIENT_ID                   = 'client-id'
            INVENTORY_CLIENT_SECRET               = 'secret'
            INVENTORY_TARGET_DATAVERSE_URL        = 'https://example.crm.dynamics.com'
            INVENTORY_AGENT_CREATED_IN            = 'Agent Builder'
            APPLICATIONINSIGHTS_CONNECTION_STRING = 'InstrumentationKey=test'
            INVENTORY_SYNC_RUN_TABLE              = 'custom_runs'
            INVENTORY_SYNC_LOG_TABLE              = 'custom_logs'
        }

        $configuration = Get-InventorySyncConfiguration -Settings $settings

        $configuration.SyncRunTable | Should -Be 'custom_runs'
        $configuration.SyncLogTable | Should -Be 'custom_logs'
    }

    It 'reads the per-run creation cap from app settings' {
        $settings = @{
            INVENTORY_TENANT_ID                   = 'tenant-id'
            INVENTORY_CLIENT_ID                   = 'client-id'
            INVENTORY_CLIENT_SECRET               = 'secret'
            INVENTORY_TARGET_DATAVERSE_URL        = 'https://example.crm.dynamics.com'
            INVENTORY_AGENT_CREATED_IN            = 'Agent Builder'
            INVENTORY_MAX_CREATES_PER_RUN         = '12'
            APPLICATIONINSIGHTS_CONNECTION_STRING = 'InstrumentationKey=test'
        }

        (Get-InventorySyncConfiguration -Settings $settings).MaxCreatesPerRun |
            Should -Be 12
        $settings.Remove('INVENTORY_MAX_CREATES_PER_RUN')
        (Get-InventorySyncConfiguration -Settings $settings).MaxCreatesPerRun |
            Should -Be 1000
    }
}
