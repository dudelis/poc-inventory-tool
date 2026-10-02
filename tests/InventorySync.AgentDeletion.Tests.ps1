BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\Modules\InventorySync\InventorySync.psd1'
    Import-Module $modulePath -Force
}

Describe 'Agent Builder deletion check' {
    It 'marks only active collected-set differences that Resource Graph confirms missing' {
        $collectedId = New-InventoryComponentId -EnvironmentId 'environment-1' `
            -ComponentType 5 -SourceId 'collected-agent'
        $missingId = '11111111-1111-1111-1111-111111111111'
        $stillExistingId = '22222222-2222-2222-2222-222222222222'
        $inactiveId = '33333333-3333-3333-3333-333333333333'
        $script:verificationQueries = [System.Collections.Generic.List[string]]::new()
        $script:batchBodies = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            if ($uriText -match 'Microsoft\.ResourceGraph/resources') {
                $query = [string] $Body.query
                if ($query -match 'properties\.createdIn') {
                    return [pscustomobject] @{
                        Body = [pscustomobject] @{
                            data = @([pscustomobject] @{
                                agentId = 'collected-agent'; title = 'Collected'
                                description = ''; environmentId = 'environment-1'
                                ownerId = 'owner-1'; createdAt = '2026-09-01T08:00:00Z'
                                modifiedAt = '2026-09-02T09:00:00Z'
                            })
                        }
                    }
                }

                $script:verificationQueries.Add($query)
                $data = if ($query -match [regex]::Escape($stillExistingId)) {
                    @([pscustomobject] @{ agentId = $stillExistingId })
                }
                else {
                    @()
                }
                return [pscustomobject] @{ Body = [pscustomobject] @{ data = $data } }
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
                    Body = [pscustomobject] @{
                        value = @(
                            [pscustomobject] @{
                                palp_id = $collectedId; palp_typ = 5; palp_titel = 'Collected'
                                palp_besitzerobjectid = 'owner-1'; palp_beschreibung = ''
                                palp_environment = [pscustomobject] @{ palp_id = 'environment-1' }
                                palp_urspruenglicherstelltam = '2026-09-01T08:00:00Z'
                                palp_urspruenglichgeaendertam = '2026-09-02T09:00:00Z'
                                palp_komponentenstatus = 0; palp_status = 0
                            },
                            [pscustomobject] @{
                                palp_id = $missingId; palp_typ = 5
                                palp_environment = [pscustomobject] @{ palp_id = 'environment-1' }
                                palp_komponentenstatus = 0; palp_status = 0
                            },
                            [pscustomobject] @{
                                palp_id = $stillExistingId; palp_typ = 5
                                palp_environment = [pscustomobject] @{ palp_id = 'environment-1' }
                                palp_komponentenstatus = 0; palp_status = 0
                            },
                            [pscustomobject] @{
                                palp_id = $inactiveId; palp_typ = 5
                                palp_environment = [pscustomobject] @{ palp_id = 'environment-1' }
                                palp_komponentenstatus = 7; palp_status = 1
                            }
                        )
                    }
                }
            }
            if ($uriText -match '/\$batch$') {
                $script:batchBodies.Add([string] $Body)
                return [pscustomobject] @{ StatusCode = 200; Body = $null }
            }
            throw "Unexpected request: $uriText"
        }
        $configuration = [pscustomobject] @{
            TargetDataverseUrl = 'https://example.crm.dynamics.com'
            AgentCreatedIn = 'Agent Builder'
            AgentSubscriptions = @()
            MaxCreatesPerRun = 10
        }

        $result = Invoke-AgentSync -Configuration $configuration `
            -ResourceGraphAccessToken 'graph-token' -DataverseAccessToken 'target-token' `
            -Now ([datetimeoffset] '2026-10-02T10:00:00Z')

        $result.Status | Should -Be 'Succeeded'
        $result.Counts.MarkedDeleted | Should -Be 1
        $script:verificationQueries | Should -HaveCount 2
        $script:verificationQueries -join '|' | Should -Not -Match 'createdIn'
        $script:verificationQueries -join '|' | Should -Not -Match ([regex]::Escape($inactiveId))
        $script:batchBodies | Should -HaveCount 1
        $script:batchBodies[0] | Should -Match "PATCH palp_komponentes\(palp_id='$missingId'\)"
        $script:batchBodies[0] | Should -Match '"palp_komponentenstatus":7'
        $script:batchBodies[0] | Should -Match '"palp_status":1'
        $script:batchBodies[0] | Should -Match '"palp_letztestatusaenderung":"2026-10-02T10:00:00'
        $script:batchBodies[0] | Should -Not -Match ([regex]::Escape($stillExistingId))
        $script:batchBodies[0] | Should -Not -Match 'DELETE '
    }

    It 'restores a collected deleted row and records it in the result' {
        $componentId = New-InventoryComponentId -EnvironmentId 'environment-1' `
            -ComponentType 5 -SourceId 'restored-agent'
        $script:batchBody = $null
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            if ($uriText -match 'Microsoft\.ResourceGraph/resources') {
                return [pscustomobject] @{
                    Body = [pscustomobject] @{
                        data = @([pscustomobject] @{
                            agentId = 'restored-agent'; title = 'Restored'
                            description = ''; environmentId = 'environment-1'
                            ownerId = 'owner-1'; createdAt = '2026-09-01T08:00:00Z'
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
                return [pscustomobject] @{
                    Body = [pscustomobject] @{
                        value = @([pscustomobject] @{
                            palp_id = $componentId; palp_typ = 5; palp_titel = 'Restored'
                            palp_besitzerobjectid = 'owner-1'; palp_beschreibung = ''
                            palp_environment = [pscustomobject] @{ palp_id = 'environment-1' }
                            palp_urspruenglicherstelltam = '2026-09-01T08:00:00Z'
                            palp_urspruenglichgeaendertam = '2026-09-02T09:00:00Z'
                            palp_komponentenstatus = 7; palp_status = 1
                        })
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
            AgentCreatedIn = 'Agent Builder'
            AgentSubscriptions = @()
            MaxCreatesPerRun = 10
        }

        $result = Invoke-AgentSync -Configuration $configuration `
            -ResourceGraphAccessToken 'graph-token' -DataverseAccessToken 'target-token' `
            -Now ([datetimeoffset] '2026-10-02T10:00:00Z') `
            -WarningAction SilentlyContinue

        $result.Status | Should -Be 'Succeeded'
        $result.Counts.Restored | Should -Be 1
        $result.Counts.EnvironmentsFailed | Should -Be 0
        $result.Counts.Updated | Should -Be 0
        $result.Logs | Should -HaveCount 1
        $result.Logs[0].Category | Should -Be 'Restored'
        $result.Logs[0].ComponentId | Should -Be 'restored-agent'
        $script:batchBody | Should -Match "PATCH palp_komponentes\(palp_id='$componentId'\)"
        $script:batchBody | Should -Match '"palp_komponentenstatus":0'
        $script:batchBody | Should -Match '"palp_status":0'
        $script:batchBody | Should -Match '"palp_letztestatusaenderung":"2026-10-02T10:00:00'
    }

    It 'marks nothing and logs VerifyFailed when any targeted recheck fails' {
        $firstId = '11111111-1111-1111-1111-111111111111'
        $secondId = '22222222-2222-2222-2222-222222222222'
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            if ($uriText -match 'Microsoft\.ResourceGraph/resources') {
                $query = [string] $Body.query
                if ($query -match 'properties\.createdIn') {
                    return [pscustomobject] @{
                        Body = [pscustomobject] @{ data = @() }
                    }
                }
                if ($query -match [regex]::Escape($secondId)) {
                    throw 'HTTP 503: targeted Resource Graph check failed'
                }
                return [pscustomobject] @{
                    Body = [pscustomobject] @{ data = @() }
                }
            }
            if ($uriText -match '/palp_environments\?') {
                return [pscustomobject] @{
                    Body = [pscustomobject] @{ value = @() }
                }
            }
            if ($uriText -match '/palp_komponentes\?') {
                return [pscustomobject] @{
                    Body = [pscustomobject] @{
                        value = @(
                            [pscustomobject] @{
                                palp_id = $firstId; palp_typ = 5
                                palp_environment = [pscustomobject] @{ palp_id = 'environment-1' }
                                palp_komponentenstatus = 0; palp_status = 0
                            },
                            [pscustomobject] @{
                                palp_id = $secondId; palp_typ = 5
                                palp_environment = [pscustomobject] @{ palp_id = 'environment-2' }
                                palp_komponentenstatus = 0; palp_status = 0
                            }
                        )
                    }
                }
            }
            if ($uriText -match '/\$batch$') {
                throw 'Deletion writes must not be sent after a failed recheck.'
            }
            throw "Unexpected request: $uriText"
        }
        $configuration = [pscustomobject] @{
            TargetDataverseUrl = 'https://example.crm.dynamics.com'
            AgentCreatedIn = 'Agent Builder'
            AgentSubscriptions = @()
            MaxCreatesPerRun = 10
        }

        $result = Invoke-AgentSync -Configuration $configuration `
            -ResourceGraphAccessToken 'graph-token' -DataverseAccessToken 'target-token' `
            -Now ([datetimeoffset] '2026-10-02T10:00:00Z') `
            -ErrorAction SilentlyContinue

        $result.Status | Should -Be 'Partial'
        $result.Counts.MarkedDeleted | Should -Be 0
        $result.Counts.Errors | Should -Be 1
        $result.Batch.Operations | Should -Be 0
        $result.Logs | Should -HaveCount 1
        $result.Logs[0].Category | Should -Be 'VerifyFailed'
        $result.Logs[0].Message | Should -Match 'targeted Resource Graph check failed'
        Should -Invoke Invoke-InventoryHttpRequest -ModuleName InventorySync `
            -ParameterFilter { [string] $Uri -match '/\$batch$' } -Times 0 -Exactly
    }

    It 'treats a truncated targeted response as VerifyFailed' {
        $candidateId = '11111111-1111-1111-1111-111111111111'
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            if ($uriText -match 'Microsoft\.ResourceGraph/resources') {
                if ([string] $Body.query -match 'properties\.createdIn') {
                    return [pscustomobject] @{
                        Body = [pscustomobject] @{ data = @() }
                    }
                }
                return [pscustomobject] @{
                    Body = [pscustomobject] @{
                        data = @()
                        resultTruncated = $true
                    }
                }
            }
            if ($uriText -match '/palp_environments\?') {
                return [pscustomobject] @{ Body = [pscustomobject] @{ value = @() } }
            }
            if ($uriText -match '/palp_komponentes\?') {
                return [pscustomobject] @{
                    Body = [pscustomobject] @{
                        value = @([pscustomobject] @{
                            palp_id = $candidateId; palp_typ = 5
                            palp_environment = [pscustomobject] @{ palp_id = 'environment-1' }
                            palp_komponentenstatus = 0; palp_status = 0
                        })
                    }
                }
            }
            if ($uriText -match '/\$batch$') {
                throw 'Deletion writes must not be sent after an incomplete recheck.'
            }
            throw "Unexpected request: $uriText"
        }
        $configuration = [pscustomobject] @{
            TargetDataverseUrl = 'https://example.crm.dynamics.com'
            AgentCreatedIn = 'Agent Builder'
            AgentSubscriptions = @()
            MaxCreatesPerRun = 10
        }

        $result = Invoke-AgentSync -Configuration $configuration `
            -ResourceGraphAccessToken 'graph-token' -DataverseAccessToken 'target-token' `
            -ErrorAction SilentlyContinue

        $result.Counts.MarkedDeleted | Should -Be 0
        $result.Logs[0].Category | Should -Be 'VerifyFailed'
        $result.Logs[0].Message | Should -Match 'incomplete result'
        Should -Invoke Invoke-InventoryHttpRequest -ModuleName InventorySync `
            -ParameterFilter { [string] $Uri -match '/\$batch$' } -Times 0 -Exactly
    }

    It 'skips deletion checking after an incomplete write phase and logs the reason' {
        $script:targetedChecks = 0
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $uriText = [string] $Uri
            if ($uriText -match 'Microsoft\.ResourceGraph/resources') {
                if ([string] $Body.query -notmatch 'properties\.createdIn') {
                    $script:targetedChecks++
                }
                return [pscustomobject] @{
                    Body = [pscustomobject] @{
                        data = @([pscustomobject] @{
                            agentId = 'new-agent'; title = 'New'
                            description = ''; environmentId = 'environment-1'
                            ownerId = 'owner-1'; createdAt = '2026-09-01T08:00:00Z'
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
                return [pscustomobject] @{
                    Body = [pscustomobject] @{
                        value = @([pscustomobject] @{
                            palp_id = '11111111-1111-1111-1111-111111111111'
                            palp_typ = 5; palp_komponentenstatus = 0; palp_status = 0
                        })
                    }
                }
            }
            if ($uriText -match '/\$batch$') {
                throw 'HTTP 500: Dataverse write failed'
            }
            throw "Unexpected request: $uriText"
        }
        $configuration = [pscustomobject] @{
            TargetDataverseUrl = 'https://example.crm.dynamics.com'
            AgentCreatedIn = 'Agent Builder'
            AgentSubscriptions = @()
            MaxCreatesPerRun = 10
        }

        $result = Invoke-AgentSync -Configuration $configuration `
            -ResourceGraphAccessToken 'graph-token' -DataverseAccessToken 'target-token' `
            -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

        $result.Status | Should -Be 'Partial'
        $result.Counts.MarkedDeleted | Should -Be 0
        $script:targetedChecks | Should -Be 0
        $deletionSkip = @($result.Logs | Where-Object { $_.Operation -eq 'Delete' })
        $deletionSkip | Should -HaveCount 1
        $deletionSkip[0].Category | Should -Be 'Skipped'
        $deletionSkip[0].Message | Should -Match 'write did not complete'
    }
}
