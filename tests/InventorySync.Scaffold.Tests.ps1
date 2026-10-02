BeforeAll {
    $script:projectRoot = Join-Path $PSScriptRoot '..\src'
    $modulePath = Join-Path $projectRoot 'Modules\InventorySync\InventorySync.psd1'
    Import-Module $modulePath -Force
}

Describe 'PowerShell Azure Functions scaffold' {
    It 'targets PowerShell 7.6 and Functions runtime v4' {
        $settings = Get-Content (Join-Path $projectRoot 'local.settings.example.json') -Raw | ConvertFrom-Json

        $settings.Values.FUNCTIONS_WORKER_RUNTIME | Should -Be 'powershell'
        $settings.Values.FUNCTIONS_WORKER_RUNTIME_VERSION | Should -Be '7.6'
        $settings.Values.FUNCTIONS_EXTENSION_VERSION | Should -Be '~4'
    }

    It 'uses the standalone Durable PowerShell SDK' {
        $requirements = Import-PowerShellDataFile (Join-Path $projectRoot 'requirements.psd1')
        $hostConfiguration = Get-Content (Join-Path $projectRoot 'host.json') -Raw | ConvertFrom-Json

        $requirements['AzureFunctions.PowerShell.Durable.SDK'] | Should -Be '2.*'
        $hostConfiguration.managedDependency.enabled | Should -BeTrue
    }

    It 'configures Application Insights by connection string only' {
        $settingsText = Get-Content (Join-Path $projectRoot 'local.settings.example.json') -Raw
        $settings = $settingsText | ConvertFrom-Json

        $settings.Values.APPLICATIONINSIGHTS_CONNECTION_STRING | Should -Not -BeNullOrEmpty
        $settingsText | Should -Not -Match 'APPINSIGHTS_INSTRUMENTATIONKEY'
    }
}

Describe 'Structured telemetry' {
    It 'writes structured information, warning, and error records' {
        $informationRecord = Write-InventoryTrace -Level Information -Message 'Started' `
            -CorrelationId 'correlation-id' -Data @{ syncType = 'RPA' } -InformationAction Continue 6>&1
        $warningRecord = Write-InventoryTrace -Level Warning -Message 'Throttled' `
            -CorrelationId 'correlation-id' -Data @{ retryAfter = 2 } 3>&1
        $errorRecord = Write-InventoryTrace -Level Error -Message 'Failed' `
            -CorrelationId 'correlation-id' -Data @{ statusCode = 500 } -ErrorAction Continue 2>&1

        $information = $informationRecord.MessageData | ConvertFrom-Json
        $warning = $warningRecord.Message | ConvertFrom-Json
        $error = $errorRecord.Exception.Message | ConvertFrom-Json
        $information.level | Should -Be 'Information'
        $information.correlationId | Should -Be 'correlation-id'
        $information.data.syncType | Should -Be 'RPA'
        $warning.level | Should -Be 'Warning'
        $warning.data.retryAfter | Should -Be 2
        $error.level | Should -Be 'Error'
        $error.data.statusCode | Should -Be 500
    }
}
