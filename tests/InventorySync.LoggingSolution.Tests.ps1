BeforeAll {
    $script:solutionRoot = Join-Path $PSScriptRoot '..\solutions\InventorySyncLogging'
}

Describe 'Inventory Sync Logging Dataverse solution' {
    It 'is a separate unmanaged solution with Sync Run and Sync Log tables' {
        [xml] $solution = Get-Content (Join-Path $solutionRoot 'Other\Solution.xml') -Raw

        $solution.ImportExportXml.SolutionManifest.UniqueName | Should -Be 'InventorySyncLogging'
        $solution.ImportExportXml.SolutionManifest.Managed | Should -Be '0'
        $rootComponents = @($solution.ImportExportXml.SolutionManifest.RootComponents.RootComponent)
        @($rootComponents.schemaName) | Should -Contain 'invs_syncrun'
        @($rootComponents.schemaName) | Should -Contain 'invs_synclog'
        @($rootComponents | Where-Object type -eq '10') | Should -HaveCount 0
    }

    It 'defines every Sync Run field and option' {
        $xml = Get-Content (Join-Path $solutionRoot 'Entities\invs_syncrun\Entity.xml') -Raw
        $fields = @(
            'invs_runid', 'invs_synctype', 'invs_phase', 'invs_startedon',
            'invs_completedon', 'invs_status', 'invs_environmentstotal',
            'invs_environmentsfailed', 'invs_found', 'invs_created',
            'invs_updated', 'invs_unchanged', 'invs_markeddeleted',
            'invs_restored', 'invs_errors'
        )

        foreach ($field in $fields) {
            $xml | Should -Match "<Name>$field</Name>"
        }
        foreach ($option in @(
            'RPA', 'AgentBuilder', 'Collect', 'Write', 'DeletionCheck',
            'Running', 'Succeeded', 'Partial', 'Failed'
        )) {
            $xml | Should -Match "description=`"$option`""
        }
    }

    It 'marks every declared primary name attribute' {
        Get-ChildItem (Join-Path $solutionRoot 'Entities') -Directory |
            ForEach-Object {
                [xml] $entity = Get-Content (Join-Path $_.FullName 'Entity.xml') -Raw
                $primaryName = $entity.Entity.EntityInfo.entity.PrimaryNameAttribute
                $primaryNameAttribute = @(
                    $entity.Entity.EntityInfo.entity.attributes.attribute
                ) | Where-Object { $_.LogicalName -eq $primaryName }

                $primaryNameAttribute | Should -HaveCount 1
                @($primaryNameAttribute.DisplayMask -split '\|') |
                    Should -Contain 'PrimaryName'
            }
    }

    It 'stores each relationship component under its schema name' {
        [xml] $relationships = Get-Content (
            Join-Path $solutionRoot 'Other\Relationships.xml'
        ) -Raw

        foreach ($relationship in @($relationships.EntityRelationships.EntityRelationship)) {
            $componentPath = Join-Path $solutionRoot (
                "Other\Relationships\$($relationship.Name).xml"
            )
            $componentPath | Should -Exist
            [xml] $component = Get-Content $componentPath -Raw
            $component.EntityRelationships.EntityRelationship.GetAttribute('Name') |
                Should -Be $relationship.Name
        }
    }

    It 'defines every Sync Log field, option, and Sync Run lookup' {
        [xml] $entity = Get-Content (
            Join-Path $solutionRoot 'Entities\invs_synclog\Entity.xml'
        ) -Raw
        $xml = $entity.OuterXml
        $relationships = Get-Content (
            Join-Path $solutionRoot 'Other\Relationships\invs_syncrun_synclogs.xml'
        ) -Raw
        $fields = @(
            'invs_syncrunid', 'invs_severity', 'invs_category',
            'invs_environmentid', 'invs_environmentname', 'invs_componenttype',
            'invs_componentid', 'invs_operation', 'invs_httpstatus',
            'invs_errorcode', 'invs_errormessage', 'invs_occurredon',
            'invs_correlationid'
        )

        foreach ($field in $fields) {
            $xml | Should -Match "<Name>$field</Name>"
        }
        foreach ($option in @(
            'Warning', 'Error', 'EnvironmentUnreachable', 'PermissionDenied',
            'Throttled', 'ReadFailed', 'WriteFailed', 'VerifyFailed', 'Config',
            'RunSkipped', 'Restored', 'Skipped'
        )) {
            $xml | Should -Match "description=`"$option`""
        }
        $relationships | Should -Match '<ReferencedEntityName>invs_syncrun</ReferencedEntityName>'
        $relationships | Should -Match '<ReferencingEntityName>invs_synclog</ReferencingEntityName>'
        $relationships | Should -Match '<ReferencingAttributeName>invs_syncrunid</ReferencingAttributeName>'
        $relationships | Should -Match '<RelationshipRoleType>1</RelationshipRoleType>'
        $relationships | Should -Match (
            '<NavigationPropertyName>invs_syncrun_synclogs</NavigationPropertyName>'
        )

        $syncRunLookup = @($entity.Entity.EntityInfo.entity.attributes.attribute) |
            Where-Object { $_.LogicalName -eq 'invs_syncrunid' }
        $syncRunLookup.LookupTypes.LookupType | Should -BeNullOrEmpty
    }
}
