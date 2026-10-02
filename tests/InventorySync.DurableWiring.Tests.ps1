BeforeAll {
    $durableSdkPath = Join-Path $PSScriptRoot `
        '..\src\Modules\AzureFunctions.PowerShell.Durable.SDK\2.4.0\AzureFunctions.PowerShell.Durable.SDK.psd1'
    Import-Module $durableSdkPath -Force
    $modulePath = Join-Path $PSScriptRoot '..\src\Modules\InventorySync\InventorySync.psd1'
    Import-Module $modulePath -Force
}

Describe 'Durable orchestrator wiring' {
    It 'calls the sync activity of each sync type with the propagated correlation ID' -ForEach @(
        @{ SyncType = 'AgentBuilder'; ActivityName = 'AgentSyncCreateActivity' }
        @{ SyncType = 'RPA'; ActivityName = 'RpaSyncActivity' }
    ) {
        $script:activityCalls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-DurableActivity -ModuleName InventorySync {
            $script:activityCalls.Add([pscustomobject] @{
                FunctionName = $PesterBoundParameters['FunctionName']
                Input        = $PesterBoundParameters['Input']
            })
        }
        $context = [pscustomobject] @{
            InstanceId = 'fixed-instance'
            Input      = [pscustomobject] @{ CorrelationId = 'timer-correlation' }
        }

        Invoke-InventorySyncOrchestrator -SyncType $SyncType -Context $context

        $script:activityCalls | Should -HaveCount 1
        $script:activityCalls[0].FunctionName | Should -Be $ActivityName
        $script:activityCalls[0].Input.CorrelationId | Should -Be 'timer-correlation'
    }
}

Describe 'Durable timer wiring' {
    It 'starts the fixed orchestration instance on the first run, when no instance exists yet' -ForEach @(
        @{
            SyncType = 'AgentBuilder'; InstanceId = 'agent-builder-inventory-sync'
            OrchestratorName = 'AgentSyncOrchestrator'
        }
        @{
            SyncType = 'RPA'; InstanceId = 'rpa-inventory-sync'
            OrchestratorName = 'RpaSyncOrchestrator'
        }
    ) {
        Mock Get-DurableStatus -ModuleName InventorySync {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new(
                'Response status code does not indicate success: 404 (Not Found).', $response)
        }
        $script:startCalls = [System.Collections.Generic.List[object]]::new()
        Mock Start-DurableOrchestration -ModuleName InventorySync {
            $script:startCalls.Add([pscustomobject] @{
                FunctionName = $PesterBoundParameters['FunctionName']
                InstanceId   = $PesterBoundParameters['InstanceId']
            })
        }

        Invoke-InventorySyncTimer -SyncType $SyncType -DurableClient ([pscustomobject] @{})

        $script:startCalls | Should -HaveCount 1
        $script:startCalls[0].FunctionName | Should -Be $OrchestratorName
        $script:startCalls[0].InstanceId | Should -Be $InstanceId
    }

    It 'fails without starting a run when the status check fails for another reason' {
        Mock Get-DurableStatus -ModuleName InventorySync {
            $response = [System.Net.Http.HttpResponseMessage]::new(
                [System.Net.HttpStatusCode]::InternalServerError)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new(
                'Response status code does not indicate success: 500 (Internal Server Error).', $response)
        }
        Mock Start-DurableOrchestration -ModuleName InventorySync {}

        { Invoke-InventorySyncTimer -SyncType AgentBuilder -DurableClient ([pscustomobject] @{}) } |
            Should -Throw '*500*'
        Should -Invoke Start-DurableOrchestration -ModuleName InventorySync -Times 0 -Exactly
    }
}
