BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\Modules\InventorySync\InventorySync.psd1'
    Import-Module $modulePath -Force
}

Describe 'Inventory HTTP transport' {
    It 'retries throttled requests and honors Retry-After' {
        $script:attempt = 0
        $script:delays = [System.Collections.Generic.List[double]]::new()
        $invoker = {
            param($request)
            $script:attempt++
            if ($script:attempt -eq 1) {
                return [pscustomobject] @{
                    StatusCode = 429
                    Headers    = @{ 'Retry-After' = '2' }
                    Content    = '{"error":{"code":"TooManyRequests"}}'
                }
            }

            [pscustomobject] @{
                StatusCode = 200
                Headers    = @{}
                Content    = '{"value":"complete"}'
            }
        }
        $sleeper = { param([double] $seconds) $script:delays.Add($seconds) }

        $response = Invoke-InventoryHttpRequest -Uri 'https://example.crm.dynamics.com/api/data/v9.2/test' `
            -Invoker $invoker -SleepAction $sleeper

        $response.Body.value | Should -Be 'complete'
        $script:attempt | Should -Be 2
        $script:delays | Should -HaveCount 1
        $script:delays[0] | Should -Be 2
    }

    It 'retries Dataverse service-protection errors' {
        $script:attempt = 0
        $script:delays = [System.Collections.Generic.List[double]]::new()
        $invoker = {
            param($request)
            $script:attempt++
            if ($script:attempt -eq 1) {
                return [pscustomobject] @{
                    StatusCode = 503
                    Headers    = @{ 'Retry-After' = '3' }
                    Content    = '{"error":{"code":"0x80072321","message":"Service protection limit exceeded"}}'
                }
            }

            [pscustomobject] @{ StatusCode = 204; Headers = @{}; Content = '' }
        }
        $sleeper = { param([double] $seconds) $script:delays.Add($seconds) }

        $response = Invoke-InventoryHttpRequest -Uri 'https://example.crm.dynamics.com/api/data/v9.2/test' `
            -Method POST -Invoker $invoker -SleepAction $sleeper

        $response.StatusCode | Should -Be 204
        $script:attempt | Should -Be 2
        $script:delays[0] | Should -Be 3
    }

    It 'stops after the configured retry bound' {
        $script:attempt = 0
        $invoker = {
            param($request)
            $script:attempt++
            [pscustomobject] @{
                StatusCode = 429
                Headers    = @{ 'Retry-After' = '0' }
                Content    = '{"error":{"code":"TooManyRequests","message":"Still throttled"}}'
            }
        }

        {
            Invoke-InventoryHttpRequest -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources' `
                -MaxRetryCount 2 -Invoker $invoker -SleepAction { param($seconds) }
        } | Should -Throw '*HTTP 429*Still throttled*'
        $script:attempt | Should -Be 3
    }

    It 'reports a nonstandard JSON error without masking the HTTP status' {
        $invoker = {
            param($request)
            [pscustomobject] @{
                StatusCode = 400
                Headers    = @{}
                Content    = '{"title":"Bad request"}'
            }
        }

        {
            Invoke-InventoryHttpRequest -Uri 'https://example.invalid/request' -Invoker $invoker
        } | Should -Throw '*HTTP 400*Bad request*'
    }
}
