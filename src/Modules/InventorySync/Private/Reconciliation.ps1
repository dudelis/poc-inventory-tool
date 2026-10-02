function New-InventoryComponentId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $EnvironmentId,
        [Parameter(Mandatory)] [ValidateRange(0, [int]::MaxValue)] [int] $ComponentType,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SourceId
    )

    $namespaceBytes = ([guid] '89d605f0-44cb-497c-a664-96c6c13d2bfc').ToByteArray()
    [array]::Reverse($namespaceBytes, 0, 4)
    [array]::Reverse($namespaceBytes, 4, 2)
    [array]::Reverse($namespaceBytes, 6, 2)

    $name = '{0}|{1}|{2}' -f $EnvironmentId.Trim().ToLowerInvariant(), $ComponentType,
        $SourceId.Trim().ToLowerInvariant()
    $nameBytes = [System.Text.Encoding]::UTF8.GetBytes($name)
    $inputBytes = [byte[]]::new($namespaceBytes.Length + $nameBytes.Length)
    [array]::Copy($namespaceBytes, 0, $inputBytes, 0, $namespaceBytes.Length)
    [array]::Copy($nameBytes, 0, $inputBytes, $namespaceBytes.Length, $nameBytes.Length)

    $hash = [System.Security.Cryptography.SHA1]::HashData($inputBytes)
    $guidBytes = [byte[]] $hash[0..15]
    $guidBytes[6] = [byte] (($guidBytes[6] -band 0x0f) -bor 0x50)
    $guidBytes[8] = [byte] (($guidBytes[8] -band 0x3f) -bor 0x80)
    [array]::Reverse($guidBytes, 0, 4)
    [array]::Reverse($guidBytes, 4, 2)
    [array]::Reverse($guidBytes, 6, 2)

    ([guid]::new($guidBytes)).ToString()
}

function Test-InventoryTechnicalValueEqual {
    param(
        [Parameter(Mandatory)] [string] $FieldName,
        [AllowNull()] $ExistingValue,
        [AllowNull()] $SourceValue
    )

    if ($FieldName -in @('palp_urspruenglicherstelltam', 'palp_urspruenglichgeaendertam')) {
        $existingTimestamp = [datetimeoffset]::MinValue
        $sourceTimestamp = [datetimeoffset]::MinValue
        if (
            [datetimeoffset]::TryParse([string] $ExistingValue, [ref] $existingTimestamp) -and
            [datetimeoffset]::TryParse([string] $SourceValue, [ref] $sourceTimestamp)
        ) {
            return $existingTimestamp.UtcTicks -eq $sourceTimestamp.UtcTicks
        }
    }
    if ($FieldName -eq 'palp_besitzerobjectid') {
        return [string] $ExistingValue -ieq [string] $SourceValue
    }

    [string] $ExistingValue -ceq [string] $SourceValue
}

