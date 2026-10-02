BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\Modules\InventorySync\InventorySync.psd1'
    Import-Module $modulePath -Force
}

Describe 'Agent Builder environment validation' {
    It 'does not write an agent whose target environment is absent and emits a warning' {
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            if ($uriText -match 'Microsoft\.ResourceGraph/resources') {
                return [pscustomobject] @{
                    Body = [pscustomobject] @{
                        data = @([pscustomobject] @{
                            agentId = 'orphan-agent'; title = 'Orphan'
                            environmentId = 'missing-environment'; ownerId = 'owner-1'
                            createdAt = '2026-09-01T08:00:00Z'
                            modifiedAt = '2026-09-02T09:00:00Z'
                        })
                    }
                }
            }
            if ($uriText -match '/palp_environments\?') {
                return [pscustomobject] @{ Body = [pscustomobject] @{ value = @() } }
            }
            if ($uriText -match '/palp_komponentes\?') {
                return [pscustomobject] @{ Body = [pscustomobject] @{ value = @() } }
            }
            throw "A write was not expected: $uriText"
        }
        $configuration = [pscustomobject] @{
            TargetDataverseUrl = 'https://example.crm.dynamics.com'
            AgentCreatedIn     = 'Agent Builder'
            AgentSubscriptions = @()
        }

        $result = Invoke-AgentCreateSync -Configuration $configuration `
            -ResourceGraphAccessToken 'graph-token' -DataverseAccessToken 'target-token' `
            -WarningVariable warnings -WarningAction SilentlyContinue

        $result.Counts.Found | Should -Be 1
        $result.Counts.Created | Should -Be 0
        $result.Counts.Skipped | Should -Be 1
        $result.Logs[0].EnvironmentId | Should -Be 'missing-environment'
        $warnings.Message | Should -Match 'not present in palp_environment'
        Should -Invoke Invoke-InventoryHttpRequest -ModuleName InventorySync -Times 3 -Exactly
    }
}
