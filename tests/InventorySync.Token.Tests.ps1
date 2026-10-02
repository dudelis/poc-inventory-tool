BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\Modules\InventorySync\InventorySync.psd1'
    Import-Module $modulePath -Force
}

Describe 'Client-credentials token acquisition' {
    BeforeEach {
        Clear-InventoryTokenCache
        $script:tokenRequestCount = 0
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $script:tokenRequestCount++
            [pscustomobject] @{
                StatusCode = 200
                Headers    = @{}
                Body       = [pscustomobject] @{
                    access_token = "token-$script:tokenRequestCount"
                    expires_in   = 3600
                    token_type   = 'Bearer'
                }
            }
        }
    }

    It 'caches a token independently for each resource' {
        $configuration = [pscustomobject] @{
            TenantId     = 'tenant'
            ClientId     = 'client'
            ClientSecret = 'secret'
        }
        $now = [datetimeoffset] '2026-10-02T10:00:00Z'

        $first = Get-InventoryAccessToken -Resource 'https://management.azure.com/' -Configuration $configuration -Now $now
        $cached = Get-InventoryAccessToken -Resource 'https://management.azure.com' -Configuration $configuration -Now $now.AddMinutes(10)
        $other = Get-InventoryAccessToken -Resource 'https://example.crm.dynamics.com/' -Configuration $configuration -Now $now

        $first | Should -Be 'token-1'
        $cached | Should -Be 'token-1'
        $other | Should -Be 'token-2'
        Should -Invoke Invoke-InventoryHttpRequest -ModuleName InventorySync -Times 2 -Exactly
    }

    It 'refreshes a token shortly before it expires' {
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $script:tokenRequestCount++
            [pscustomobject] @{
                StatusCode = 200
                Headers    = @{}
                Body       = [pscustomobject] @{
                    access_token = "token-$script:tokenRequestCount"
                    expires_in   = 301
                }
            }
        }
        $configuration = [pscustomobject] @{
            TenantId     = 'tenant'
            ClientId     = 'client'
            ClientSecret = 'secret'
        }
        $now = [datetimeoffset] '2026-10-02T10:00:00Z'

        $first = Get-InventoryAccessToken -Resource 'https://management.azure.com' -Configuration $configuration -Now $now
        $refreshed = Get-InventoryAccessToken -Resource 'https://management.azure.com' -Configuration $configuration -Now $now.AddSeconds(2)

        $first | Should -Be 'token-1'
        $refreshed | Should -Be 'token-2'
        Should -Invoke Invoke-InventoryHttpRequest -ModuleName InventorySync -Times 2 -Exactly
    }

    It 'sends the v2 client-credentials request through the shared transport' {
        $configuration = [pscustomobject] @{
            TenantId     = 'tenant'
            ClientId     = 'client id'
            ClientSecret = 's&cret'
        }

        Get-InventoryAccessToken -Resource 'https://management.azure.com/' -Configuration $configuration | Out-Null

        Should -Invoke Invoke-InventoryHttpRequest -ModuleName InventorySync -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://login.microsoftonline.com/tenant/oauth2/v2.0/token' -and
            $Method -eq 'POST' -and
            $ContentType -eq 'application/x-www-form-urlencoded' -and
            $Body -match 'client_id=client\+id' -and
            $Body -match 'client_secret=s%26cret' -and
            $Body -match 'scope=https%3A%2F%2Fmanagement.azure.com%2F.default'
        }
    }
}
