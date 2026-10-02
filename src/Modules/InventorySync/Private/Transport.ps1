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
            if ($attempt -le $MaxRetryCount) {
                $delay = Get-RetryDelaySeconds -Headers @{} -RetryNumber $attempt
                & $SleepAction $delay
                continue
            }
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
        $isRetryable = $statusCode -in @(408, 429, 500, 502, 503, 504) -or $isServiceProtection
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
        [Parameter(Mandatory)] [string] $AccessToken,
        [Parameter()] [System.Collections.IDictionary] $AdditionalHeaders = @{}
    )

    $headers = @{
        Authorization    = "Bearer $AccessToken"
        Accept           = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version'  = '4.0'
    }
    foreach ($header in $AdditionalHeaders.GetEnumerator()) {
        $headers[[string] $header.Key] = $header.Value
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
        $truncatedProperty = $response.Body.PSObject.Properties['resultTruncated']
        if (
            $null -ne $truncatedProperty -and
            [string] $truncatedProperty.Value -ieq 'true' -and
            [string]::IsNullOrWhiteSpace($skipToken)
        ) {
            throw 'Resource Graph returned an incomplete result without a continuation token.'
        }
        if (-not [string]::IsNullOrWhiteSpace($skipToken) -and -not $seenTokens.Add($skipToken)) {
            throw "Resource Graph returned a repeated `$skipToken: '$skipToken'."
        }
    } while (-not [string]::IsNullOrWhiteSpace($skipToken))
}
