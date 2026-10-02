function Get-InventoryDeletionCandidates {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $ExistingComponents,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $CollectedComponentIds,
        [Parameter(Mandatory)] [int] $ComponentType,
        [Parameter()] [AllowEmptyCollection()] [string[]] $IncludedEnvironmentIds
    )

    $collected = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($componentId in $CollectedComponentIds) {
        if (-not [string]::IsNullOrWhiteSpace($componentId)) {
            $null = $collected.Add($componentId)
        }
    }
    $includedEnvironments = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    if ($PSBoundParameters.ContainsKey('IncludedEnvironmentIds')) {
        foreach ($environmentId in $IncludedEnvironmentIds) {
            if (-not [string]::IsNullOrWhiteSpace($environmentId)) {
                $null = $includedEnvironments.Add($environmentId)
            }
        }
    }

    foreach ($existing in $ExistingComponents) {
        $typeProperty = $existing.PSObject.Properties['palp_typ']
        if ($null -ne $typeProperty -and [int] $typeProperty.Value -ne $ComponentType) {
            continue
        }
        $statusProperty = $existing.PSObject.Properties['palp_status']
        if ($null -ne $statusProperty -and [int] $statusProperty.Value -ne 0) {
            continue
        }
        $componentStatusProperty = $existing.PSObject.Properties['palp_komponentenstatus']
        if ($null -ne $componentStatusProperty -and [int] $componentStatusProperty.Value -eq 7) {
            continue
        }
        if ($PSBoundParameters.ContainsKey('IncludedEnvironmentIds')) {
            $environmentId = [string] $existing.palp_environment.palp_id
            if (-not $includedEnvironments.Contains($environmentId)) {
                continue
            }
        }
        $componentId = [string] $existing.palp_id
        if (-not [string]::IsNullOrWhiteSpace($componentId) -and -not $collected.Contains($componentId)) {
            $existing
        }
    }
}

