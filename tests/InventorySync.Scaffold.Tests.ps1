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

    It 'provides concrete daily schedules for both app-setting-backed timer bindings' {
        $settings = Get-Content (Join-Path $projectRoot 'local.settings.example.json') -Raw |
            ConvertFrom-Json
        foreach ($syncName in @('AGENT', 'RPA')) {
            $functionName = if ($syncName -eq 'AGENT') { 'AgentSyncTimer' } else { 'RpaSyncTimer' }
            $binding = Get-Content (Join-Path $projectRoot "$functionName\function.json") -Raw |
                ConvertFrom-Json
            $binding.bindings[0].schedule | Should -Be "%INVENTORY_${syncName}_SCHEDULE%"
            $settings.Values."INVENTORY_${syncName}_SCHEDULE" | Should -Be '0 0 0 * * *'
        }
    }

    It 'loads cohesive private scripts instead of one monolithic implementation file' {
        $moduleRoot = Join-Path $projectRoot 'Modules\InventorySync'
        (Get-Content (Join-Path $moduleRoot 'InventorySync.psm1')).Count | Should -BeLessThan 100
        @(Get-ChildItem (Join-Path $moduleRoot 'Private') -Filter '*.ps1').Count |
            Should -BeGreaterOrEqual 5
    }

    It 'keeps timer, orchestrator, and activity wrappers parameterized and logic-free' {
        $wrappers = @{
            'AgentSyncTimer'          = 'Invoke-InventorySyncTimer -SyncType AgentBuilder'
            'RpaSyncTimer'            = 'Invoke-InventorySyncTimer -SyncType RPA'
            'AgentSyncOrchestrator'   = 'Invoke-InventorySyncOrchestrator -SyncType AgentBuilder'
            'RpaSyncOrchestrator'     = 'Invoke-InventorySyncOrchestrator -SyncType RPA'
            'AgentSyncCreateActivity' = 'Invoke-InventorySyncActivity -SyncType AgentBuilder'
            'RpaSyncActivity'         = 'Invoke-InventorySyncActivity -SyncType RPA'
        }

        foreach ($wrapper in $wrappers.GetEnumerator()) {
            $text = Get-Content (Join-Path $projectRoot "$($wrapper.Key)\run.ps1") -Raw
            $text | Should -Match ([regex]::Escape($wrapper.Value))
            $text | Should -Not -Match 'Get-DurableStatus|Start-DurableOrchestration|Get-InventorySyncConfiguration'
        }
    }
}

Describe 'Structured telemetry' {
    It 'uses the current Application Insights operation trace ID and has explicit fallbacks' {
        $previousActivity = [System.Diagnostics.Activity]::Current
        try {
            [System.Diagnostics.Activity]::DefaultIdFormat =
                [System.Diagnostics.ActivityIdFormat]::W3C
            $activity = [System.Diagnostics.Activity]::new('inventory-test').Start()
            Get-InventoryOperationId -Fallback 'fallback-id' |
                Should -Be $activity.TraceId.ToString()
            $activity.Stop()

            Get-InventoryOperationId -Fallback 'fallback-id' | Should -Be 'fallback-id'
            Get-InventoryOperationId | Should -Match '^[0-9a-f-]{36}$'
        }
        finally {
            if ($null -ne [System.Diagnostics.Activity]::Current) {
                [System.Diagnostics.Activity]::Current.Stop()
            }
            $previousActivity | Out-Null
        }
    }

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
