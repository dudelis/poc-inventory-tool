BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\Modules\InventorySync\InventorySync.psd1'
    Import-Module $modulePath -Force
}

Describe 'Paged API reads' {
    It 'returns every Dataverse record by following @odata.nextLink' {
        $script:requestedUris = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $script:requestedUris.Add([string] $Uri)
            if ($script:requestedUris.Count -eq 1) {
                return [pscustomobject] @{
                    Body = [pscustomobject] @{
                        value             = @([pscustomobject] @{ id = 'one' })
                        '@odata.nextLink' = 'https://example.crm.dynamics.com/api/data/v9.2/widgets?$skiptoken=next'
                    }
                }
            }

            [pscustomobject] @{
                Body = [pscustomobject] @{
                    value = @([pscustomobject] @{ id = 'two' })
                }
            }
        }

        $records = @(Get-DataversePagedRecords `
            -Uri 'https://example.crm.dynamics.com/api/data/v9.2/widgets?$select=id' `
            -AccessToken 'token')

        $records.id | Should -Be @('one', 'two')
        $script:requestedUris | Should -Be @(
            'https://example.crm.dynamics.com/api/data/v9.2/widgets?$select=id',
            'https://example.crm.dynamics.com/api/data/v9.2/widgets?$skiptoken=next'
        )
        Should -Invoke Invoke-InventoryHttpRequest -ModuleName InventorySync -Times 2 -Exactly `
            -ParameterFilter { $Headers.Authorization -eq 'Bearer token' }
    }

    It 'returns every Resource Graph row by sending each $skipToken' {
        $script:requestBodies = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $script:requestBodies.Add($Body)
            if ($script:requestBodies.Count -eq 1) {
                return [pscustomobject] @{
                    Body = [pscustomobject] @{
                        data         = @([pscustomobject] @{ id = 'one' })
                        '$skipToken' = 'continuation-token'
                    }
                }
            }

            [pscustomobject] @{
                Body = [pscustomobject] @{
                    data = @([pscustomobject] @{ id = 'two' })
                }
            }
        }

        $records = @(Invoke-ResourceGraphPagedQuery -Query 'resources | project id' `
            -Subscriptions @('subscription-id') -AccessToken 'token')

        $records.id | Should -Be @('one', 'two')
        $script:requestBodies | Should -HaveCount 2
        $script:requestBodies[0].options.PSObject.Properties['$skipToken'] | Should -BeNullOrEmpty
        $script:requestBodies[1].options.'$skipToken' | Should -Be 'continuation-token'
        Should -Invoke Invoke-InventoryHttpRequest -ModuleName InventorySync -Times 2 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and
            $Uri -eq 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2024-04-01' -and
            $Headers.Authorization -eq 'Bearer token'
        }
    }
}
