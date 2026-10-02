BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\Modules\InventorySync\InventorySync.psd1'
    Import-Module $modulePath -Force
}

Describe 'Agent Builder sync' {
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

    It 'reads type 5 rows once and sends only a changed technical field' {
        $updatedId = New-InventoryComponentId -EnvironmentId 'environment-1' `
            -ComponentType 5 -SourceId 'updated-agent'
        $unchangedId = New-InventoryComponentId -EnvironmentId 'environment-1' `
            -ComponentType 5 -SourceId 'unchanged-agent'
        $script:componentReadUris = [System.Collections.Generic.List[string]]::new()
        $script:batchBody = $null
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            if ($uriText -match 'Microsoft\.ResourceGraph/resources') {
                return [pscustomobject] @{
                    Body = [pscustomobject] @{
                        data = @(
                            [pscustomobject] @{
                                agentId = 'updated-agent'; title = 'Current title'
                                description = 'Description'; environmentId = 'environment-1'
                                ownerId = 'owner-1'; createdAt = '2026-09-01T08:00:00Z'
                                modifiedAt = '2026-09-02T09:00:00Z'
                            },
                            [pscustomobject] @{
                                agentId = 'unchanged-agent'; title = 'Unchanged title'
                                description = 'Description'; environmentId = 'environment-1'
                                ownerId = 'owner-1'; createdAt = '2026-09-01T08:00:00Z'
                                modifiedAt = '2026-09-02T09:00:00Z'
                            }
                        )
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
                $script:componentReadUris.Add($uriText)
                return [pscustomobject] @{
                    Body = [pscustomobject] @{
                        value = @(
                            [pscustomobject] @{
                                palp_id = $updatedId; palp_titel = 'Old title'
                                palp_besitzerobjectid = 'owner-1'
                                palp_beschreibung = 'Description'
                                palp_environment = [pscustomobject] @{ palp_id = 'environment-1' }
                                palp_urspruenglicherstelltam = '2026-09-01T08:00:00Z'
                                palp_urspruenglichgeaendertam = '2026-09-02T09:00:00Z'
                                palp_komponentenstatus = 3; palp_status = 0
                            },
                            [pscustomobject] @{
                                palp_id = $unchangedId; palp_titel = 'Unchanged title'
                                palp_besitzerobjectid = 'owner-1'
                                palp_beschreibung = 'Description'
                                palp_environment = [pscustomobject] @{ palp_id = 'environment-1' }
                                palp_urspruenglicherstelltam = '2026-09-01T08:00:00Z'
                                palp_urspruenglichgeaendertam = '2026-09-02T09:00:00Z'
                            }
                        )
                    }
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
            MaxCreatesPerRun   = 10
        }

        $result = Invoke-AgentSync -Configuration $configuration `
            -ResourceGraphAccessToken 'graph-token' -DataverseAccessToken 'target-token'

        $result.Counts.Updated | Should -Be 1
        $result.Counts.Unchanged | Should -Be 1
        $result.Counts.Created | Should -Be 0
        $script:componentReadUris | Should -HaveCount 1
        $script:componentReadUris[0] | Should -Match '\$filter=palp_typ eq 5$'
        $script:componentReadUris[0] | Should -Match '\$expand=palp_environment\(\$select=palp_id\)'
        $script:batchBody | Should -Match "PATCH palp_komponentes\(palp_id='$updatedId'\)"
        $script:batchBody | Should -Match '"palp_titel":"Current title"'
        $script:batchBody | Should -Not -Match ([regex]::Escape($unchangedId))
        $script:batchBody | Should -Not -Match 'palp_komponentenstatus|palp_status|palp_nutzungsbereich'
    }

    It 'does not let an invalid environment consume the creation cap and logs overflow' {
        $validId = New-InventoryComponentId -EnvironmentId 'environment-1' `
            -ComponentType 5 -SourceId 'valid-agent'
        $orphanId = New-InventoryComponentId -EnvironmentId 'missing-environment' `
            -ComponentType 5 -SourceId 'orphan-agent'
        $script:batchBody = $null
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            if ($uriText -match 'Microsoft\.ResourceGraph/resources') {
                return [pscustomobject] @{
                    Body = [pscustomobject] @{
                        data = @(
                            [pscustomobject] @{
                                agentId = 'orphan-agent'; title = 'Orphan'
                                description = ''; environmentId = 'missing-environment'
                                ownerId = 'owner-1'; createdAt = '2026-09-01T08:00:00Z'
                                modifiedAt = '2026-09-02T09:00:00Z'
                            },
                            [pscustomobject] @{
                                agentId = 'valid-agent'; title = 'Valid'
                                description = ''; environmentId = 'environment-1'
                                ownerId = 'owner-1'; createdAt = '2026-09-01T08:00:00Z'
                                modifiedAt = '2026-09-02T09:00:00Z'
                            },
                            [pscustomobject] @{
                                agentId = 'overflow-agent'; title = 'Overflow'
                                description = ''; environmentId = 'environment-1'
                                ownerId = 'owner-1'; createdAt = '2026-09-01T08:00:00Z'
                                modifiedAt = '2026-09-02T09:00:00Z'
                            }
                        )
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
                return [pscustomobject] @{ Body = [pscustomobject] @{ value = @() } }
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
            MaxCreatesPerRun   = 1
        }

        $result = Invoke-AgentSync -Configuration $configuration `
            -ResourceGraphAccessToken 'graph-token' -DataverseAccessToken 'target-token' `
            -WarningAction SilentlyContinue

        $result.Counts.Created | Should -Be 1
        $result.Counts.Skipped | Should -Be 2
        ($result.Logs.Message -join '|') | Should -Match 'not present in palp_environment'
        ($result.Logs.Message -join '|') | Should -Match 'creation cap of 1'
        $script:batchBody | Should -Match ([regex]::Escape($validId))
        $script:batchBody | Should -Not -Match ([regex]::Escape($orphanId))
    }
}