function New-InventoryComponentReconciliationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $SourceComponents,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Environments,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $ExistingComponents,
        [Parameter(Mandatory)] [ValidateRange(0, [int]::MaxValue)] [int] $ComponentType,
        [Parameter()] [ValidateRange(0, [int]::MaxValue)] [int] $CreationCap = [int]::MaxValue,
        [Parameter()] [datetimeoffset] $Now = [datetimeoffset]::UtcNow
    )

    $existingById = @{}
    foreach ($existing in $ExistingComponents) {
        $typeProperty = $existing.PSObject.Properties['palp_typ']
        if ($null -ne $typeProperty -and [int] $typeProperty.Value -ne $ComponentType) {
            continue
        }
        $idProperty = $existing.PSObject.Properties['palp_id']
        if ($null -ne $idProperty -and -not [string]::IsNullOrWhiteSpace([string] $idProperty.Value)) {
            $existingById[[string] $idProperty.Value] = $existing
        }
    }
    $knownEnvironmentIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($environment in $Environments) {
        $environmentIdProperty = $environment.PSObject.Properties['palp_id']
        if (
            $null -ne $environmentIdProperty -and
            -not [string]::IsNullOrWhiteSpace([string] $environmentIdProperty.Value)
        ) {
            $null = $knownEnvironmentIds.Add(([string] $environmentIdProperty.Value).Trim())
        }
    }

    $writes = [System.Collections.Generic.List[object]]::new()
    $logs = [System.Collections.Generic.List[object]]::new()
    $created = 0
    $updated = 0
    $restored = 0
    $unchanged = 0
    $skipped = 0
    foreach ($source in $SourceComponents) {
        $environmentId = ([string] $source.EnvironmentId).Trim()
        $componentId = New-InventoryComponentId -EnvironmentId $environmentId `
            -ComponentType $ComponentType -SourceId ([string] $source.SourceId)
        $escapedEnvironmentId = $environmentId.Replace("'", "''")
        if ($existingById.ContainsKey($componentId)) {
            $existing = $existingById[$componentId]
            $payload = [ordered] @{}
            $componentStatusProperty = $existing.PSObject.Properties['palp_komponentenstatus']
            $isDeleted = $null -ne $componentStatusProperty -and
                [int] $componentStatusProperty.Value -eq 7
            $fieldMappings = [ordered] @{
                palp_titel                    = [string] $source.Title
                palp_besitzerobjectid         = [string] $source.OwnerObjectId
                palp_beschreibung             = $source.Description
                palp_urspruenglicherstelltam  = [string] $source.SourceCreatedAt
                palp_urspruenglichgeaendertam = [string] $source.SourceModifiedAt
            }
            foreach ($mapping in $fieldMappings.GetEnumerator()) {
                $existingProperty = $existing.PSObject.Properties[$mapping.Key]
                $existingValue = if ($null -ne $existingProperty) { $existingProperty.Value } else { $null }
                if (-not (Test-InventoryTechnicalValueEqual -FieldName $mapping.Key `
                            -ExistingValue $existingValue -SourceValue $mapping.Value)) {
                    $payload[$mapping.Key] = $mapping.Value
                }
            }

            $existingEnvironmentId = $null
            $environmentProperty = $existing.PSObject.Properties['palp_environment']
            if ($null -ne $environmentProperty -and $null -ne $environmentProperty.Value) {
                $environmentIdProperty = $environmentProperty.Value.PSObject.Properties['palp_id']
                if ($null -ne $environmentIdProperty) {
                    $existingEnvironmentId = [string] $environmentIdProperty.Value
                }
            }
            if ($existingEnvironmentId -ine $environmentId) {
                $payload['palp_environment@odata.bind'] =
                    "/palp_environments(palp_id='$escapedEnvironmentId')"
            }
            if ($isDeleted) {
                $payload.palp_komponentenstatus = 0
                $payload.palp_status = 0
                $payload.palp_letztestatusaenderung = $Now.ToString('o')
            }

            if ($payload.Count -gt 0) {
                $escapedComponentId = $componentId.Replace("'", "''")
                $writes.Add([pscustomobject] @{
                    Method        = 'PATCH'
                    RelativeUri   = "palp_komponentes(palp_id='$escapedComponentId')"
                    Payload       = [pscustomobject] $payload
                    EnvironmentId = $environmentId
                    ComponentType = $ComponentType
                    ComponentId   = [string] $source.SourceId
                    Operation     = if ($isDeleted) { 'Restore' } else { 'Update' }
                })
                if ($isDeleted) {
                    $restored++
                    $logs.Add([pscustomobject] [ordered] @{
                        Severity      = 'Warning'
                        Category      = 'Restored'
                        EnvironmentId = $environmentId
                        ComponentType = $ComponentType
                        ComponentId   = [string] $source.SourceId
                        Operation     = 'Restore'
                        Message       = 'A previously deleted component was restored to Neu and Aktiv.'
                    })
                }
                else {
                    $updated++
                }
            }
            else {
                $unchanged++
            }
            continue
        }

        if (-not $knownEnvironmentIds.Contains($environmentId)) {
            $logs.Add([pscustomobject] [ordered] @{
                Severity      = 'Warning'
                Category      = 'Skipped'
                EnvironmentId = $environmentId
                ComponentType = $ComponentType
                ComponentId   = [string] $source.SourceId
                Operation     = 'Create'
                Message       = "Environment '$environmentId' is not present in palp_environment."
            })
            $skipped++
            continue
        }

        if ($created -ge $CreationCap) {
            $logs.Add([pscustomobject] [ordered] @{
                Severity      = 'Warning'
                Category      = 'Skipped'
                EnvironmentId = $environmentId
                ComponentType = $ComponentType
                ComponentId   = [string] $source.SourceId
                Operation     = 'Create'
                Message       = "Component was not created because the creation cap of $CreationCap was reached."
            })
            $skipped++
            continue
        }

        $writes.Add([pscustomobject] @{
            Method        = 'POST'
            RelativeUri   = 'palp_komponentes'
            Payload       = [pscustomobject] [ordered] @{
                palp_id                       = $componentId
                palp_typ                      = $ComponentType
                palp_titel                    = [string] $source.Title
                palp_besitzerobjectid         = [string] $source.OwnerObjectId
                palp_beschreibung             = $source.Description
                'palp_environment@odata.bind' = "/palp_environments(palp_id='$escapedEnvironmentId')"
                palp_urspruenglicherstelltam  = [string] $source.SourceCreatedAt
                palp_urspruenglichgeaendertam = [string] $source.SourceModifiedAt
                palp_komponentenstatus        = 0
                palp_status                   = 0
                palp_nutzungsbereich          = 0
                palp_letztestatusaenderung    = $Now.ToString('o')
            }
            EnvironmentId = $environmentId
            ComponentType = $ComponentType
            ComponentId   = [string] $source.SourceId
            Operation     = 'Create'
        })
        $created++
    }

    [pscustomobject] @{
        Writes = $writes.ToArray()
        Logs   = $logs.ToArray()
        Counts = [pscustomobject] @{
            Created   = $created
            Updated   = $updated
            Restored  = $restored
            Skipped   = $skipped
            Unchanged = $unchanged
        }
    }
}

