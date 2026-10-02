BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\Modules\InventorySync\InventorySync.psd1'
    Import-Module $modulePath -Force

    function New-TestSourceComponent {
        param(
            [string] $SourceId = 'agent-1',
            [string] $EnvironmentId = 'environment-1',
            [string] $Title = 'Agent one',
            [string] $OwnerObjectId = 'owner-1',
            [AllowNull()] [string] $Description = 'Description one',
            [string] $SourceCreatedAt = '2026-09-01T08:00:00Z',
            [string] $SourceModifiedAt = '2026-09-02T09:00:00Z'
        )

        [pscustomobject] @{
            SourceId         = $SourceId
            EnvironmentId    = $EnvironmentId
            Title            = $Title
            OwnerObjectId    = $OwnerObjectId
            Description      = $Description
            SourceCreatedAt  = $SourceCreatedAt
            SourceModifiedAt = $SourceModifiedAt
        }
    }
}

Describe 'Shared component reconciliation' {
    It 'creates a missing component with technical values and governance defaults' {
        $plan = New-InventoryComponentReconciliationPlan `
            -SourceComponents @(New-TestSourceComponent) `
            -Environments @([pscustomobject] @{ palp_id = 'environment-1' }) `
            -ExistingComponents @() -ComponentType 5 -CreationCap 10 `
            -Now ([datetimeoffset] '2026-10-02T10:00:00Z')

        $plan.Counts.Created | Should -Be 1
        $plan.Counts.Updated | Should -Be 0
        $plan.Counts.Unchanged | Should -Be 0
        $plan.Writes | Should -HaveCount 1
        $plan.Writes[0].Method | Should -Be 'POST'
        $plan.Writes[0].Payload.palp_beschreibung | Should -Be 'Description one'
        $plan.Writes[0].Payload.palp_komponentenstatus | Should -Be 0
    }

    It 'updates only technical values that changed' {
        $source = New-TestSourceComponent
        $componentId = New-InventoryComponentId -EnvironmentId $source.EnvironmentId `
            -ComponentType 5 -SourceId $source.SourceId
        $existing = [pscustomobject] @{
            palp_id                       = $componentId
            palp_titel                    = 'Old title'
            palp_besitzerobjectid         = 'old-owner'
            palp_beschreibung             = 'Old description'
            palp_environment              = [pscustomobject] @{ palp_id = 'old-environment' }
            palp_urspruenglicherstelltam  = '2026-08-01T08:00:00Z'
            palp_urspruenglichgeaendertam = '2026-08-02T09:00:00Z'
            palp_komponentenstatus        = 7
            palp_status                   = 1
            palp_nutzungsbereich          = 2
            palp_letztestatusaenderung    = '2026-08-03T09:00:00Z'
            palp_regelverstoss            = $true
            palp_handlungsbedarf          = 'Do not overwrite'
            palp_stellvertreter           = 'delegate'
            palp_team                     = 'team'
            palp_gesellschaft             = 'company'
        }

        $plan = New-InventoryComponentReconciliationPlan `
            -SourceComponents @($source) `
            -Environments @([pscustomobject] @{ palp_id = 'environment-1' }) `
            -ExistingComponents @($existing) -ComponentType 5 -CreationCap 10

        $plan.Counts.Updated | Should -Be 1
        $plan.Counts.Created | Should -Be 0
        $plan.Writes | Should -HaveCount 1
        $plan.Writes[0].Method | Should -Be 'PATCH'
        $plan.Writes[0].RelativeUri | Should -Be "palp_komponentes(palp_id='$componentId')"
        @($plan.Writes[0].Payload.PSObject.Properties.Name | Sort-Object) |
            Should -Be @(
                'palp_beschreibung'
                'palp_besitzerobjectid'
                'palp_environment@odata.bind'
                'palp_titel'
                'palp_urspruenglicherstelltam'
                'palp_urspruenglichgeaendertam'
            )
    }

    It 'does not write an unchanged component' {
        $source = New-TestSourceComponent
        $componentId = New-InventoryComponentId -EnvironmentId $source.EnvironmentId `
            -ComponentType 5 -SourceId $source.SourceId
        $existing = [pscustomobject] @{
            palp_id                       = $componentId
            palp_titel                    = $source.Title
            palp_besitzerobjectid         = 'OWNER-1'
            palp_beschreibung             = $source.Description
            palp_environment              = [pscustomobject] @{ palp_id = $source.EnvironmentId }
            palp_urspruenglicherstelltam  = '2026-09-01T08:00:00.0000000Z'
            palp_urspruenglichgeaendertam = '2026-09-02T11:00:00+02:00'
        }

        $plan = New-InventoryComponentReconciliationPlan `
            -SourceComponents @($source) `
            -Environments @([pscustomobject] @{ palp_id = 'environment-1' }) `
            -ExistingComponents @($existing) -ComponentType 5 -CreationCap 10

        $plan.Writes | Should -HaveCount 0
        $plan.Counts.Created | Should -Be 0
        $plan.Counts.Updated | Should -Be 0
        $plan.Counts.Unchanged | Should -Be 1
    }

    It 'skips and logs new components beyond the creation cap' {
        $sources = @(
            New-TestSourceComponent -SourceId 'agent-1' -Title 'Agent one'
            New-TestSourceComponent -SourceId 'agent-2' -Title 'Agent two'
        )

        $plan = New-InventoryComponentReconciliationPlan `
            -SourceComponents $sources `
            -Environments @([pscustomobject] @{ palp_id = 'environment-1' }) `
            -ExistingComponents @() -ComponentType 5 -CreationCap 1

        $plan.Writes | Should -HaveCount 1
        $plan.Counts.Created | Should -Be 1
        $plan.Counts.Skipped | Should -Be 1
        $plan.Logs | Should -HaveCount 1
        $plan.Logs[0].Category | Should -Be 'Skipped'
        $plan.Logs[0].ComponentId | Should -Be 'agent-2'
        $plan.Logs[0].Message | Should -Match 'creation cap of 1'
    }

    It 'never reconciles an existing row of another component type' {
        $source = New-TestSourceComponent
        $componentId = New-InventoryComponentId -EnvironmentId $source.EnvironmentId `
            -ComponentType 5 -SourceId $source.SourceId
        $otherTypeRow = [pscustomobject] @{
            palp_id = $componentId
            palp_typ = 4
            palp_titel = 'Desktop flow row'
        }

        $plan = New-InventoryComponentReconciliationPlan `
            -SourceComponents @($source) `
            -Environments @([pscustomobject] @{ palp_id = 'environment-1' }) `
            -ExistingComponents @($otherTypeRow) -ComponentType 5 -CreationCap 10

        $plan.Counts.Created | Should -Be 1
        $plan.Counts.Updated | Should -Be 0
        $plan.Writes[0].Method | Should -Be 'POST'
        $plan.Writes[0].Payload.palp_typ | Should -Be 5
    }
}
