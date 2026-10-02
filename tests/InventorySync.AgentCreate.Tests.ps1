BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\Modules\InventorySync\InventorySync.psd1'
    Import-Module $modulePath -Force
}

Describe 'Agent Builder collection and creation' {
    BeforeEach {
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            [pscustomobject] @{
                Body = [pscustomobject] @{
                    data = @(
                        [pscustomobject] @{
                            agentId       = 'agent-1'
                            title         = 'Agent one'
                            environmentId = 'environment-1'
                            ownerId       = 'owner-1'
                            createdAt     = '2026-09-01T08:00:00Z'
                            modifiedAt    = '2026-09-02T09:00:00Z'
                        }
                    )
                }
            }

        }
    }

    It 'queries Agent Builder agents tenant-wide without subscription scoping' {
        $script:agentRequestBody = $null
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $script:agentRequestBody = $Body
            [pscustomobject] @{
                Body = [pscustomobject] @{ data = @([pscustomobject] @{ agentId = 'agent-1' }) }
            }
        }
        $agents = @(Get-AgentBuilderAgents -CreatedIn 'Microsoft 365 Copilot Agent Builder' `
            -AccessToken 'token')

        $agents.agentId | Should -Be 'agent-1'
        $script:agentRequestBody.PSObject.Properties['subscriptions'] | Should -BeNullOrEmpty
        Should -Invoke Invoke-InventoryHttpRequest -ModuleName InventorySync -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and
            $Body.query -match 'PowerPlatformResources' -and
            $Body.query -match 'microsoft\.copilotstudio/agents' -and
            $Body.query -match [regex]::Escape('"Microsoft 365 Copilot Agent Builder"') -and
            $Body.query -match 'properties\.createdIn' -and
            $Body.query -match 'properties\.displayName' -and
            $Body.query -match 'properties\.ownerId' -and
            $Body.query -match 'properties\.environmentId' -and
            $Body.query -match 'properties\.createdAt' -and
            $Body.query -match 'properties\.lastModifiedAt'
        }
    }
}
