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
    It 'matches the full Default Admin GUID and binds its Dataverse row for type <ComponentType>' -ForEach @(
        @{ ComponentType = 4 }
        @{ ComponentType = 5 }
    ) {
        $source = New-TestSourceComponent `
            -EnvironmentId 'default-4658d2db-ccde-47b9-84f0-8e9bbf015628'
        $environment = [pscustomobject] @{
            palp_id = 'Default-4658d2db-ccde-47b9-84f0-8e9b'
            palp_adminguid = 'Default-4658d2db-ccde-47b9-84f0-8e9bbf015628'
            palp_environmentid = '5a5c35ce-3fc6-f111-aaad-000d3ab63df3'
        }

        $plan = New-InventoryComponentReconciliationPlan `
            -SourceComponents @($source) -Environments @($environment) `
            -ExistingComponents @() -ComponentType $ComponentType

        $plan.Counts.Created | Should -Be 1
        $plan.Counts.Skipped | Should -Be 0
        $plan.Writes[0].Payload.palp_status | Should -BeOfType ([bool])
        $plan.Writes[0].Payload.palp_status | Should -BeFalse
        $plan.Writes[0].Payload.'palp_environment@odata.bind' |
            Should -Be '/palp_environments(5a5c35ce-3fc6-f111-aaad-000d3ab63df3)'
    }

    It 'creates a missing component with technical values and governance defaults' {
        $plan = New-InventoryComponentReconciliationPlan `
            -SourceComponents @(New-TestSourceComponent) `
            -Environments @([pscustomobject] @{ palp_id = 'legacy-environment-1'; palp_adminguid = 'environment-1'; palp_environmentid = '00000000-0000-0000-0000-000000000001' }) `
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

    It 'skips and logs a legacy ID match when Admin GUID is missing' {
        $plan = New-InventoryComponentReconciliationPlan `
            -SourceComponents @(New-TestSourceComponent) `
            -Environments @([pscustomobject] @{
                palp_id = 'environment-1'
                palp_environmentid = '00000000-0000-0000-0000-000000000001'
            }) -ExistingComponents @() -ComponentType 5

        $plan.Writes | Should -HaveCount 0
        $plan.Counts.Skipped | Should -Be 1
        $plan.Logs[0].Message | Should -Match 'Admin GUID'
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
            palp_environment              = [pscustomobject] @{ palp_id = 'legacy-old-environment'; palp_adminguid = 'old-environment'; palp_environmentid = '00000000-0000-0000-0000-000000000003' }
            palp_urspruenglicherstelltam  = '2026-08-01T08:00:00Z'
            palp_urspruenglichgeaendertam = '2026-08-02T09:00:00Z'
            palp_komponentenstatus        = 3
            palp_status                   = 0
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
            -Environments @([pscustomobject] @{ palp_id = 'legacy-environment-1'; palp_adminguid = 'environment-1'; palp_environmentid = '00000000-0000-0000-0000-000000000001' }) `
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
        $source = New-TestSourceComponent `
            -SourceCreatedAt '2026-09-01T08:00:00.7689191Z' `
            -SourceModifiedAt '2026-09-02T09:00:00.7689191Z'
        $componentId = New-InventoryComponentId -EnvironmentId $source.EnvironmentId `
            -ComponentType 5 -SourceId $source.SourceId
        $existing = [pscustomobject] @{
            palp_id                       = $componentId
            palp_titel                    = $source.Title
            palp_besitzerobjectid         = 'OWNER-1'
            palp_beschreibung             = $source.Description
            palp_environment              = [pscustomobject] @{ palp_adminguid = $source.EnvironmentId; palp_environmentid = '00000000-0000-0000-0000-000000000001' }
            palp_urspruenglicherstelltam  = '2026-09-01T08:00:00.0000000Z'
            palp_urspruenglichgeaendertam = '2026-09-02T11:00:00+02:00'
        }

        $plan = New-InventoryComponentReconciliationPlan `
            -SourceComponents @($source) `
            -Environments @([pscustomobject] @{ palp_id = 'legacy-environment-1'; palp_adminguid = 'environment-1'; palp_environmentid = '00000000-0000-0000-0000-000000000001' }) `
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
            -Environments @([pscustomobject] @{ palp_id = 'legacy-environment-1'; palp_adminguid = 'environment-1'; palp_environmentid = '00000000-0000-0000-0000-000000000001' }) `
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
            -Environments @([pscustomobject] @{ palp_id = 'legacy-environment-1'; palp_adminguid = 'environment-1'; palp_environmentid = '00000000-0000-0000-0000-000000000001' }) `
            -ExistingComponents @($otherTypeRow) -ComponentType 5 -CreationCap 10

        $plan.Counts.Created | Should -Be 1
        $plan.Counts.Updated | Should -Be 0
        $plan.Writes[0].Method | Should -Be 'POST'
        $plan.Writes[0].Payload.palp_typ | Should -Be 5
    }
}
