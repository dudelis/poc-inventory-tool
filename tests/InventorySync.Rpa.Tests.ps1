BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\Modules\InventorySync\InventorySync.psd1'
    Import-Module $modulePath -Force
}

Describe 'RPA environment selection' {
    It 'selects only active environments with a URL and logs every excluded environment' {
        $environments = @(
            [pscustomobject] @{ palp_id = 'prod'; palp_name = 'Production'; palp_sku = 'Production'; statecode = 0; palp_dataverseurl = 'https://prod.crm.dynamics.com' }
            [pscustomobject] @{ palp_id = 'default'; palp_name = 'Default'; palp_sku = 'Standard'; statecode = 0; palp_dataverseurl = 'https://default.crm.dynamics.com' }
            [pscustomobject] @{ palp_id = 'teams'; palp_name = 'Teams'; palp_sku = 'Teams'; statecode = 0; palp_dataverseurl = 'https://teams.crm.dynamics.com' }
            [pscustomobject] @{ palp_id = 'deleted'; palp_name = 'Deleted'; palp_sku = 'Production'; statecode = 1; palp_dataverseurl = 'https://deleted.crm.dynamics.com' }
            [pscustomobject] @{ palp_id = 'removed'; palp_name = 'Removed'; palp_sku = 'Production'; statecode = 0; palp_removed = $true; palp_dataverseurl = 'https://removed.crm.dynamics.com' }
            [pscustomobject] @{ palp_id = 'no-url'; palp_name = 'No URL'; palp_sku = 'Production'; statecode = 0; palp_dataverseurl = $null }
        )

        $plan = Get-RpaEnvironmentPlan -Environments $environments `
            -UrlColumn 'palp_dataverseurl' -ExcludedSkus @('Standard', 'Teams')

        $plan.Environments.palp_id | Should -Be @('prod')
        $plan.Logs | Should -HaveCount 5
        ($plan.Logs | Where-Object EnvironmentId -eq 'no-url').Message |
            Should -Match 'Dataverse URL'
    }

    It 'uses the documented RPA defaults and validates maximum parallelism' {
        $settings = @{
            INVENTORY_TENANT_ID                   = 'tenant-id'
            INVENTORY_CLIENT_ID                   = 'client-id'
            INVENTORY_CLIENT_SECRET               = 'secret'
            INVENTORY_TARGET_DATAVERSE_URL        = 'https://target.crm.dynamics.com'
            INVENTORY_AGENT_CREATED_IN            = 'Agent Builder'
            APPLICATIONINSIGHTS_CONNECTION_STRING = 'InstrumentationKey=test'
        }

        $configuration = Get-InventorySyncConfiguration -Settings $settings

        $configuration.RpaEnvironmentUrlColumn | Should -Be 'palp_dataverseurl'
        $configuration.RpaExcludedSkus | Should -Be @('Standard', 'Teams')
        $configuration.RpaMaxParallelEnvironments | Should -Be 10

        $settings.INVENTORY_RPA_MAX_PARALLEL_ENVIRONMENTS = '0'
        { Get-InventorySyncConfiguration -Settings $settings } |
            Should -Throw '*positive integer*'
    }
}

Describe 'Desktop flow collection' {
    It 'pages all desktop-flow workflows and resolves user and team Entra owners' {
        $script:uris = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            $script:uris.Add($uriText)
            if ($uriText -match 'workflows\?page=2') {
                return [pscustomobject] @{ Body = [pscustomobject] @{ value = @(
                    [pscustomobject] @{
                        workflowid = 'flow-team'; name = 'Team flow'; description = 'Two'
                        createdon = '2026-09-03T08:00:00Z'; modifiedon = '2026-09-04T09:00:00Z'
                        _ownerid_value = 'team-1'
                        '_ownerid_value@Microsoft.Dynamics.CRM.lookuplogicalname' = 'team'
                    },
                    [pscustomobject] @{
                        workflowid = 'flow-orphan'; name = 'Orphan'; _ownerid_value = 'missing'
                        '_ownerid_value@Microsoft.Dynamics.CRM.lookuplogicalname' = 'systemuser'
                    }
                ) }}
            }
            if ($uriText -match '/workflows\?') {
                return [pscustomobject] @{ Body = [pscustomobject] @{
                    value = @([pscustomobject] @{
                        workflowid = 'flow-user'; name = 'User flow'; description = 'One'
                        createdon = '2026-09-01T08:00:00Z'; modifiedon = '2026-09-02T09:00:00Z'
                        _ownerid_value = 'user-1'
                        '_ownerid_value@Microsoft.Dynamics.CRM.lookuplogicalname' = 'systemuser'
                    })
                    '@odata.nextLink' = 'https://source.crm.dynamics.com/api/data/v9.2/workflows?page=2'
                }}
            }
            if ($uriText -match '/systemusers\(user-1\)') {
                return [pscustomobject] @{ Body = [pscustomobject] @{ azureactivedirectoryobjectid = 'entra-user' } }
            }
            if ($uriText -match '/teams\(team-1\)') {
                return [pscustomobject] @{ Body = [pscustomobject] @{ azureactivedirectoryobjectid = 'entra-team' } }
            }
            if ($uriText -match '/systemusers\(missing\)') {
                return [pscustomobject] @{ Body = [pscustomobject] @{ azureactivedirectoryobjectid = $null } }
            }
            throw "Unexpected request: $uriText"
        }

        $result = Get-RpaDesktopFlows -Environment ([pscustomobject] @{
            palp_id = 'environment-1'; palp_name = 'Production'
            DataverseUrl = 'https://source.crm.dynamics.com'
        }) -AccessToken 'source-token'

        $result.Flows | Should -HaveCount 2
        $result.Found | Should -Be 3
        $result.Flows.OwnerObjectId | Should -Be @('entra-user', 'entra-team')
        $result.Logs | Should -HaveCount 1
        $result.Logs[0].ComponentId | Should -Be 'flow-orphan'
        $script:uris[0] | Should -Match 'category eq 6'
        $script:uris | Where-Object { $_ -match '/workflows' } | Should -HaveCount 2
    }
}

Describe 'RPA fan-out and reconciliation' {
    It 'returns successes and categorized failures without exceeding the configured bound' {
        $collector = {
            param($environment, $configuration)
            $started = [datetimeoffset]::UtcNow
            Start-Sleep -Milliseconds 150
            if ($environment.palp_id -eq 'bad') {
                throw 'HTTP 403: full permission failure'
            }
            [pscustomobject] @{
                Flows = @([pscustomobject] @{
                    SourceId = "flow-$($environment.palp_id)"
                    Started = $started
                    Completed = [datetimeoffset]::UtcNow
                })
                Logs = @()
            }
        }

        $environments = @(
            [pscustomobject] @{ palp_id = 'one'; palp_name = 'One'; DataverseUrl = 'https://one.example' }
            [pscustomobject] @{ palp_id = 'two'; palp_name = 'Two'; DataverseUrl = 'https://two.example' }
            [pscustomobject] @{ palp_id = 'three'; palp_name = 'Three'; DataverseUrl = 'https://three.example' }
            [pscustomobject] @{ palp_id = 'bad'; palp_name = 'Bad'; DataverseUrl = 'https://bad.example' }
        )

        $result = Invoke-RpaEnvironmentFanOut -Environments $environments `
            -Configuration ([pscustomobject] @{}) `
            -MaxParallel 2 -CollectionAction $collector

        $result.SuccessfulEnvironmentIds | Sort-Object | Should -Be @('one', 'three', 'two')
        $result.Flows.SourceId | Sort-Object | Should -Be @('flow-one', 'flow-three', 'flow-two')
        $result.Failures | Should -HaveCount 1
        $result.Failures[0].Category | Should -Be 'PermissionDenied'
        $result.Failures[0].Message | Should -Be 'HTTP 403: full permission failure'
        $maximumOverlap = @(
            foreach ($flow in $result.Flows) {
                @($result.Flows | Where-Object {
                    $_.Started -le $flow.Started -and $_.Completed -gt $flow.Started
                }).Count
            }
        ) | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
        $maximumOverlap | Should -BeLessOrEqual 2
        $maximumOverlap | Should -BeGreaterThan 1
    }

    It 'creates and updates only type 4 rows and marks an environment failure Partial' {
        $existingId = New-InventoryComponentId -EnvironmentId 'good' -ComponentType 4 -SourceId 'updated'
        $script:requests = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            $script:requests.Add([pscustomobject] @{ Uri = $uriText; Method = $Method; Body = $Body })
            if ($uriText -match '/palp_environments\?') {
                return [pscustomobject] @{ Body = [pscustomobject] @{ value = @(
                    [pscustomobject] @{ palp_id = 'good'; palp_name = 'Good'; palp_sku = 'Production'; statecode = 0; palp_dataverseurl = 'https://good.crm.dynamics.com' }
                    [pscustomobject] @{ palp_id = 'bad'; palp_name = 'Bad'; palp_sku = 'Production'; statecode = 0; palp_dataverseurl = 'https://bad.crm.dynamics.com' }
                ) }}
            }
            if ($uriText -match '/palp_komponentes\?') {
                return [pscustomobject] @{ Body = [pscustomobject] @{ value = @(
                    [pscustomobject] @{
                        palp_id = $existingId; palp_typ = 4; palp_titel = 'Old'
                        palp_besitzerobjectid = 'entra-owner'; palp_beschreibung = 'Description'
                        palp_environment = [pscustomobject] @{ palp_id = 'good' }
                        palp_urspruenglicherstelltam = '2026-09-01T08:00:00Z'
                        palp_urspruenglichgeaendertam = '2026-09-02T09:00:00Z'
                    }
                ) }}
            }
            if ($uriText -match '/\$batch$') {
                return [pscustomobject] @{ StatusCode = 200; Body = $null }
            }
            throw "Unexpected request: $uriText"
        }
        $collector = {
            param($environment, $configuration)
            if ($environment.palp_id -eq 'bad') { throw 'HTTP 504: source timed out after retries' }
            [pscustomobject] @{
                Flows = @(
                    [pscustomobject] @{
                        SourceId = 'updated'; EnvironmentId = 'good'; Title = 'Current'
                        OwnerObjectId = 'entra-owner'; Description = 'Description'
                        SourceCreatedAt = '2026-09-01T08:00:00Z'
                        SourceModifiedAt = '2026-09-02T09:00:00Z'
                    },
                    [pscustomobject] @{
                        SourceId = 'created'; EnvironmentId = 'good'; Title = 'New'
                        OwnerObjectId = 'entra-owner'; Description = $null
                        SourceCreatedAt = '2026-09-03T08:00:00Z'
                        SourceModifiedAt = '2026-09-04T09:00:00Z'
                    }
                )
                Logs = @()
            }
        }

        $configuration = [pscustomobject] @{
            TargetDataverseUrl = 'https://target.crm.dynamics.com'
            RpaEnvironmentUrlColumn = 'palp_dataverseurl'
            RpaExcludedSkus = @('Standard', 'Teams')
            RpaMaxParallelEnvironments = 2
            MaxCreatesPerRun = 10
        }

        $result = Invoke-RpaSync -Configuration $configuration `
            -DataverseAccessToken 'target-token' -EnvironmentCollector $collector

        $result.Status | Should -Be 'Partial'
        $result.Counts.EnvironmentsTotal | Should -Be 2
        $result.Counts.EnvironmentsFailed | Should -Be 1
        $result.Counts.Created | Should -Be 1
        $result.Counts.Updated | Should -Be 1
        $result.Logs.Message | Should -Contain 'HTTP 504: source timed out after retries'
        $componentRead = $script:requests | Where-Object Uri -match '/palp_komponentes\?'
        $componentRead.Uri | Should -Match 'palp_typ eq 4'
        $batch = $script:requests | Where-Object Uri -match '/\$batch$'
        $batch.Body | Should -Match '"palp_typ":4'
        $batch.Body | Should -Match "PATCH palp_komponentes\(palp_id='$existingId'\)"
        $script:requests.Uri | Should -Not -Match 'palp_environments\('
    }

    It 'persists the RPA Sync Run and full environment failure Sync Log lifecycle' {
        $script:requests = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            $script:requests.Add([pscustomobject] @{ Uri = $uriText; Method = $Method; Body = $Body })
            if ($uriText -match '/palp_environments\?') {
                return [pscustomobject] @{ Body = [pscustomobject] @{ value = @(
                    [pscustomobject] @{
                        palp_id = 'bad'; palp_name = 'Bad'; palp_sku = 'Production'
                        statecode = 0; palp_dataverseurl = 'https://bad.crm.dynamics.com'
                    }
                ) }}
            }
            if ($uriText -match '/palp_komponentes\?') {
                return [pscustomobject] @{ Body = [pscustomobject] @{ value = @() } }
            }
            if ($uriText -match '/custom_runs|/custom_logs') {
                return [pscustomobject] @{ StatusCode = 204; Body = $null }
            }
            throw "Unexpected request: $uriText"
        }
        $collector = {
            param($environment, $configuration)
            throw 'HTTP 403: complete permission failure detail'
        }
        $configuration = [pscustomobject] @{
            TargetDataverseUrl = 'https://target.crm.dynamics.com'
            RpaEnvironmentUrlColumn = 'palp_dataverseurl'
            RpaExcludedSkus = @('Standard', 'Teams')
            RpaMaxParallelEnvironments = 1
            MaxCreatesPerRun = 10
            SyncRunTable = 'custom_runs'
            SyncLogTable = 'custom_logs'
        }

        $result = Invoke-RpaSync -Configuration $configuration `
            -DataverseAccessToken 'target-token' -EnvironmentCollector $collector `
            -CorrelationId 'rpa-correlation'

        $result.Status | Should -Be 'Partial'
        $runCreate = $script:requests | Where-Object {
            $_.Uri -match '/custom_runs$' -and $_.Method -eq 'POST'
        }
        $runComplete = $script:requests | Where-Object {
            $_.Uri -match '/custom_runs\(' -and $_.Method -eq 'PATCH'
        }
        $detail = $script:requests | Where-Object { $_.Uri -match '/custom_logs$' }
        $runCreate.Body.invs_synctype | Should -Be 100000000
        $runComplete.Body.invs_status | Should -Be 100000002
        $runComplete.Body.invs_phase | Should -Be 100000002
        $runComplete.Body.invs_environmentsfailed | Should -Be 1
        $detail.Body.invs_category | Should -Be 100000001
        $detail.Body.invs_errormessage | Should -Be 'HTTP 403: complete permission failure detail'
        $detail.Body.invs_correlationid | Should -Be 'rpa-correlation'
    }
}

