BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\Modules\InventorySync\InventorySync.psd1'
    Import-Module $modulePath -Force
}

Describe 'Inventory component identity' {
    It 'uses a stable component ID that is unique to the environment' {
        $first = New-InventoryComponentId -EnvironmentId 'environment-1' -ComponentType 5 `
            -SourceId 'agent-1'
        $again = New-InventoryComponentId -EnvironmentId 'environment-1' -ComponentType 5 `
            -SourceId 'agent-1'
        $otherEnvironment = New-InventoryComponentId -EnvironmentId 'environment-2' -ComponentType 5 `
            -SourceId 'agent-1'

        $first | Should -Be '8c1faa29-db0a-5c1e-9616-f2ede5028847'
        $again | Should -Be $first
        $otherEnvironment | Should -Be 'f84f8d7a-705e-534c-90d5-656cc2041b35'
    }
}
