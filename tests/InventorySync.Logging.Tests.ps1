BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\Modules\InventorySync\InventorySync.psd1'
    Import-Module $modulePath -Force
}

Describe 'Shared Dataverse logging writers' {
    It 'creates a running Sync Run header in the configured table' {
        $script:request = $null
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $script:request = [pscustomobject] @{
                Uri = [string] $Uri
                Method = $Method
                Body = $Body
            }
            [pscustomobject] @{ StatusCode = 204; Headers = @{}; Body = $null }
        }

        $result = Start-InventorySyncRun -DataverseUrl 'https://example.crm.dynamics.com' `
            -AccessToken 'target-token' -TableName 'custom_runs' `
            -RunId 'correlation-id' -SyncType AgentBuilder `
            -StartedOn ([datetimeoffset] '2026-10-02T10:00:00Z')

        $result.Persisted | Should -BeTrue
        $result.RecordId | Should -Match '^[0-9a-f-]{36}$'
        $script:request.Uri | Should -Be 'https://example.crm.dynamics.com/api/data/v9.2/custom_runs'
        $script:request.Method | Should -Be 'POST'
        $script:request.Body.invs_runid | Should -Be 'correlation-id'
        $script:request.Body.invs_synctype | Should -Be 100000001
        $script:request.Body.invs_phase | Should -Be 100000000
        $script:request.Body.invs_status | Should -Be 100000000
        $script:request.Body.invs_startedon | Should -Be '2026-10-02T10:00:00.0000000+00:00'
    }

    It 'completes the Sync Run header with final status and counts' {
        $script:request = $null
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $script:request = [pscustomobject] @{
                Uri = [string] $Uri
                Method = $Method
                Body = $Body
            }
            [pscustomobject] @{ StatusCode = 204; Headers = @{}; Body = $null }
        }
        $counts = [pscustomobject] @{
            EnvironmentsTotal = 3; EnvironmentsFailed = 1; Found = 8
            Created = 4; Updated = 1; Unchanged = 2; MarkedDeleted = 0
            Restored = 0; Errors = 1
        }

        $result = Complete-InventorySyncRun -DataverseUrl 'https://example.crm.dynamics.com/' `
            -AccessToken 'target-token' -TableName 'custom_runs' `
            -RecordId '11111111-1111-1111-1111-111111111111' -RunId 'correlation-id' `
            -Phase Write -Status Partial -Counts $counts `
            -CompletedOn ([datetimeoffset] '2026-10-02T10:05:00Z')

        $result.Persisted | Should -BeTrue
        $script:request.Uri | Should -Be 'https://example.crm.dynamics.com/api/data/v9.2/custom_runs(11111111-1111-1111-1111-111111111111)'
        $script:request.Method | Should -Be 'PATCH'
        $script:request.Body.invs_phase | Should -Be 100000001
        $script:request.Body.invs_status | Should -Be 100000002
        $script:request.Body.invs_completedon | Should -Be '2026-10-02T10:05:00.0000000+00:00'
        $script:request.Body.invs_environmentstotal | Should -Be 3
        $script:request.Body.invs_environmentsfailed | Should -Be 1
        $script:request.Body.invs_found | Should -Be 8
        $script:request.Body.invs_created | Should -Be 4
        $script:request.Body.invs_errors | Should -Be 1
    }

    It 'writes a correlated Sync Log detail with its Sync Run lookup' {
        $script:request = $null
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $script:request = [pscustomobject] @{
                Uri = [string] $Uri
                Method = $Method
                Body = $Body
            }
            [pscustomobject] @{ StatusCode = 204; Headers = @{}; Body = $null }
        }

        $result = Write-InventorySyncLog -DataverseUrl 'https://example.crm.dynamics.com' `
            -AccessToken 'target-token' -TableName 'custom_logs' `
            -SyncRunTableName 'custom_runs' `
            -RunRecordId '11111111-1111-1111-1111-111111111111' `
            -CorrelationId 'correlation-id' -Severity Warning -Category Skipped `
            -EnvironmentId 'environment-1' -EnvironmentName 'Production' `
            -ComponentType 5 -ComponentId 'agent-1' -Operation Create `
            -HttpStatus 403 -ErrorCode '0x8004' -Message 'Full failure text' `
            -OccurredOn ([datetimeoffset] '2026-10-02T10:03:00Z') `
            -WarningAction SilentlyContinue

        $result.Persisted | Should -BeTrue
        $script:request.Uri | Should -Be 'https://example.crm.dynamics.com/api/data/v9.2/custom_logs'
        $script:request.Method | Should -Be 'POST'
        $script:request.Body.'invs_syncrunid@odata.bind' |
            Should -Be '/custom_runs(11111111-1111-1111-1111-111111111111)'
        $script:request.Body.invs_severity | Should -Be 100000000
        $script:request.Body.invs_category | Should -Be 100000009
        $script:request.Body.invs_environmentid | Should -Be 'environment-1'
        $script:request.Body.invs_environmentname | Should -Be 'Production'
        $script:request.Body.invs_componenttype | Should -Be 5
        $script:request.Body.invs_componentid | Should -Be 'agent-1'
        $script:request.Body.invs_operation | Should -Be 'Create'
        $script:request.Body.invs_httpstatus | Should -Be 403
        $script:request.Body.invs_errorcode | Should -Be '0x8004'
        $script:request.Body.invs_errormessage | Should -Be 'Full failure text'
        $script:request.Body.invs_occurredon | Should -Be '2026-10-02T10:03:00.0000000+00:00'
        $script:request.Body.invs_correlationid | Should -Be 'correlation-id'
    }

    It 'falls back to structured Application Insights telemetry when the log table is unavailable' {
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            throw 'HTTP 404: entity set was not found'
        }

        $result = Write-InventorySyncLog -DataverseUrl 'https://example.crm.dynamics.com' `
            -AccessToken 'target-token' -TableName 'missing_logs' `
            -SyncRunTableName 'missing_runs' `
            -RunRecordId '11111111-1111-1111-1111-111111111111' `
            -CorrelationId 'same-operation-id' -Severity Warning -Category Skipped `
            -ComponentId 'agent-1' -Operation Create -Message 'Agent was skipped' `
            -WarningVariable warnings -WarningAction SilentlyContinue

        $result.Persisted | Should -BeFalse
        $result.Error | Should -Match '404'
        $telemetry = @($warnings | ForEach-Object { $_.Message | ConvertFrom-Json })
        $telemetry[0].correlationId | Should -Be 'same-operation-id'
        $telemetry[0].data.category | Should -Be 'Skipped'
        $telemetry[-1].data.operation | Should -Be 'CreateSyncLog'
    }
}

