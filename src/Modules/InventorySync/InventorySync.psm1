Set-StrictMode -Version Latest

$script:TokenCache = @{}
$script:TokenRefreshBuffer = [timespan]::FromMinutes(5)

function Get-InventorySyncConfiguration {
    [CmdletBinding()]
    param(
        [Parameter()]
        [System.Collections.IDictionary] $Settings = [System.Environment]::GetEnvironmentVariables()
    )

    $requiredSettings = [ordered]@{
        INVENTORY_TENANT_ID                   = 'TenantId'
        INVENTORY_CLIENT_ID                   = 'ClientId'
        INVENTORY_CLIENT_SECRET               = 'ClientSecret'
        INVENTORY_TARGET_DATAVERSE_URL        = 'TargetDataverseUrl'
        INVENTORY_AGENT_CREATED_IN            = 'AgentCreatedIn'
        APPLICATIONINSIGHTS_CONNECTION_STRING = 'ApplicationInsightsConnectionString'
    }

    $missing = @(
        foreach ($settingName in $requiredSettings.Keys) {
            if (-not $Settings.Contains($settingName) -or [string]::IsNullOrWhiteSpace([string] $Settings[$settingName])) {
                $settingName
            }
        }
    )

    if ($missing.Count -gt 0) {
        throw "Missing required app settings: $($missing -join ', ')."
    }

    $configuration = [ordered]@{}
    foreach ($entry in $requiredSettings.GetEnumerator()) {
        $configuration[$entry.Value] = ([string] $Settings[$entry.Key]).Trim()
    }
    $configuration.TargetDataverseUrl = $configuration.TargetDataverseUrl.TrimEnd('/')
    $configuration.AgentSchedule = if (
        $Settings.Contains('INVENTORY_AGENT_SCHEDULE') -and
        -not [string]::IsNullOrWhiteSpace([string] $Settings['INVENTORY_AGENT_SCHEDULE'])
    ) {
        ([string] $Settings['INVENTORY_AGENT_SCHEDULE']).Trim()
    }
    else {
        '0 0 0 * * *'
    }
    $configuration.AgentSubscriptions = if (
        $Settings.Contains('INVENTORY_AGENT_SUBSCRIPTIONS') -and
        -not [string]::IsNullOrWhiteSpace([string] $Settings['INVENTORY_AGENT_SUBSCRIPTIONS'])
    ) {
        @(
            ([string] $Settings['INVENTORY_AGENT_SUBSCRIPTIONS']).Split(',') |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }
    else {
        @()
    }
    $configuration.MaxCreatesPerRun = 1000
    if (
        $Settings.Contains('INVENTORY_MAX_CREATES_PER_RUN') -and
        -not [string]::IsNullOrWhiteSpace([string] $Settings['INVENTORY_MAX_CREATES_PER_RUN'])
    ) {
        $configuredCap = 0
        if (
            -not [int]::TryParse([string] $Settings['INVENTORY_MAX_CREATES_PER_RUN'], [ref] $configuredCap) -or
            $configuredCap -lt 0
        ) {
            throw 'INVENTORY_MAX_CREATES_PER_RUN must be a non-negative integer.'
        }
        $configuration.MaxCreatesPerRun = $configuredCap
    }

    [pscustomobject] $configuration
}

function Get-ResponseHeaderValue {
    param(
        [Parameter(Mandatory)] $Headers,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($Headers -is [System.Collections.IDictionary]) {
        foreach ($key in $Headers.Keys) {
            if ([string] $key -ieq $Name) {
                return [string] $Headers[$key]
            }
        }
        return $null
    }

    try {
        $values = $Headers.GetValues($Name)
        if ($null -ne $values) {
            return [string] ($values | Select-Object -First 1)
        }
    }
    catch {
        return $null
    }
}

function Get-RetryDelaySeconds {
    param(
        [Parameter(Mandatory)] $Headers,
        [Parameter(Mandatory)] [int] $RetryNumber
    )

    $retryAfter = Get-ResponseHeaderValue -Headers $Headers -Name 'Retry-After'
    $seconds = 0.0
    if ([double]::TryParse(
            $retryAfter,
            [System.Globalization.NumberStyles]::Number,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref] $seconds
        )) {
        return [Math]::Max(0, $seconds)
    }

    $retryAt = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse(
            $retryAfter,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal,
            [ref] $retryAt
        )) {
        return [Math]::Max(0, ($retryAt - [datetimeoffset]::UtcNow).TotalSeconds)
    }

    [Math]::Min(60, [Math]::Pow(2, $RetryNumber - 1))
}