function New-AgentComponentCreatePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Agents,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Environments,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ExistingComponentIds,
        [Parameter()] [datetimeoffset] $Now = [datetimeoffset]::UtcNow
    )

    $knownEnvironmentIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($environment in $Environments) {
        if (-not [string]::IsNullOrWhiteSpace([string] $environment.palp_id)) {
            $null = $knownEnvironmentIds.Add(([string] $environment.palp_id).Trim())
        }
    }

    $existingIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($existingId in $ExistingComponentIds) {
        if (-not [string]::IsNullOrWhiteSpace($existingId)) {
            $null = $existingIds.Add($existingId.Trim())
        }
    }

    $writes = [System.Collections.Generic.List[object]]::new()
    $logs = [System.Collections.Generic.List[object]]::new()
    $created = 0
    $skipped = 0
    $unchanged = 0

    foreach ($agent in $Agents) {
        $environmentId = ([string] $agent.environmentId).Trim()
        $sourceId = ([string] $agent.agentId).Trim()
        $componentId = New-InventoryComponentId -EnvironmentId $environmentId `
            -ComponentType 5 -SourceId $sourceId

        if ($existingIds.Contains($componentId)) {
            $unchanged++
            continue
        }

        if (-not $knownEnvironmentIds.Contains($environmentId)) {
            $logs.Add([pscustomobject] [ordered] @{
                Severity      = 'Warning'
                Category      = 'Skipped'
                EnvironmentId = $environmentId
                ComponentType = 5
                ComponentId   = $sourceId
                Operation     = 'Create'
                Message       = "Environment '$environmentId' is not present in palp_environment."
            })
            $skipped++
            continue
        }

        $escapedEnvironmentId = $environmentId.Replace("'", "''")
        $payload = [ordered] @{
            palp_id                       = $componentId
            palp_typ                      = 5
            palp_titel                    = [string] $agent.title
            palp_besitzerobjectid         = [string] $agent.ownerId
            'palp_environment@odata.bind' = "/palp_environments(palp_id='$escapedEnvironmentId')"
            palp_urspruenglicherstelltam  = [string] $agent.createdAt
            palp_urspruenglichgeaendertam = [string] $agent.modifiedAt
            palp_komponentenstatus        = 0
            palp_status                   = 0
            palp_nutzungsbereich          = 0
            palp_letztestatusaenderung    = $Now.ToString('o')
        }
        $writes.Add([pscustomobject] @{
            Method        = 'POST'
            RelativeUri   = 'palp_komponentes'
            Payload       = [pscustomobject] $payload
            EnvironmentId = $environmentId
            ComponentType = 5
            ComponentId   = $sourceId
            Operation     = 'Create'
        })
        $created++
    }

    [pscustomobject] @{
        Writes = $writes.ToArray()
        Logs   = $logs.ToArray()
        Counts = [pscustomobject] @{
            Created   = $created
            Skipped   = $skipped
            Unchanged = $unchanged
        }
    }
}

function Get-InventoryErrorDetails {
    param([Parameter(Mandatory)] [string] $Message)

    $httpStatus = 0
    if ($Message -match '(?i)\bHTTP(?:/1\.[01])?\s+(?<status>[45][0-9]{2})\b') {
        $httpStatus = [int] $Matches.status
    }
    $errorCode = ''
    if ($Message -match '(?i)\b(?<code>0x[0-9a-f]+)\b') {
        $errorCode = [string] $Matches.code
    }
    [pscustomobject] @{
        HttpStatus = $httpStatus
        ErrorCode  = $errorCode
    }
}

function Write-DataverseBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Writes,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $DataverseUrl,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $AccessToken,
        [Parameter()] [ValidateRange(1, 1000)] [int] $BatchSize = 1000
    )

    $baseUrl = $DataverseUrl.TrimEnd('/')
    $batchCount = 0
    $operationCount = 0
    $succeededCount = 0
    $failures = [System.Collections.Generic.List[object]]::new()
    for ($offset = 0; $offset -lt $Writes.Count; $offset += $BatchSize) {
        $lastIndex = [Math]::Min($offset + $BatchSize - 1, $Writes.Count - 1)
        $batchWrites = @($Writes[$offset..$lastIndex])
        $batchBoundary = 'batch_{0}' -f ([guid]::NewGuid().ToString('N'))
        $changeSetBoundary = 'changeset_{0}' -f ([guid]::NewGuid().ToString('N'))
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("--$batchBoundary")
        $lines.Add("Content-Type: multipart/mixed;boundary=$changeSetBoundary")
        $lines.Add('')

        $contentId = 0
        foreach ($write in $batchWrites) {
            $contentId++
            $lines.Add("--$changeSetBoundary")
            $lines.Add('Content-Type: application/http')
            $lines.Add('Content-Transfer-Encoding: binary')
            $lines.Add("Content-ID: $contentId")
            $lines.Add('')
            $lines.Add("$($write.Method) $($write.RelativeUri) HTTP/1.1")
            $lines.Add('Content-Type: application/json;type=entry')
            $lines.Add('Accept: application/json')
            $lines.Add('')
            $lines.Add(($write.Payload | ConvertTo-Json -Depth 100 -Compress))
            $lines.Add('')
        }
        $lines.Add("--$changeSetBoundary--")
        $lines.Add("--$batchBoundary--")
        $lines.Add('')

        $headers = @{
            Authorization = "Bearer $AccessToken"
            Accept        = 'application/json'
        }
        $contentType = "multipart/mixed;boundary=$batchBoundary"
        $body = $lines -join "`r`n"
        try {
            $response = Invoke-InventoryHttpRequest -Uri "$baseUrl/api/data/v9.2/`$batch" `
                -Method POST -Headers $headers -ContentType $contentType -Body $body
            if ($response.Body -is [string] -and
                $response.Body -match '(?im)^HTTP/1\.[01]\s+[45][0-9]{2}\b') {
                throw "Dataverse batch contained a failed operation: $($response.Body)"
            }
            $succeededCount += $batchWrites.Count
        }
        catch {
            $errorDetails = Get-InventoryErrorDetails -Message $_.Exception.Message
            foreach ($write in $batchWrites) {
                $failures.Add([pscustomobject] @{
                    EnvironmentId = [string] $write.EnvironmentId
                    ComponentType = [int] $write.ComponentType
                    ComponentId   = [string] $write.ComponentId
                    Operation     = [string] $write.Operation
                    HttpStatus    = $errorDetails.HttpStatus
                    ErrorCode     = $errorDetails.ErrorCode
                    Message       = $_.Exception.Message
                })
            }
        }
        $batchCount++
        $operationCount += $batchWrites.Count
    }

    [pscustomobject] @{
        Batches    = $batchCount
        Operations = $operationCount
        Succeeded  = $succeededCount
        Failed     = $failures.Count
        Failures   = $failures.ToArray()
    }
}
