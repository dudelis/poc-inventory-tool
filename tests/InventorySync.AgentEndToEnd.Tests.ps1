BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\Modules\InventorySync\InventorySync.psd1'
    Import-Module $modulePath -Force
}

Describe 'Agent Builder create sync' {
    It 'collects tenant agents, reads target rows, and batches missing components' {
        $script:requestedUris = [System.Collections.Generic.List[string]]::new()
        $script:batchBody = $null
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            $script:requestedUris.Add($uriText)
            if ($uriText -match 'Microsoft\.ResourceGraph/resources') {
                return [pscustomobject] @{
                    Body = [pscustomobject] @{
                        data = @([pscustomobject] @{
                            agentId       = 'agent-1'
                            title         = 'Agent one'
                            environmentId = 'environment-1'
                            ownerId       = 'owner-1'
                            createdAt     = '2026-09-01T08:00:00Z'
                            modifiedAt    = '2026-09-02T09:00:00Z'
                        })
                    }
                }
            }
            if ($uriText -match '/palp_environments\?') {
                return [pscustomobject] @{
                    Body = [pscustomobject] @{
                        value = @([pscustomobject] @{ palp_id = 'environment-1' })
                    }
                }
            }
            if ($uriText -match '/palp_komponentes\?') {
                return [pscustomobject] @{
                    Body = [pscustomobject] @{ value = @() }
                }
            }
            if ($uriText -match '/\$batch$') {
                $script:batchBody = [string] $Body
                return [pscustomobject] @{ StatusCode = 200; Body = $null }
            }
            throw "Unexpected request: $uriText"
        }
        $configuration = [pscustomobject] @{
            TargetDataverseUrl = 'https://example.crm.dynamics.com'
            AgentCreatedIn     = 'Agent Builder'
            AgentSubscriptions = @()
        }

        $result = Invoke-AgentCreateSync -Configuration $configuration `
            -ResourceGraphAccessToken 'graph-token' -DataverseAccessToken 'target-token' `
            -Now ([datetimeoffset] '2026-10-02T10:00:00Z')

        $result.Counts.Found | Should -Be 1
        $result.Counts.Created | Should -Be 1
        $result.Counts.Skipped | Should -Be 0
        $result.Batch.Batches | Should -Be 1
        $script:requestedUris | Should -HaveCount 4
        $script:requestedUris[1] | Should -Match '/palp_environments\?\$select=palp_id$'
        $script:requestedUris[2] |
            Should -Match '/palp_komponentes\?\$select=palp_id&\$filter=palp_typ eq 5$'
        $script:batchBody | Should -Match '"palp_id":"8c1faa29-db0a-5c1e-9616-f2ede5028847"'
    }
}