function ConvertFrom-InventoryJson {
    param([AllowNull()] [string] $Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $null
    }

    try {
        return $Content | ConvertFrom-Json -Depth 100
    }
    catch {
        return $Content
    }
}

function Invoke-InventoryHttpRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [uri] $Uri,
        [Parameter()] [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')] [string] $Method = 'GET',
        [Parameter()] [System.Collections.IDictionary] $Headers = @{},
        [Parameter()] [AllowNull()] $Body,
        [Parameter()] [string] $ContentType = 'application/json',
        [Parameter()] [ValidateRange(0, 10)] [int] $MaxRetryCount = 3,
        [Parameter()] [ValidateRange(1, 600)] [int] $TimeoutSec = 100,
        [Parameter()] [scriptblock] $Invoker = {
            param($request)
            Invoke-WebRequest @request -SkipHttpErrorCheck
        },
        [Parameter()] [scriptblock] $SleepAction = {
            param([double] $seconds)
            Start-Sleep -Seconds $seconds
        }
    )

    $request = @{
        Uri         = $Uri
        Method      = $Method
        Headers     = $Headers
        ContentType = $ContentType
        TimeoutSec  = $TimeoutSec
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $request.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 100 -Compress }
    }

    for ($attempt = 1; $attempt -le ($MaxRetryCount + 1); $attempt++) {
        try {
            $rawResponse = & $Invoker $request
        }
        catch {
            throw "HTTP request to '$Uri' failed before a response was received: $($_.Exception.Message)"
        }

        $statusCode = [int] $rawResponse.StatusCode
        $content = [string] $rawResponse.Content
        $bodyValue = ConvertFrom-InventoryJson -Content $content

        if ($statusCode -ge 200 -and $statusCode -lt 300) {
            return [pscustomobject] @{
                StatusCode = $statusCode
                Headers    = $rawResponse.Headers
                Body       = $bodyValue
            }
        }

        $isServiceProtection = $content -match '0x800723(?:21|22|26)'
        $isRetryable = $statusCode -eq 429 -or $isServiceProtection
        if ($isRetryable -and $attempt -le $MaxRetryCount) {
            $delay = Get-RetryDelaySeconds -Headers $rawResponse.Headers -RetryNumber $attempt
            & $SleepAction $delay
            continue
        }

        $errorMessage = $null
        if ($null -ne $bodyValue -and $bodyValue -isnot [string]) {
            $errorProperty = $bodyValue.PSObject.Properties['error']
            if ($null -ne $errorProperty -and $null -ne $errorProperty.Value) {
                $messageProperty = $errorProperty.Value.PSObject.Properties['message']
                if ($null -ne $messageProperty) {
                    $errorMessage = [string] $messageProperty.Value
                }
            }
            if ([string]::IsNullOrWhiteSpace($errorMessage)) {
                $titleProperty = $bodyValue.PSObject.Properties['title']
                if ($null -ne $titleProperty) {
                    $errorMessage = [string] $titleProperty.Value
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($errorMessage)) {
            $errorMessage = if (-not [string]::IsNullOrWhiteSpace($content)) {
                $content
            }
            else {
                'The service returned no error details.'
            }
        }
        throw "HTTP $statusCode from '$Uri': $errorMessage"
    }
}

function Clear-InventoryTokenCache {
    [CmdletBinding()]
    param()

    $script:TokenCache.Clear()
}

function ConvertTo-FormValue {
    param([Parameter(Mandatory)] [string] $Value)

    [System.Net.WebUtility]::UrlEncode($Value)
}

function Get-InventoryAccessToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Resource,
        [Parameter(Mandatory)] [psobject] $Configuration,
        [Parameter()] [datetimeoffset] $Now = [datetimeoffset]::UtcNow
    )

    $normalizedResource = $Resource.Trim().TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($normalizedResource)) {
        throw 'Resource must not be empty.'
    }

    $cacheKey = "$($Configuration.TenantId)|$($Configuration.ClientId)|$($normalizedResource.ToLowerInvariant())"
    if ($script:TokenCache.ContainsKey($cacheKey)) {
        $cachedToken = $script:TokenCache[$cacheKey]
        if ($Now -lt ($cachedToken.ExpiresOn - $script:TokenRefreshBuffer)) {
            return $cachedToken.AccessToken
        }
    }

    $tokenUri = "https://login.microsoftonline.com/$($Configuration.TenantId)/oauth2/v2.0/token"
    $formFields = [ordered]@{
        client_id     = [string] $Configuration.ClientId
        client_secret = [string] $Configuration.ClientSecret
        grant_type    = 'client_credentials'
        scope         = "$normalizedResource/.default"
    }
    $formBody = @(
        foreach ($entry in $formFields.GetEnumerator()) {
            '{0}={1}' -f (ConvertTo-FormValue $entry.Key), (ConvertTo-FormValue $entry.Value)
        }
    ) -join '&'

    $response = Invoke-InventoryHttpRequest -Uri $tokenUri -Method POST `
        -ContentType 'application/x-www-form-urlencoded' -Body $formBody
    if ($null -eq $response.Body -or [string]::IsNullOrWhiteSpace([string] $response.Body.access_token)) {
        throw "Token endpoint '$tokenUri' returned no access token."
    }

    $expiresIn = 3600
    if ($null -ne $response.Body.expires_in) {
        $expiresIn = [int] $response.Body.expires_in
    }
    if ($expiresIn -le 0) {
        throw "Token endpoint '$tokenUri' returned an invalid expiry."
    }

    $script:TokenCache[$cacheKey] = [pscustomobject] @{
        AccessToken = [string] $response.Body.access_token
        ExpiresOn   = $Now.AddSeconds($expiresIn)
    }

    [string] $response.Body.access_token
}

function Get-DataversePagedRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [uri] $Uri,
        [Parameter(Mandatory)] [string] $AccessToken
    )

    $headers = @{
        Authorization    = "Bearer $AccessToken"
        Accept           = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version'  = '4.0'
    }
    $nextUri = [string] $Uri
    $visitedUris = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    while (-not [string]::IsNullOrWhiteSpace($nextUri)) {
        if (-not $visitedUris.Add($nextUri)) {
            throw "Dataverse returned a repeated @odata.nextLink: '$nextUri'."
        }

        $response = Invoke-InventoryHttpRequest -Uri $nextUri -Headers $headers
        foreach ($record in @($response.Body.value)) {
            $record
        }

        $nextLinkProperty = $response.Body.PSObject.Properties['@odata.nextLink']
        $nextUri = if ($null -ne $nextLinkProperty) { [string] $nextLinkProperty.Value } else { $null }
    }
}

function Invoke-ResourceGraphPagedQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Query,
        [Parameter()] [AllowEmptyCollection()] [string[]] $Subscriptions = @(),
        [Parameter(Mandatory)] [string] $AccessToken
    )

    $uri = 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2024-04-01'
    $headers = @{
        Authorization = "Bearer $AccessToken"
        Accept        = 'application/json'
    }
    $skipToken = $null
    $seenTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    do {
        $options = [ordered]@{
            resultFormat = 'objectArray'
        }
        if (-not [string]::IsNullOrWhiteSpace($skipToken)) {
            $options['$skipToken'] = $skipToken
        }
        $requestBody = [ordered]@{
            query   = $Query
            options = [pscustomobject] $options
        }
        if ($Subscriptions.Count -gt 0) {
            $requestBody['subscriptions'] = $Subscriptions
        }

        $response = Invoke-InventoryHttpRequest -Uri $uri -Method POST -Headers $headers -Body $requestBody
        foreach ($record in @($response.Body.data)) {
            $record
        }

        $skipTokenProperty = $response.Body.PSObject.Properties['$skipToken']
        $skipToken = if ($null -ne $skipTokenProperty) { [string] $skipTokenProperty.Value } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($skipToken) -and -not $seenTokens.Add($skipToken)) {
            throw "Resource Graph returned a repeated `$skipToken: '$skipToken'."
        }
    } while (-not [string]::IsNullOrWhiteSpace($skipToken))
}