Describe 'Agent sync logging lifecycle' {
    It 'records final counts and a correlated detail when an agent is skipped' {
        $script:requests = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            $script:requests.Add([pscustomobject] @{
                Uri = $uriText
                Method = $Method
                Body = $Body
            })
            if ($uriText -match 'Microsoft\.ResourceGraph/resources') {
                return [pscustomobject] @{
                    Body = [pscustomobject] @{
                        data = @(
                            [pscustomobject] @{
                                agentId = 'agent-1'; title = 'Agent one'
                                environmentId = 'environment-1'; ownerId = 'owner-1'
                                createdAt = '2026-09-01T08:00:00Z'
                                modifiedAt = '2026-09-02T09:00:00Z'
                            },
                            [pscustomobject] @{
                                agentId = 'agent-2'; title = 'Agent two'
                                environmentId = 'missing-environment'; ownerId = 'owner-2'
                                createdAt = '2026-09-01T08:00:00Z'
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
            return [pscustomobject] @{ StatusCode = 204; Headers = @{}; Body = $null }
        }
        $configuration = [pscustomobject] @{
            TargetDataverseUrl = 'https://example.crm.dynamics.com'
            AgentCreatedIn = 'Agent Builder'
            AgentSubscriptions = @()
            SyncRunTable = 'custom_runs'
            SyncLogTable = 'custom_logs'
        }

        $result = Invoke-AgentCreateSync -Configuration $configuration `
            -ResourceGraphAccessToken 'graph-token' -DataverseAccessToken 'target-token' `
            -Now ([datetimeoffset] '2026-10-02T10:00:00Z') `
            -CorrelationId '11111111-1111-1111-1111-111111111111' `
            -WarningAction SilentlyContinue

        $result.Status | Should -Be 'Partial'
        $result.Counts.Found | Should -Be 2
        $result.Counts.Created | Should -Be 1
        $result.Counts.Unchanged | Should -Be 0
        $result.Counts.Skipped | Should -Be 1
        $result.Counts.EnvironmentsTotal | Should -Be 2
        $result.Counts.EnvironmentsFailed | Should -Be 1
        $result.Counts.Errors | Should -Be 1
        $runCreates = @($script:requests | Where-Object {
            $_.Uri -match '/custom_runs$' -and $_.Method -eq 'POST'
        })
        $runUpdates = @($script:requests | Where-Object {
            $_.Uri -match '/custom_runs\([0-9a-f-]{36}\)$' -and $_.Method -eq 'PATCH'
        })
        $details = @($script:requests | Where-Object {
            $_.Uri -match '/custom_logs$' -and $_.Method -eq 'POST'
        })
        $runCreates | Should -HaveCount 1
        $runCreates[0].Body.invs_status | Should -Be 100000000
        $runUpdates | Should -HaveCount 1
        $runUpdates[0].Body.invs_status | Should -Be 100000002
        $runUpdates[0].Body.invs_found | Should -Be 2
        $runUpdates[0].Body.invs_created | Should -Be 1
        $runUpdates[0].Body.invs_errors | Should -Be 1
        $details | Should -HaveCount 1
        $details[0].Body.invs_category | Should -Be 100000009
        $details[0].Body.invs_componentid | Should -Be 'agent-2'
        $details[0].Body.invs_correlationid |
            Should -Be '11111111-1111-1111-1111-111111111111'
    }

    It 'records a write failure without abandoning the run lifecycle' {
        $script:requests = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            $script:requests.Add([pscustomobject] @{
                Uri = $uriText
                Method = $Method
                Body = $Body
            })
            if ($uriText -match 'Microsoft\.ResourceGraph/resources') {
                return [pscustomobject] @{
                    Body = [pscustomobject] @{
                        data = @([pscustomobject] @{
                            agentId = 'agent-1'; title = 'Agent one'
                            environmentId = 'environment-1'; ownerId = 'owner-1'
                            createdAt = '2026-09-01T08:00:00Z'
                            modifiedAt = '2026-09-02T09:00:00Z'
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
                return [pscustomobject] @{ Body = [pscustomobject] @{ value = @() } }
            }
            if ($uriText -match '/\$batch$') {
                throw 'HTTP 500: Dataverse batch failed'
            }
            return [pscustomobject] @{ StatusCode = 204; Headers = @{}; Body = $null }
        }
        $configuration = [pscustomobject] @{
            TargetDataverseUrl = 'https://example.crm.dynamics.com'
            AgentCreatedIn = 'Agent Builder'
            AgentSubscriptions = @()
            SyncRunTable = 'custom_runs'
            SyncLogTable = 'custom_logs'
        }

        $result = Invoke-AgentCreateSync -Configuration $configuration `
            -ResourceGraphAccessToken 'graph-token' -DataverseAccessToken 'target-token' `
            -CorrelationId '22222222-2222-2222-2222-222222222222' `
            -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

        $result.Status | Should -Be 'Partial'
        $result.Counts.Found | Should -Be 1
        $result.Counts.Created | Should -Be 0
        $result.Counts.Errors | Should -Be 1
        $result.Batch.Succeeded | Should -Be 0
        $result.Batch.Failed | Should -Be 1
        $details = @($script:requests | Where-Object {
            $_.Uri -match '/custom_logs$' -and $_.Method -eq 'POST'
        })
        $details | Should -HaveCount 1
        $details[0].Body.invs_category | Should -Be 100000004
        $details[0].Body.invs_componentid | Should -Be 'agent-1'
        $details[0].Body.invs_httpstatus | Should -Be 500
        $details[0].Body.invs_errormessage | Should -Match 'batch failed'
        $runUpdate = @($script:requests | Where-Object {
            $_.Uri -match '/custom_runs\([0-9a-f-]{36}\)$' -and $_.Method -eq 'PATCH'
        })
        $runUpdate[0].Body.invs_status | Should -Be 100000002
        $runUpdate[0].Body.invs_created | Should -Be 0
        $runUpdate[0].Body.invs_errors | Should -Be 1
    }

    It 'closes the run as failed and logs a read failure when collection aborts' {
        $script:requests = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            $script:requests.Add([pscustomobject] @{
                Uri = $uriText
                Method = $Method
                Body = $Body
            })
            if ($uriText -match 'Microsoft\.ResourceGraph/resources') {
                throw 'HTTP 403: Resource Graph denied'
            }
            return [pscustomobject] @{ StatusCode = 204; Headers = @{}; Body = $null }
        }
        $configuration = [pscustomobject] @{
            TargetDataverseUrl = 'https://example.crm.dynamics.com'
            AgentCreatedIn = 'Agent Builder'
            AgentSubscriptions = @()
            SyncRunTable = 'custom_runs'
            SyncLogTable = 'custom_logs'
        }

        {
            Invoke-AgentCreateSync -Configuration $configuration `
                -ResourceGraphAccessToken 'graph-token' -DataverseAccessToken 'target-token' `
                -CorrelationId '44444444-4444-4444-4444-444444444444' `
                -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        } | Should -Throw '*Resource Graph denied*'

        $detail = @($script:requests | Where-Object {
            $_.Uri -match '/custom_logs$' -and $_.Method -eq 'POST'
        })
        $runUpdate = @($script:requests | Where-Object {
            $_.Uri -match '/custom_runs\([0-9a-f-]{36}\)$' -and $_.Method -eq 'PATCH'
        })
        $detail | Should -HaveCount 1
        $detail[0].Body.invs_category | Should -Be 100000003
        $detail[0].Body.invs_errormessage | Should -Match 'Resource Graph denied'
        $runUpdate | Should -HaveCount 1
        $runUpdate[0].Body.invs_status | Should -Be 100000003
        $runUpdate[0].Body.invs_errors | Should -Be 1
    }

    It 'finishes the sync through Application Insights when the logging tables are missing' {
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            if ($uriText -match '/missing_runs(?:\(|$)' -or $uriText -match '/missing_logs$') {
                throw 'HTTP 404: logging entity set is missing'
            }
            if ($uriText -match 'Microsoft\.ResourceGraph/resources') {
                return [pscustomobject] @{
                    Body = [pscustomobject] @{
                        data = @([pscustomobject] @{
                            agentId = 'agent-1'; title = 'Agent one'
                            environmentId = 'environment-1'; ownerId = 'owner-1'
                            createdAt = '2026-09-01T08:00:00Z'
                            modifiedAt = '2026-09-02T09:00:00Z'
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
                return [pscustomobject] @{ Body = [pscustomobject] @{ value = @() } }
            }
            return [pscustomobject] @{ StatusCode = 204; Headers = @{}; Body = $null }
        }
        $configuration = [pscustomobject] @{
            TargetDataverseUrl = 'https://example.crm.dynamics.com'
            AgentCreatedIn = 'Agent Builder'
            AgentSubscriptions = @()
            SyncRunTable = 'missing_runs'
            SyncLogTable = 'missing_logs'
        }

        $result = Invoke-AgentCreateSync -Configuration $configuration `
            -ResourceGraphAccessToken 'graph-token' -DataverseAccessToken 'target-token' `
            -CorrelationId '55555555-5555-5555-5555-555555555555' `
            -WarningVariable warnings -WarningAction SilentlyContinue

        $result.Status | Should -Be 'Succeeded'
        $result.Counts.Created | Should -Be 1
        $telemetry = @($warnings | ForEach-Object { $_.Message | ConvertFrom-Json })
        $telemetry[0].correlationId |
            Should -Be '55555555-5555-5555-5555-555555555555'
        $telemetry[0].data.operation | Should -Be 'CreateSyncRun'
        Should -Invoke Invoke-InventoryHttpRequest -ModuleName InventorySync `
            -ParameterFilter { [string] $Uri -match '/\$batch$' } -Times 1 -Exactly
    }
}

Describe 'Skipped Agent singleton logging' {
    It 'records a RunSkipped detail and closes the skipped run as partial' {
        $script:requests = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $script:requests.Add([pscustomobject] @{
                Uri = [string] $Uri
                Method = $Method
                Body = $Body
            })
            [pscustomobject] @{ StatusCode = 204; Headers = @{}; Body = $null }
        }
        $configuration = [pscustomobject] @{
            TargetDataverseUrl = 'https://example.crm.dynamics.com'
            SyncRunTable = 'custom_runs'
            SyncLogTable = 'custom_logs'
        }

        $result = Write-AgentSyncSkippedRun -Configuration $configuration `
            -DataverseAccessToken 'target-token' `
            -CorrelationId '33333333-3333-3333-3333-333333333333' `
            -InstanceId 'agent-builder-inventory-sync' -RuntimeStatus Running `
            -Now ([datetimeoffset] '2026-10-02T10:00:00Z') `
            -WarningAction SilentlyContinue

        $result.Status | Should -Be 'Partial'
        $result.Counts.Errors | Should -Be 1
        $runCreate = @($script:requests | Where-Object {
            $_.Uri -match '/custom_runs$' -and $_.Method -eq 'POST'
        })
        $detail = @($script:requests | Where-Object {
            $_.Uri -match '/custom_logs$' -and $_.Method -eq 'POST'
        })
        $runUpdate = @($script:requests | Where-Object {
            $_.Uri -match '/custom_runs\([0-9a-f-]{36}\)$' -and $_.Method -eq 'PATCH'
        })
        $runCreate | Should -HaveCount 1
        $detail | Should -HaveCount 1
        $detail[0].Body.invs_category | Should -Be 100000007
        $detail[0].Body.invs_operation | Should -Be 'Start'
        $detail[0].Body.invs_correlationid |
            Should -Be '33333333-3333-3333-3333-333333333333'
        $runUpdate | Should -HaveCount 1
        $runUpdate[0].Body.invs_status | Should -Be 100000002
        $runUpdate[0].Body.invs_errors | Should -Be 1
    }
}