Describe 'RPA deletion check' {
    BeforeEach {
        Clear-InventoryTokenCache
    }

    It 'checks and deletes only missing desktop flows from environments read successfully' {
        $missingId = '11111111-1111-1111-1111-111111111111'
        $existingSourceId = 'existing-flow'
        $existingId = New-InventoryComponentId -EnvironmentId 'good' `
            -ComponentType 4 -SourceId $existingSourceId
        $failedEnvironmentId = '33333333-3333-3333-3333-333333333333'
        $skippedEnvironmentId = '44444444-4444-4444-4444-444444444444'
        $script:sourceChecks = [System.Collections.Generic.List[string]]::new()
        $script:batchBody = $null
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            if ($uriText -match 'login\.microsoftonline\.com') {
                return [pscustomobject] @{ Body = [pscustomobject] @{
                    access_token = 'source-token'; expires_in = 3600
                } }
            }
            if ($uriText -match '/palp_environments\?') {
                return [pscustomobject] @{ Body = [pscustomobject] @{ value = @(
                    [pscustomobject] @{
                        palp_id = 'good'; palp_name = 'Good'; palp_sku = 'Production'
                        statecode = 0; palp_dataverseurl = 'https://good.crm.dynamics.com'
                    },
                    [pscustomobject] @{
                        palp_id = 'bad'; palp_name = 'Bad'; palp_sku = 'Production'
                        statecode = 0; palp_dataverseurl = 'https://bad.crm.dynamics.com'
                    },
                    [pscustomobject] @{
                        palp_id = 'skipped'; palp_name = 'Skipped'; palp_sku = 'Standard'
                        statecode = 0; palp_dataverseurl = 'https://skipped.crm.dynamics.com'
                    }
                ) } }
            }
            if ($uriText -match '/palp_komponentes\?') {
                return [pscustomobject] @{ Body = [pscustomobject] @{ value = @(
                    [pscustomobject] @{
                        palp_id = $missingId; palp_typ = 4
                        palp_environment = [pscustomobject] @{ palp_id = 'good' }
                        palp_komponentenstatus = 0; palp_status = 0
                    },
                    [pscustomobject] @{
                        palp_id = $existingId; palp_typ = 4
                        palp_environment = [pscustomobject] @{ palp_id = 'good' }
                        palp_komponentenstatus = 0; palp_status = 0
                    },
                    [pscustomobject] @{
                        palp_id = $failedEnvironmentId; palp_typ = 4
                        palp_environment = [pscustomobject] @{ palp_id = 'bad' }
                        palp_komponentenstatus = 0; palp_status = 0
                    },
                    [pscustomobject] @{
                        palp_id = $skippedEnvironmentId; palp_typ = 4
                        palp_environment = [pscustomobject] @{ palp_id = 'skipped' }
                        palp_komponentenstatus = 0; palp_status = 0
                    }
                ) } }
            }
            if ($uriText -match 'https://good\.crm\.dynamics\.com/.*/workflows\?') {
                $script:sourceChecks.Add($uriText)
                $value = @([pscustomobject] @{ workflowid = $existingSourceId })
                return [pscustomobject] @{ Body = [pscustomobject] @{ value = $value } }
            }
            if ($uriText -match '/\$batch$') {
                $script:batchBody = [string] $Body
                return [pscustomobject] @{ StatusCode = 200; Body = $null }
            }
            throw "Unexpected request: $uriText"
        }
        $collector = {
            param($environment, $configuration)
            if ($environment.palp_id -eq 'bad') {
                throw 'HTTP 403: source environment cannot be read'
            }
            [pscustomobject] @{ Flows = @(); Logs = @(); Found = 0 }
        }
        $configuration = [pscustomobject] @{
            TenantId = 'tenant'; ClientId = 'client'; ClientSecret = 'secret'
            TargetDataverseUrl = 'https://target.crm.dynamics.com'
            RpaEnvironmentUrlColumn = 'palp_dataverseurl'
            RpaExcludedSkus = @('Standard', 'Teams')
            RpaMaxParallelEnvironments = 2
            MaxCreatesPerRun = 10
        }

        $result = Invoke-RpaSync -Configuration $configuration `
            -DataverseAccessToken 'target-token' -EnvironmentCollector $collector `
            -Now ([datetimeoffset] '2026-10-02T10:00:00Z')

        $result.Status | Should -Be 'Partial'
        $result.Counts.MarkedDeleted | Should -Be 1
        $script:sourceChecks | Should -HaveCount 1
        $script:sourceChecks -join '|' | Should -Not -Match 'bad\.crm'
        $script:sourceChecks -join '|' | Should -Not -Match 'skipped\.crm'
        $script:sourceChecks -join '|' | Should -Match 'category( |%20|\+)eq( |%20|\+)6'
        $script:sourceChecks -join '|' | Should -Not -Match ([regex]::Escape($missingId))
        $script:sourceChecks -join '|' | Should -Not -Match ([regex]::Escape($existingId))
        $script:batchBody | Should -Match "PATCH palp_komponentes\(palp_id='$missingId'\)"
        $script:batchBody | Should -Match '"palp_komponentenstatus":7'
        $script:batchBody | Should -Match '"palp_status":1'
        $script:batchBody | Should -Match '"palp_letztestatusaenderung":"2026-10-02T10:00:00'
        $script:batchBody | Should -Not -Match ([regex]::Escape($existingId))
        $script:batchBody | Should -Not -Match ([regex]::Escape($failedEnvironmentId))
        $script:batchBody | Should -Not -Match ([regex]::Escape($skippedEnvironmentId))
    }

    It 'marks nothing and logs VerifyFailed when a targeted workflow re-check fails' {
        $firstId = '11111111-1111-1111-1111-111111111111'
        $secondId = '22222222-2222-2222-2222-222222222222'
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            if ($uriText -match 'login\.microsoftonline\.com') {
                return [pscustomobject] @{ Body = [pscustomobject] @{
                    access_token = 'source-token'; expires_in = 3600
                } }
            }
            if ($uriText -match '/palp_environments\?') {
                return [pscustomobject] @{ Body = [pscustomobject] @{ value = @(
                    [pscustomobject] @{
                        palp_id = 'good'; palp_name = 'Good'; palp_sku = 'Production'
                        statecode = 0; palp_dataverseurl = 'https://good.crm.dynamics.com'
                    }
                ) } }
            }
            if ($uriText -match '/palp_komponentes\?') {
                return [pscustomobject] @{ Body = [pscustomobject] @{ value = @(
                    [pscustomobject] @{
                        palp_id = $firstId; palp_typ = 4
                        palp_environment = [pscustomobject] @{ palp_id = 'good' }
                        palp_komponentenstatus = 0; palp_status = 0
                    },
                    [pscustomobject] @{
                        palp_id = $secondId; palp_typ = 4
                        palp_environment = [pscustomobject] @{ palp_id = 'good' }
                        palp_komponentenstatus = 0; palp_status = 0
                    }
                ) } }
            }
            if ($uriText -match '/workflows\?') {
                throw 'HTTP 503: targeted workflow check failed'
            }
            if ($uriText -match '/\$batch$') {
                throw 'Deletion writes must not be sent after a failed re-check.'
            }
            throw "Unexpected request: $uriText"
        }
        $collector = {
            param($environment, $configuration)
            [pscustomobject] @{ Flows = @(); Logs = @(); Found = 0 }
        }
        $configuration = [pscustomobject] @{
            TenantId = 'tenant'; ClientId = 'client'; ClientSecret = 'secret'
            TargetDataverseUrl = 'https://target.crm.dynamics.com'
            RpaEnvironmentUrlColumn = 'palp_dataverseurl'
            RpaExcludedSkus = @('Standard', 'Teams')
            RpaMaxParallelEnvironments = 1
            MaxCreatesPerRun = 10
        }

        $result = Invoke-RpaSync -Configuration $configuration `
            -DataverseAccessToken 'target-token' -EnvironmentCollector $collector `
            -Now ([datetimeoffset] '2026-10-02T10:00:00Z') -ErrorAction SilentlyContinue

        $result.Status | Should -Be 'Partial'
        $result.Counts.MarkedDeleted | Should -Be 0
        $result.Counts.Errors | Should -Be 1
        $result.Batch.Operations | Should -Be 0
        $result.Logs | Should -HaveCount 1
        $result.Logs[0].Category | Should -Be 'VerifyFailed'
        $result.Logs[0].Message | Should -Match 'targeted workflow check failed'
        Should -Invoke Invoke-InventoryHttpRequest -ModuleName InventorySync `
            -ParameterFilter { [string] $Uri -match '/\$batch$' } -Times 0 -Exactly
    }

    It 'restores a collected deleted desktop flow and records the restore' {
        $componentId = New-InventoryComponentId -EnvironmentId 'good' `
            -ComponentType 4 -SourceId 'restored-flow'
        $script:batchBody = $null
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            if ($uriText -match '/palp_environments\?') {
                return [pscustomobject] @{ Body = [pscustomobject] @{ value = @(
                    [pscustomobject] @{
                        palp_id = 'good'; palp_name = 'Good'; palp_sku = 'Production'
                        statecode = 0; palp_dataverseurl = 'https://good.crm.dynamics.com'
                    }
                ) } }
            }
            if ($uriText -match '/palp_komponentes\?') {
                return [pscustomobject] @{ Body = [pscustomobject] @{ value = @(
                    [pscustomobject] @{
                        palp_id = $componentId; palp_typ = 4; palp_titel = 'Restored'
                        palp_besitzerobjectid = 'owner'; palp_beschreibung = 'Description'
                        palp_environment = [pscustomobject] @{ palp_id = 'good' }
                        palp_urspruenglicherstelltam = '2026-09-01T08:00:00Z'
                        palp_urspruenglichgeaendertam = '2026-09-02T09:00:00Z'
                        palp_komponentenstatus = 7; palp_status = 1
                    }
                ) } }
            }
            if ($uriText -match '/\$batch$') {
                $script:batchBody = [string] $Body
                return [pscustomobject] @{ StatusCode = 200; Body = $null }
            }
            throw "Unexpected request: $uriText"
        }
        $collector = {
            param($environment, $configuration)
            [pscustomobject] @{
                Flows = @([pscustomobject] @{
                    SourceId = 'restored-flow'; EnvironmentId = 'good'; Title = 'Restored'
                    OwnerObjectId = 'owner'; Description = 'Description'
                    SourceCreatedAt = '2026-09-01T08:00:00Z'
                    SourceModifiedAt = '2026-09-02T09:00:00Z'
                })
                Logs = @()
                Found = 1
            }
        }
        $configuration = [pscustomobject] @{
            TargetDataverseUrl = 'https://target.crm.dynamics.com'
            RpaEnvironmentUrlColumn = 'palp_dataverseurl'
            RpaExcludedSkus = @('Standard', 'Teams')
            RpaMaxParallelEnvironments = 1
            MaxCreatesPerRun = 10
        }

        $result = Invoke-RpaSync -Configuration $configuration `
            -DataverseAccessToken 'target-token' -EnvironmentCollector $collector `
            -Now ([datetimeoffset] '2026-10-02T10:00:00Z') `
            -WarningAction SilentlyContinue

        $result.Status | Should -Be 'Succeeded'
        $result.Counts.Restored | Should -Be 1
        $result.Counts.Updated | Should -Be 0
        $result.Logs | Should -HaveCount 1
        $result.Logs[0].Category | Should -Be 'Restored'
        $result.Logs[0].ComponentId | Should -Be 'restored-flow'
        $script:batchBody | Should -Match "PATCH palp_komponentes\(palp_id='$componentId'\)"
        $script:batchBody | Should -Match '"palp_komponentenstatus":0'
        $script:batchBody | Should -Match '"palp_status":0'
        $script:batchBody | Should -Match '"palp_letztestatusaenderung":"2026-10-02T10:00:00'
        Should -Invoke Invoke-InventoryHttpRequest -ModuleName InventorySync `
            -ParameterFilter { [string] $Uri -match '/workflows\?' } -Times 0 -Exactly
    }
}
