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
    $configuration.SyncRunTable = if (
        $Settings.Contains('INVENTORY_SYNC_RUN_TABLE') -and
        -not [string]::IsNullOrWhiteSpace([string] $Settings['INVENTORY_SYNC_RUN_TABLE'])
    ) {
        ([string] $Settings['INVENTORY_SYNC_RUN_TABLE']).Trim()
    }
    else {
        'invs_syncruns'
    }
    $configuration.SyncLogTable = if (
        $Settings.Contains('INVENTORY_SYNC_LOG_TABLE') -and
        -not [string]::IsNullOrWhiteSpace([string] $Settings['INVENTORY_SYNC_LOG_TABLE'])
    ) {
        ([string] $Settings['INVENTORY_SYNC_LOG_TABLE']).Trim()
    }
    else {
        'invs_synclogs'
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

function Start-InventorySyncRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $DataverseUrl,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $AccessToken,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $TableName,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
        [Parameter(Mandatory)] [ValidateSet('RPA', 'AgentBuilder')] [string] $SyncType,
        [Parameter()] [datetimeoffset] $StartedOn = [datetimeoffset]::UtcNow
    )

    $recordId = [guid]::NewGuid().ToString()
    try {
        if ($TableName -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
            throw "Invalid Sync Run table name '$TableName'."
        }

        $payload = [ordered] @{
            invs_syncrunid         = $recordId
            invs_name              = "$SyncType $($StartedOn.ToString('u'))"
            invs_runid             = $RunId
            invs_synctype          = if ($SyncType -eq 'RPA') { 100000000 } else { 100000001 }
            invs_phase             = 100000000
            invs_startedon         = $StartedOn.ToString('o')
            invs_status            = 100000000
            invs_environmentstotal = 0
            invs_environmentsfailed = 0
            invs_found             = 0
            invs_created           = 0
            invs_updated           = 0
            invs_unchanged         = 0
            invs_markeddeleted     = 0
            invs_restored          = 0
            invs_errors            = 0
        }
        $headers = @{
            Authorization = "******"
            Accept        = 'application/json'
        }
        $baseUrl = $DataverseUrl.TrimEnd('/')
        Invoke-InventoryHttpRequest -Uri "$baseUrl/api/data/v9.2/$TableName" -Method POST `
            -Headers $headers -Body $payload | Out-Null
        [pscustomobject] @{
            Persisted = $true
            RecordId  = $recordId
            Error     = $null
        }
    }
    catch {
        Write-InventoryTrace -Level Warning -Message 'Sync Run could not be written to Dataverse; continuing with Application Insights only.' `
            -CorrelationId $RunId -Data @{
                category  = 'WriteFailed'
                operation = 'CreateSyncRun'
                error     = $_.Exception.Message
            }
        [pscustomobject] @{
            Persisted = $false
            RecordId  = $recordId
            Error     = $_.Exception.Message
        }
    }
}

function Complete-InventorySyncRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $DataverseUrl,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $AccessToken,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $TableName,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RecordId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
        [Parameter(Mandatory)] [ValidateSet('Collect', 'Write', 'DeletionCheck')] [string] $Phase,
        [Parameter(Mandatory)] [ValidateSet('Running', 'Succeeded', 'Partial', 'Failed')] [string] $Status,
        [Parameter(Mandatory)] [psobject] $Counts,
        [Parameter()] [datetimeoffset] $CompletedOn = [datetimeoffset]::UtcNow
    )

    try {
        if ($TableName -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
            throw "Invalid Sync Run table name '$TableName'."
        }
        if ($RecordId -notmatch '^[0-9a-fA-F-]{36}$') {
            throw "Invalid Sync Run record ID '$RecordId'."
        }

        $phaseValue = switch ($Phase) {
            'Collect' { 100000000 }
            'Write' { 100000001 }
            'DeletionCheck' { 100000002 }
        }
        $statusValue = switch ($Status) {
            'Running' { 100000000 }
            'Succeeded' { 100000001 }
            'Partial' { 100000002 }
            'Failed' { 100000003 }
        }
        $payload = [ordered] @{
            invs_phase              = $phaseValue
            invs_completedon        = $CompletedOn.ToString('o')
            invs_status             = $statusValue
            invs_environmentstotal  = [int] $Counts.EnvironmentsTotal
            invs_environmentsfailed = [int] $Counts.EnvironmentsFailed
            invs_found              = [int] $Counts.Found
            invs_created            = [int] $Counts.Created
            invs_updated            = [int] $Counts.Updated
            invs_unchanged          = [int] $Counts.Unchanged
            invs_markeddeleted      = [int] $Counts.MarkedDeleted
            invs_restored           = [int] $Counts.Restored
            invs_errors             = [int] $Counts.Errors
        }
        $headers = @{
            Authorization = "******"
            Accept        = 'application/json'
        }
        $baseUrl = $DataverseUrl.TrimEnd('/')
        Invoke-InventoryHttpRequest -Uri "$baseUrl/api/data/v9.2/$TableName($RecordId)" `
            -Method PATCH -Headers $headers -Body $payload | Out-Null
        [pscustomobject] @{ Persisted = $true; Error = $null }
    }
    catch {
        Write-InventoryTrace -Level Warning -Message 'Sync Run completion could not be written to Dataverse; continuing with Application Insights only.' `
            -CorrelationId $RunId -Data @{
                category  = 'WriteFailed'
                operation = 'CompleteSyncRun'
                error     = $_.Exception.Message
            }
        [pscustomobject] @{ Persisted = $false; Error = $_.Exception.Message }
    }
}

