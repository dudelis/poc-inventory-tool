BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\Modules\InventorySync\InventorySync.psd1'
    Import-Module $modulePath -Force
}

Describe 'Agent Builder sync' {
    It 'creates a Default-environment component by Admin GUID and leaves its rerun unchanged' {
        $script:defaultComponent = $null
        $script:defaultBatches = 0
        $script:defaultEnvironment = [pscustomobject] @{
            palp_id = 'Default-4658d2db-ccde-47b9-84f0-8e9b'
            palp_adminguid = 'Default-4658d2db-ccde-47b9-84f0-8e9bbf015628'
            palp_environmentid = '5a5c35ce-3fc6-f111-aaad-000d3ab63df3'
        }
        Mock Invoke-WebRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            if ($uriText -match 'Microsoft\.ResourceGraph/resources') {
                $content = [pscustomobject] @{ data = @(
                    [pscustomobject] @{
                        agentId = 'agent-1'; title = 'Default agent'; description = 'Test agent'
                        environmentId = 'default-4658d2db-ccde-47b9-84f0-8e9bbf015628'
                        ownerId = 'owner-1'; createdAt = '2026-09-01T08:00:00Z'
                        modifiedAt = ''
                    }
                ) } | ConvertTo-Json -Depth 10
                return [pscustomobject] @{ StatusCode = 200; Headers = @{}; Content = $content }
            }
            if ($uriText -match '/palp_environments\?') {
                $uriText | Should -Match '\$select=palp_adminguid,palp_environmentid$'
                $content = [pscustomobject] @{
                    value = @($script:defaultEnvironment)
                } | ConvertTo-Json -Depth 10
                return [pscustomobject] @{ StatusCode = 200; Headers = @{}; Content = $content }
            }
            if ($uriText -match '/palp_komponentes\?') {
                $uriText | Should -MatchExactly '\$expand=palp_Environment\(\$select=palp_adminguid,palp_environmentid\)'
                $rows = @(if ($null -ne $script:defaultComponent) { $script:defaultComponent })
                $content = [pscustomobject] @{ value = $rows } | ConvertTo-Json -Depth 10
                return [pscustomobject] @{ StatusCode = 200; Headers = @{}; Content = $content }
            }
            if ($uriText -match '/\$batch$') {
                $script:defaultBatches++
                [string] $Body | Should -MatchExactly '"palp_Environment@odata.bind"'
                [string] $Body | Should -MatchExactly '"palp_urspruenglicherstelltam":"2026-09-01T08:00:00Z"'
                [string] $Body | Should -MatchExactly '"palp_urspruenglichgeaendertam":"2026-09-01T08:00:00Z"'
                $payload = ([string] $Body -split '\r?\n' | Where-Object { $_.StartsWith('{') }) |
                    ConvertFrom-Json -DateKind String
                $payload.'palp_environment@odata.bind' |
                    Should -Be '/palp_environments(5a5c35ce-3fc6-f111-aaad-000d3ab63df3)'
                $script:defaultComponent = $payload
                $script:defaultComponent | Add-Member -NotePropertyName palp_environment `
                    -NotePropertyValue $script:defaultEnvironment
                return [pscustomobject] @{ StatusCode = 200; Headers = @{}; Content = '' }
            }
            throw "Unexpected request: $uriText"
        }
        $parameters = @{
            Configuration = [pscustomobject] @{
                TargetDataverseUrl = 'https://example.crm.dynamics.com'
                AgentCreatedIn = 'Copilot Studio Lite'
                MaxCreatesPerRun = 5
            }
            ResourceGraphAccessToken = 'graph-token'
            DataverseAccessToken = 'target-token'
        }

        $first = Invoke-AgentSync @parameters
        $second = Invoke-AgentSync @parameters

        $first.Status | Should -Be 'Succeeded'
        $first.Counts.Created | Should -Be 1
        $first.Counts.Skipped | Should -Be 0
        $first.Counts.Errors | Should -Be 0
        $first.Counts.EnvironmentsFailed | Should -Be 0
        $first.Logs | Should -HaveCount 1
        $first.Logs[0].Severity | Should -Be 'Warning'
        $first.Logs[0].Category | Should -Be 'Config'
        $first.Logs[0].Message | Should -Match 'fallback.*creation timestamp'
        $second.Status | Should -Be 'Succeeded'
        $second.Counts.Created | Should -Be 0
        $second.Counts.Updated | Should -Be 0
        $second.Counts.Unchanged | Should -Be 1
        $second.Counts.EnvironmentsFailed | Should -Be 0
        $second.Logs | Should -HaveCount 1
        $script:defaultBatches | Should -Be 1
    }

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
                        value = @([pscustomobject] @{ palp_id = 'legacy-environment-1'; palp_adminguid = 'environment-1'; palp_environmentid = '00000000-0000-0000-0000-000000000001' })
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
        $script:requestedUris[1] | Should -Match '/palp_environments\?\$select=palp_adminguid,palp_environmentid$'
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
                        value = @([pscustomobject] @{ palp_id = 'legacy-environment-1'; palp_adminguid = 'environment-1'; palp_environmentid = '00000000-0000-0000-0000-000000000001' })
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
                                palp_environment = [pscustomobject] @{ palp_id = 'legacy-environment-1'; palp_adminguid = 'environment-1'; palp_environmentid = '00000000-0000-0000-0000-000000000001' }
                                palp_urspruenglicherstelltam = '2026-09-01T08:00:00Z'
                                palp_urspruenglichgeaendertam = '2026-09-02T09:00:00Z'
                                palp_komponentenstatus = 3; palp_status = 0
                            },
                            [pscustomobject] @{
                                palp_id = $unchangedId; palp_titel = 'Unchanged title'
                                palp_besitzerobjectid = 'owner-1'
                                palp_beschreibung = 'Description'
                                palp_environment = [pscustomobject] @{ palp_id = 'legacy-environment-1'; palp_adminguid = 'environment-1'; palp_environmentid = '00000000-0000-0000-0000-000000000001' }
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
        $script:componentReadUris[0] | Should -Match '\$expand=palp_environment\(\$select=palp_adminguid,palp_environmentid\)'
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
                        value = @([pscustomobject] @{ palp_id = 'legacy-environment-1'; palp_adminguid = 'environment-1'; palp_environmentid = '00000000-0000-0000-0000-000000000001' })
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
