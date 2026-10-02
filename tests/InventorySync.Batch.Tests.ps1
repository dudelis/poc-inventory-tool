BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\Modules\InventorySync\InventorySync.psd1'
    Import-Module $modulePath -Force
}

Describe 'Dataverse batch writes' {
    It 'sends component creates in a Dataverse changeset through the transport seam' {
        $script:capturedBody = $null
        $script:capturedContentType = $null
        Mock Invoke-InventoryHttpRequest -ModuleName InventorySync {
            $script:capturedBody = [string] $Body
            $script:capturedContentType = [string] $ContentType
            [pscustomobject] @{ StatusCode = 200; Headers = @{}; Body = $null }
        }
        $writes = @(
            [pscustomobject] @{
                Method = 'POST'; RelativeUri = 'palp_komponentes'
                Payload = [pscustomobject] @{ palp_id = 'component-1'; palp_typ = 5 }
            },
            [pscustomobject] @{
                Method = 'POST'; RelativeUri = 'palp_komponentes'
                Payload = [pscustomobject] @{ palp_id = 'component-2'; palp_typ = 5 }
            }
        )

        $result = Write-DataverseBatch -Writes $writes `
            -DataverseUrl 'https://example.crm.dynamics.com/' -AccessToken 'target-token'

        $result.Batches | Should -Be 1
        $result.Operations | Should -Be 2
        $script:capturedContentType | Should -Match '^multipart/mixed;boundary=batch_'
        $script:capturedBody | Should -Match 'Content-Type: multipart/mixed;boundary=changeset_'
        $script:capturedBody | Should -Match 'POST palp_komponentes HTTP/1.1'
        $script:capturedBody | Should -Match '"palp_id":"component-1","palp_typ":5'
        $script:capturedBody | Should -Match '"palp_id":"component-2","palp_typ":5'
        ([regex]::Matches($script:capturedBody, 'Content-Transfer-Encoding: binary')).Count |
            Should -Be 2
        Should -Invoke Invoke-InventoryHttpRequest -ModuleName InventorySync -Times 1 -Exactly `
            -ParameterFilter {
                $Method -eq 'POST' -and
                $Uri -eq 'https://example.crm.dynamics.com/api/data/v9.2/$batch' -and
                $Headers.Authorization -eq 'Bearer target-token'
            }
    }
}