function Write-InventorySyncLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $DataverseUrl,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $AccessToken,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $TableName,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SyncRunTableName,
        [Parameter()] [AllowEmptyString()] [string] $RunRecordId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $CorrelationId,
        [Parameter(Mandatory)] [ValidateSet('Warning', 'Error')] [string] $Severity,
        [Parameter(Mandatory)] [ValidateSet(
            'EnvironmentUnreachable', 'PermissionDenied', 'Throttled', 'ReadFailed',
            'WriteFailed', 'VerifyFailed', 'Config', 'RunSkipped', 'Restored', 'Skipped'
        )] [string] $Category,
        [Parameter()] [AllowEmptyString()] [string] $EnvironmentId,
        [Parameter()] [AllowEmptyString()] [string] $EnvironmentName,
        [Parameter()] [int] $ComponentType,
        [Parameter()] [AllowEmptyString()] [string] $ComponentId,
        [Parameter()] [AllowEmptyString()] [string] $Operation,
        [Parameter()] [int] $HttpStatus,
        [Parameter()] [AllowEmptyString()] [string] $ErrorCode,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Message,
        [Parameter()] [datetimeoffset] $OccurredOn = [datetimeoffset]::UtcNow
    )

    $traceData = [ordered] @{
        category        = $Category
        environmentId   = $EnvironmentId
        environmentName = $EnvironmentName
        componentType   = $ComponentType
        componentId     = $ComponentId
        operation       = $Operation
        httpStatus      = $HttpStatus
        errorCode       = $ErrorCode
    }
    Write-InventoryTrace -Level $Severity -Message $Message -CorrelationId $CorrelationId `
        -Data $traceData -ErrorAction Continue

    try {
        if ($TableName -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
            throw "Invalid Sync Log table name '$TableName'."
        }
        if ($SyncRunTableName -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
            throw "Invalid Sync Run table name '$SyncRunTableName'."
        }
        if ($RunRecordId -notmatch '^[0-9a-fA-F-]{36}$') {
            throw 'The Sync Run header was not persisted.'
        }

        $categoryValue = switch ($Category) {
            'EnvironmentUnreachable' { 100000000 }
            'PermissionDenied' { 100000001 }
            'Throttled' { 100000002 }
            'ReadFailed' { 100000003 }
            'WriteFailed' { 100000004 }
            'VerifyFailed' { 100000005 }
            'Config' { 100000006 }
            'RunSkipped' { 100000007 }
            'Restored' { 100000008 }
            'Skipped' { 100000009 }
        }
        $payload = [ordered] @{
            invs_synclogid                   = [guid]::NewGuid().ToString()
            'invs_syncrunid@odata.bind'      = "/$SyncRunTableName($RunRecordId)"
            invs_severity                    = if ($Severity -eq 'Warning') { 100000000 } else { 100000001 }
            invs_category                    = $categoryValue
            invs_environmentid               = $EnvironmentId
            invs_environmentname             = $EnvironmentName
            invs_componenttype               = $ComponentType
            invs_componentid                 = $ComponentId
            invs_operation                   = $Operation
            invs_httpstatus                  = $HttpStatus
            invs_errorcode                   = $ErrorCode
            invs_errormessage                = $Message
            invs_occurredon                  = $OccurredOn.ToString('o')
            invs_correlationid               = $CorrelationId
        }
        $headers = @{
            Authorization = "******"
            Accept        = 'application/json'
        }
        $baseUrl = $DataverseUrl.TrimEnd('/')
        Invoke-InventoryHttpRequest -Uri "$baseUrl/api/data/v9.2/$TableName" -Method POST `
            -Headers $headers -Body $payload | Out-Null
        [pscustomobject] @{ Persisted = $true; Error = $null }
    }
    catch {
        Write-InventoryTrace -Level Warning -Message 'Sync Log could not be written to Dataverse; continuing with Application Insights only.' `
            -CorrelationId $CorrelationId -Data @{
                category  = 'WriteFailed'
                operation = 'CreateSyncLog'
                error     = $_.Exception.Message
            }
        [pscustomobject] @{ Persisted = $false; Error = $_.Exception.Message }
    }
}

function Write-AgentSyncSkippedRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Configuration,
        [Parameter()] [string] $DataverseAccessToken,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $CorrelationId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $InstanceId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RuntimeStatus,
        [Parameter()] [datetimeoffset] $Now = [datetimeoffset]::UtcNow
    )

    $message = "Agent sync start skipped because singleton '$InstanceId' is $RuntimeStatus."
    $counts = [pscustomobject] @{
        EnvironmentsTotal  = 0
        EnvironmentsFailed = 0
        Found              = 0
        Created            = 0
        Updated            = 0
        Unchanged          = 0
        MarkedDeleted      = 0
        Restored           = 0
        Errors             = 1
        Skipped            = 1
    }
    try {
        if ([string]::IsNullOrWhiteSpace($DataverseAccessToken)) {
            $DataverseAccessToken = Get-InventoryAccessToken `
                -Resource $Configuration.TargetDataverseUrl -Configuration $Configuration
        }
        $runHeader = Start-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
            -AccessToken $DataverseAccessToken -TableName $Configuration.SyncRunTable `
            -RunId $CorrelationId -SyncType AgentBuilder -StartedOn $Now
        Write-InventorySyncLog -DataverseUrl $Configuration.TargetDataverseUrl `
            -AccessToken $DataverseAccessToken -TableName $Configuration.SyncLogTable `
            -SyncRunTableName $Configuration.SyncRunTable `
            -RunRecordId $(if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }) `
            -CorrelationId $CorrelationId -Severity Warning -Category RunSkipped `
            -Operation Start -Message $message | Out-Null
        if ($runHeader.Persisted) {
            Complete-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
                -AccessToken $DataverseAccessToken -TableName $Configuration.SyncRunTable `
                -RecordId $runHeader.RecordId -RunId $CorrelationId -Phase Collect `
                -Status Partial -Counts $counts -CompletedOn $Now | Out-Null
        }
    }
    catch {
        Write-InventoryTrace -Level Warning -Message $message -CorrelationId $CorrelationId `
            -Data @{
                category      = 'RunSkipped'
                instanceId    = $InstanceId
                runtimeStatus = $RuntimeStatus
                loggingError  = $_.Exception.Message
            }
    }

    [pscustomobject] @{
        CorrelationId = $CorrelationId
        Status        = 'Partial'
        Counts        = $counts
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

    $syncRunTableProperty = $Configuration.PSObject.Properties['SyncRunTable']
    $syncLogTableProperty = $Configuration.PSObject.Properties['SyncLogTable']
    $loggingConfigured = $null -ne $syncRunTableProperty -and
        $null -ne $syncLogTableProperty -and
        -not [string]::IsNullOrWhiteSpace([string] $syncRunTableProperty.Value) -and
        -not [string]::IsNullOrWhiteSpace([string] $syncLogTableProperty.Value)
    $runHeader = if ($loggingConfigured) {
        Start-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
            -AccessToken $DataverseAccessToken -TableName ([string] $syncRunTableProperty.Value) `
            -RunId $CorrelationId -SyncType AgentBuilder -StartedOn $Now
    }
    else {
        [pscustomobject] @{ Persisted = $false; RecordId = ''; Error = $null }
    }

    $phase = 'Collect'
    $counts = [pscustomobject] @{
        EnvironmentsTotal  = 0
        EnvironmentsFailed = 0
        Found              = 0
        Created            = 0
        Updated            = 0
        Unchanged          = 0
        MarkedDeleted      = 0
        Restored           = 0
        Errors             = 0
        Skipped            = 0
    }
    try {
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
        if ($loggingConfigured) {
            Write-InventorySyncLog -DataverseUrl $Configuration.TargetDataverseUrl `
                -AccessToken $DataverseAccessToken -TableName ([string] $syncLogTableProperty.Value) `
                -SyncRunTableName ([string] $syncRunTableProperty.Value) `
                -RunRecordId $(if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }) `
                -CorrelationId $CorrelationId -Severity $logEntry.Severity `
                -Category $logEntry.Category -EnvironmentId $logEntry.EnvironmentId `
                -ComponentType $logEntry.ComponentType -ComponentId $logEntry.ComponentId `
                -Operation $logEntry.Operation -Message $logEntry.Message | Out-Null
        }
        else {
            Write-InventoryTrace -Level $logEntry.Severity -Message $logEntry.Message `
                -CorrelationId $CorrelationId -Data @{
                    category      = $logEntry.Category
                    environmentId = $logEntry.EnvironmentId
                    componentType = $logEntry.ComponentType
                    componentId   = $logEntry.ComponentId
                    operation     = $logEntry.Operation
                }
        }
    }

    $phase = 'Write'
    $batch = Write-DataverseBatch -Writes $plan.Writes -DataverseUrl $baseUrl `
        -AccessToken $DataverseAccessToken

    foreach ($failure in $batch.Failures) {
        if ($loggingConfigured) {
            Write-InventorySyncLog -DataverseUrl $Configuration.TargetDataverseUrl `
                -AccessToken $DataverseAccessToken -TableName ([string] $syncLogTableProperty.Value) `
                -SyncRunTableName ([string] $syncRunTableProperty.Value) `
                -RunRecordId $(if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }) `
                -CorrelationId $CorrelationId -Severity Error -Category WriteFailed `
                -EnvironmentId $failure.EnvironmentId -ComponentType $failure.ComponentType `
                -ComponentId $failure.ComponentId -Operation $failure.Operation `
                -HttpStatus $failure.HttpStatus -ErrorCode $failure.ErrorCode `
                -Message $failure.Message | Out-Null
        }
        else {
            Write-InventoryTrace -Level Error -Message $failure.Message `
                -CorrelationId $CorrelationId -Data @{
                    category      = 'WriteFailed'
                    environmentId = $failure.EnvironmentId
                    componentType = $failure.ComponentType
                    componentId   = $failure.ComponentId
                    operation     = $failure.Operation
                    httpStatus    = $failure.HttpStatus
                    errorCode     = $failure.ErrorCode
                }
        }
    }

    $environmentIds = @(
        $agents |
            ForEach-Object { ([string] $_.environmentId).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    $failedEnvironmentIds = @(
        @($plan.Logs) + @($batch.Failures) |
            ForEach-Object { ([string] $_.EnvironmentId).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    $counts = [pscustomobject] @{
        EnvironmentsTotal  = $environmentIds.Count
        EnvironmentsFailed = $failedEnvironmentIds.Count
        Found              = $agents.Count
        Created            = $batch.Succeeded
        Updated            = 0
        Unchanged          = $plan.Counts.Unchanged
        MarkedDeleted      = 0
        Restored           = 0
        Errors             = $plan.Counts.Skipped + $batch.Failed
        Skipped            = $plan.Counts.Skipped
    }
    $status = if ($counts.Errors -gt 0) { 'Partial' } else { 'Succeeded' }
    if ($loggingConfigured -and $runHeader.Persisted) {
        Complete-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
            -AccessToken $DataverseAccessToken -TableName ([string] $syncRunTableProperty.Value) `
            -RecordId $runHeader.RecordId -RunId $CorrelationId -Phase Write `
            -Status $status -Counts $counts | Out-Null
    }
    Write-InventoryTrace -Level Information -Message "Agent sync completed with status $status." `
        -CorrelationId $CorrelationId -Data @{
            syncType = 'AgentBuilder'
            status   = $status
            counts   = $counts
        }
    [pscustomobject] @{
        CorrelationId = $CorrelationId
        Status        = $status
        Counts        = $counts
        Logs          = $plan.Logs
        Batch         = $batch
    }
    }
    catch {
        $failure = $_
        $counts.Errors++
        $category = if ($phase -eq 'Collect') { 'ReadFailed' } else { 'WriteFailed' }
        $errorDetails = Get-InventoryErrorDetails -Message $failure.Exception.Message
        if ($loggingConfigured) {
            Write-InventorySyncLog -DataverseUrl $Configuration.TargetDataverseUrl `
                -AccessToken $DataverseAccessToken -TableName ([string] $syncLogTableProperty.Value) `
                -SyncRunTableName ([string] $syncRunTableProperty.Value) `
                -RunRecordId $(if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }) `
                -CorrelationId $CorrelationId -Severity Error -Category $category `
                -Operation $phase -HttpStatus $errorDetails.HttpStatus `
                -ErrorCode $errorDetails.ErrorCode -Message $failure.Exception.Message `
                -ErrorAction Continue | Out-Null
        }
        else {
            Write-InventoryTrace -Level Error -Message $failure.Exception.Message `
                -CorrelationId $CorrelationId -Data @{
                    category  = $category
                    operation = $phase
                    httpStatus = $errorDetails.HttpStatus
                    errorCode = $errorDetails.ErrorCode
                } -ErrorAction Continue
        }
        if ($loggingConfigured -and $runHeader.Persisted) {
            Complete-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
                -AccessToken $DataverseAccessToken -TableName ([string] $syncRunTableProperty.Value) `
                -RecordId $runHeader.RecordId -RunId $CorrelationId -Phase $phase `
                -Status Failed -Counts $counts | Out-Null
        }
        throw $failure
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