function Get-AgentBuilderAgents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $CreatedIn,
        [Parameter()] [AllowEmptyCollection()] [string[]] $Subscriptions = @(),
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $AccessToken
    )

    $createdInLiteral = $CreatedIn.Replace('\', '\\').Replace('"', '\"')
    $query = @"
PowerPlatformResources
| where type =~ "microsoft.copilotstudio/agents"
| extend properties = parse_json(properties)
| where tostring(properties.createdIn) == "$createdInLiteral"
| project agentId = tostring(name),
          title = tostring(properties.displayName),
          description = tostring(properties.description),
          environmentId = tostring(properties.environmentId),
          ownerId = tostring(properties.ownerId),
          createdAt = todatetime(properties.createdAt),
          modifiedAt = todatetime(properties.lastModifiedAt)
"@

    Invoke-ResourceGraphPagedQuery -Query $query -Subscriptions $Subscriptions -AccessToken $AccessToken
}

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

            if ($payload.Count -gt 0) {
                $escapedComponentId = $componentId.Replace("'", "''")
                $writes.Add([pscustomobject] @{
                    Method      = 'PATCH'
                    RelativeUri = "palp_komponentes(palp_id='$escapedComponentId')"
                    Payload     = [pscustomobject] $payload
                })
                $updated++
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
            Method      = 'POST'
            RelativeUri = 'palp_komponentes'
            Payload     = [pscustomobject] [ordered] @{
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
        })
        $created++
    }

    [pscustomobject] @{
        Writes = $writes.ToArray()
        Logs   = $logs.ToArray()
        Counts = [pscustomobject] @{
            Created   = $created
            Updated   = $updated
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
            Method      = 'POST'
            RelativeUri = 'palp_komponentes'
            Payload     = [pscustomobject] $payload
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
        Invoke-InventoryHttpRequest -Uri "$baseUrl/api/data/v9.2/`$batch" -Method POST `
            -Headers $headers -ContentType $contentType -Body $body | Out-Null
        $batchCount++
        $operationCount += $batchWrites.Count
    }

    [pscustomobject] @{
        Batches    = $batchCount
        Operations = $operationCount
    }
}

function Invoke-AgentCreateSync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Configuration,
        [Parameter()] [string] $ResourceGraphAccessToken,
        [Parameter()] [string] $DataverseAccessToken,
        [Parameter()] [datetimeoffset] $Now = [datetimeoffset]::UtcNow,
        [Parameter()] [string] $CorrelationId = ([guid]::NewGuid().ToString())
    )

    if ([string]::IsNullOrWhiteSpace($ResourceGraphAccessToken)) {
        $ResourceGraphAccessToken = Get-InventoryAccessToken `
            -Resource 'https://management.azure.com' -Configuration $Configuration
    }
    if ([string]::IsNullOrWhiteSpace($DataverseAccessToken)) {
        $DataverseAccessToken = Get-InventoryAccessToken `
            -Resource $Configuration.TargetDataverseUrl -Configuration $Configuration
    }

    $agents = @(Get-AgentBuilderAgents -CreatedIn $Configuration.AgentCreatedIn `
        -Subscriptions @($Configuration.AgentSubscriptions) -AccessToken $ResourceGraphAccessToken)
    $baseUrl = $Configuration.TargetDataverseUrl.TrimEnd('/')
    $environments = @(Get-DataversePagedRecords `
        -Uri "$baseUrl/api/data/v9.2/palp_environments?`$select=palp_id" `
        -AccessToken $DataverseAccessToken)
    $existingComponents = @(Get-DataversePagedRecords `
        -Uri "$baseUrl/api/data/v9.2/palp_komponentes?`$select=palp_id&`$filter=palp_typ%20eq%205" `
        -AccessToken $DataverseAccessToken)
    $existingIds = @($existingComponents | ForEach-Object { [string] $_.palp_id })
    $plan = New-AgentComponentCreatePlan -Agents $agents -Environments $environments `
        -ExistingComponentIds $existingIds -Now $Now

    foreach ($logEntry in $plan.Logs) {
        Write-InventoryTrace -Level $logEntry.Severity -Message $logEntry.Message `
            -CorrelationId $CorrelationId -Data @{
                category      = $logEntry.Category
                environmentId = $logEntry.EnvironmentId
                componentType = $logEntry.ComponentType
                componentId   = $logEntry.ComponentId
                operation     = $logEntry.Operation
            }
    }

    $batch = Write-DataverseBatch -Writes $plan.Writes -DataverseUrl $baseUrl `
        -AccessToken $DataverseAccessToken
    [pscustomobject] @{
        Counts = [pscustomobject] @{
            Found     = $agents.Count
            Created   = $plan.Counts.Created
            Skipped   = $plan.Counts.Skipped
            Unchanged = $plan.Counts.Unchanged
        }
        Logs  = $plan.Logs
        Batch = $batch
    }
}

function Invoke-AgentSync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Configuration,
        [Parameter()] [string] $ResourceGraphAccessToken,
        [Parameter()] [string] $DataverseAccessToken,
        [Parameter()] [datetimeoffset] $Now = [datetimeoffset]::UtcNow,
        [Parameter()] [string] $CorrelationId = ([guid]::NewGuid().ToString())
    )

    if ([string]::IsNullOrWhiteSpace($ResourceGraphAccessToken)) {
        $ResourceGraphAccessToken = Get-InventoryAccessToken `
            -Resource 'https://management.azure.com' -Configuration $Configuration
    }
    if ([string]::IsNullOrWhiteSpace($DataverseAccessToken)) {
        $DataverseAccessToken = Get-InventoryAccessToken `
            -Resource $Configuration.TargetDataverseUrl -Configuration $Configuration
    }

    $agents = @(Get-AgentBuilderAgents -CreatedIn $Configuration.AgentCreatedIn `
        -Subscriptions @($Configuration.AgentSubscriptions) -AccessToken $ResourceGraphAccessToken)
    $sourceComponents = @(
        foreach ($agent in $agents) {
            $descriptionProperty = $agent.PSObject.Properties['description']
            [pscustomobject] @{
                SourceId         = [string] $agent.agentId
                EnvironmentId    = [string] $agent.environmentId
                Title            = [string] $agent.title
                OwnerObjectId    = [string] $agent.ownerId
                Description      = if ($null -ne $descriptionProperty) {
                    $descriptionProperty.Value
                }
                else {
                    $null
                }
                SourceCreatedAt  = [string] $agent.createdAt
                SourceModifiedAt = [string] $agent.modifiedAt
            }
        }
    )

    $baseUrl = $Configuration.TargetDataverseUrl.TrimEnd('/')
    $environments = @(Get-DataversePagedRecords `
        -Uri "$baseUrl/api/data/v9.2/palp_environments?`$select=palp_id" `
        -AccessToken $DataverseAccessToken)
    $componentQuery = 'palp_komponentes?' +
        '$select=palp_id,palp_typ,palp_titel,palp_besitzerobjectid,palp_beschreibung,' +
        'palp_urspruenglicherstelltam,palp_urspruenglichgeaendertam' +
        '&$expand=palp_environment($select=palp_id)&$filter=palp_typ%20eq%205'
    $existingComponents = @(Get-DataversePagedRecords `
        -Uri "$baseUrl/api/data/v9.2/$componentQuery" -AccessToken $DataverseAccessToken)
    $capProperty = $Configuration.PSObject.Properties['MaxCreatesPerRun']
    $creationCap = if ($null -ne $capProperty) { [int] $capProperty.Value } else { 1000 }
    $plan = New-InventoryComponentReconciliationPlan `
        -SourceComponents $sourceComponents -Environments $environments `
        -ExistingComponents $existingComponents -ComponentType 5 `
        -CreationCap $creationCap -Now $Now

    foreach ($logEntry in $plan.Logs) {
        Write-InventoryTrace -Level $logEntry.Severity -Message $logEntry.Message `
            -CorrelationId $CorrelationId -Data @{
                category      = $logEntry.Category
                environmentId = $logEntry.EnvironmentId
                componentType = $logEntry.ComponentType
                componentId   = $logEntry.ComponentId
                operation     = $logEntry.Operation
            }
    }

    $batch = Write-DataverseBatch -Writes $plan.Writes -DataverseUrl $baseUrl `
        -AccessToken $DataverseAccessToken
    [pscustomobject] @{
        Counts = [pscustomobject] @{
            Found     = $agents.Count
            Created   = $plan.Counts.Created
            Updated   = $plan.Counts.Updated
            Skipped   = $plan.Counts.Skipped
            Unchanged = $plan.Counts.Unchanged
        }
        Logs  = $plan.Logs
        Batch = $batch
    }
}

function Write-InventoryTrace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Information', 'Warning', 'Error')] [string] $Level,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Message,
        [Parameter()] [AllowEmptyString()] [string] $CorrelationId,
        [Parameter()] [System.Collections.IDictionary] $Data = @{}
    )

    $record = [ordered]@{
        timestamp     = [datetimeoffset]::UtcNow.ToString('o')
        level         = $Level
        message       = $Message
        correlationId = $CorrelationId
        data          = $Data
    }
    $json = $record | ConvertTo-Json -Depth 20 -Compress

    switch ($Level) {
        'Information' { Write-Information -MessageData $json -Tags 'InventorySync' }
        'Warning' { Write-Warning -Message $json }
        'Error' { Write-Error -Message $json -ErrorId 'InventorySync' -Category NotSpecified }
    }
}