function Get-MissingAgentCandidateIds {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Candidates,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $CreatedIn,
        [Parameter(Mandatory)] [string] $AccessToken
    )

    foreach ($environmentGroup in @($Candidates | Group-Object {
                [string] $_.palp_environment.palp_id
            })) {
        $environmentId = [string] $environmentGroup.Name
        if ([string]::IsNullOrWhiteSpace($environmentId)) {
            throw 'An Agent deletion candidate has no source environment identity.'
        }
        $environmentLiteral = $environmentId.Replace('\', '\\').Replace('"', '\"')
        $createdInLiteral = $CreatedIn.Replace('\', '\\').Replace('"', '\"')
        $query = @"
PowerPlatformResources
| where type =~ "microsoft.copilotstudio/agents"
| extend properties = parse_json(properties)
| where tostring(properties.createdIn) == "$createdInLiteral"
| where tostring(properties.environmentId) =~ "$environmentLiteral"
| project agentId = tostring(name)
"@
        $sourceTargetIds = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        foreach ($match in @(Invoke-ResourceGraphPagedQuery -Query $query -AccessToken $AccessToken)) {
            $targetId = New-InventoryComponentId -EnvironmentId $environmentId `
                -ComponentType 5 -SourceId ([string] $match.agentId)
            $null = $sourceTargetIds.Add($targetId)
        }
        foreach ($candidate in $environmentGroup.Group) {
            $candidateId = [string] $candidate.palp_id
            if (-not $sourceTargetIds.Contains($candidateId)) {
                $candidateId
            }
        }
    }
}

function New-InventoryDeletionWrites {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Candidates,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ConfirmedMissingIds,
        [Parameter(Mandatory)] [int] $ComponentType,
        [Parameter(Mandatory)] [datetimeoffset] $Now
    )

    $confirmedMissing = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($componentId in $ConfirmedMissingIds) {
        $null = $confirmedMissing.Add($componentId)
    }

    foreach ($candidate in $Candidates) {
        $componentId = [string] $candidate.palp_id
        if (-not $confirmedMissing.Contains($componentId)) {
            continue
        }
        $environmentId = ''
        $environmentProperty = $candidate.PSObject.Properties['palp_environment']
        if ($null -ne $environmentProperty -and $null -ne $environmentProperty.Value) {
            $environmentId = [string] $environmentProperty.Value.palp_id
        }
        $escapedComponentId = $componentId.Replace("'", "''")
        [pscustomobject] @{
            Method        = 'PATCH'
            RelativeUri   = "palp_komponentes(palp_id='$escapedComponentId')"
            Payload       = [pscustomobject] [ordered] @{
                palp_komponentenstatus     = 7
                palp_status                = 1
                palp_letztestatusaenderung = $Now.ToString('o')
            }
            EnvironmentId = $environmentId
            ComponentType = $ComponentType
            ComponentId   = $componentId
            Operation     = 'Delete'
        }
    }
}

function Invoke-InventoryDeletionCheck {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $ExistingComponents,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $CollectedComponentIds,
        [Parameter(Mandatory)] [int] $ComponentType,
        [Parameter(Mandatory)] [datetimeoffset] $Now,
        [Parameter(Mandatory)] [scriptblock] $VerificationAction,
        [Parameter(Mandatory)] [string] $DataverseUrl,
        [Parameter(Mandatory)] [string] $DataverseAccessToken,
        [Parameter()] [AllowEmptyCollection()] [string[]] $IncludedEnvironmentIds
    )

    $candidateParameters = @{
        ExistingComponents    = $ExistingComponents
        CollectedComponentIds = $CollectedComponentIds
        ComponentType         = $ComponentType
    }
    if ($PSBoundParameters.ContainsKey('IncludedEnvironmentIds')) {
        $candidateParameters.IncludedEnvironmentIds = $IncludedEnvironmentIds
    }
    $candidates = @(Get-InventoryDeletionCandidates @candidateParameters)
    $confirmedMissingIds = @(& $VerificationAction $candidates)
    $writes = @(New-InventoryDeletionWrites -Candidates $candidates `
        -ConfirmedMissingIds $confirmedMissingIds -ComponentType $ComponentType -Now $Now)
    $batch = Write-DataverseBatch -Writes $writes -DataverseUrl $DataverseUrl `
        -AccessToken $DataverseAccessToken

    [pscustomobject] @{
        Candidates = $candidates
        Batch      = $batch
    }
}

function Get-MissingRpaCandidateIds {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Candidates,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Environments,
        [Parameter(Mandatory)] [psobject] $Configuration
    )

    $environmentsById = @{}
    foreach ($environment in $Environments) {
        $environmentsById[[string] $environment.palp_id] = $environment
    }
    foreach ($environmentGroup in @($Candidates | Group-Object {
                [string] $_.palp_environment.palp_id
            })) {
        $environmentId = [string] $environmentGroup.Name
        if (-not $environmentsById.ContainsKey($environmentId)) {
            throw "No successfully read environment '$environmentId' is available for targeted re-check."
        }
        $environment = $environmentsById[$environmentId]
        $accessToken = Get-InventoryAccessToken -Resource ([string] $environment.DataverseUrl) `
            -Configuration $Configuration
        $query = 'workflows?$select=workflowid' +
            '&$filter=category%20eq%206'
        $matches = @(Get-DataversePagedRecords `
            -Uri "$($environment.DataverseUrl)/api/data/v9.2/$query" `
            -AccessToken $accessToken)
        $sourceTargetIds = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        foreach ($match in $matches) {
            $targetId = New-InventoryComponentId -EnvironmentId $environmentId `
                -ComponentType 4 -SourceId ([string] $match.workflowid)
            $null = $sourceTargetIds.Add($targetId)
        }
        foreach ($candidate in $environmentGroup.Group) {
            $candidateId = [string] $candidate.palp_id
            if (-not $sourceTargetIds.Contains($candidateId)) {
                $candidateId
            }
        }
    }
}
