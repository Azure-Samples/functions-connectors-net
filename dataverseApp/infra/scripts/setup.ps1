. (Join-Path $PSScriptRoot 'trigger-inputs.ps1')
. (Join-Path $PSScriptRoot 'local-key.ps1')

function Invoke-DataverseRest {
    param([string] $Method, [string] $Url, $Body, [string] $Subscription)
    $requestFile = Join-Path ([IO.Path]::GetTempPath()) "dataverse-request-$([guid]::NewGuid().ToString('N')).json"
    $responseFile = Join-Path ([IO.Path]::GetTempPath()) "dataverse-response-$([guid]::NewGuid().ToString('N')).json"
    $owned = [Collections.Generic.List[string]]::new()
    try {
        $arguments = @('rest', '--method', $Method, '--url', $Url, '--subscription', $Subscription, '--output-file', $responseFile, '-o', 'none')
        foreach ($file in @($responseFile) + $(if ($null -ne $Body) { @($requestFile) } else { @() })) {
            $stream = New-PrivateStagingStream $file
            $owned.Add($file)
            try {
                if ($file -eq $requestFile) { $stream.Write([Text.UTF8Encoding]::new($false).GetBytes(($Body | ConvertTo-Json -Depth 100 -Compress))) }
            } finally { $stream.Dispose() }
        }
        if ($null -ne $Body) { $arguments += @('--body', "@$requestFile") }
        az @arguments 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Dataverse $Method request failed. Check source permissions and Connector Namespace status; request secrets were not logged." }
        $json = [IO.File]::ReadAllText($responseFile)
        if (-not [string]::IsNullOrWhiteSpace($json)) { return ConvertFrom-DataverseJson $json }
    } finally {
        foreach ($file in $owned) { if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } }
    }
}

function ConvertTo-DataverseCanonicalJson {
    param($Value)
    function Sort-Value($Item) {
        if ($Item -is [Collections.IDictionary]) {
            $result = [ordered]@{}
            foreach ($key in @($Item.Keys | Sort-Object -CaseSensitive)) { $result[$key] = Sort-Value $Item[$key] }
            return $result
        }
        if ($Item -is [array]) { return ,@($Item | ForEach-Object { Sort-Value $_ }) }
        return $Item
    }
    return ConvertTo-Json -InputObject (Sort-Value $Value) -Depth 100 -Compress
}

function Assert-DataverseOwned {
    param($Resource, $Desired, [string] $Mode, [string] $Id)
    $properties = $Resource.properties
    $actualMode = if ($properties.deliveryMode) { $properties.deliveryMode } else { 'Webhook' }
    if ($Resource.id -ine $Id -or $actualMode -cne $Mode -or
        $properties.operationName -cne $Desired.operationName -or
        $properties.connectionDetails.connectionName -cne $Desired.connectionDetails.connectionName -or
        $properties.connectionDetails.connectorName -cne 'commondataservice') {
        throw "Refusing to overwrite an unowned, legacy-operation, or other-delivery trigger: $($Resource.name)."
    }
    foreach ($key in $Desired.metadata.Keys) {
        if ($properties.metadata[$key] -ine $Desired.metadata[$key]) {
            throw "Refusing to overwrite another application's trigger: $($Resource.name)."
        }
    }
}

function Get-DataversePollingEndpoint {
    param([string] $ReceiveUri, [string] $Name)
    $uri = $null
    if (-not [uri]::TryCreate($ReceiveUri, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Fragment) { throw 'Missing or invalid service-generated Poll receive URI.' }
    $suffix = "/triggerconfigs/$Name/receive"
    if (-not $uri.AbsolutePath.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected Poll receive URI path.' }
    $path = $uri.AbsolutePath.Substring(0, $uri.AbsolutePath.Length - $suffix.Length).TrimEnd('/')
    if ($path -eq '/api') { $path = '' }
    return $uri.GetLeftPart([UriPartial]::Authority) + $path
}

function Wait-DataverseTrigger {
    param($Resource, [string] $Url, [string] $Subscription, [string] $State, [bool] $NeedsEndpoint)
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $pending = $Resource.properties.provisioningState -in @('Accepted', 'Creating', 'Updating', 'Running')
        $missingEndpoint = $NeedsEndpoint -and -not $Resource.properties.pollingEndpoints.receiveUri
        if ($Resource.properties.provisioningState -in @('Failed', 'Canceled', 'Cancelled')) { break }
        if ($Resource.properties.state -eq $State -and -not $pending -and -not $missingEndpoint) { return $Resource }
        Start-Sleep -Seconds 2
        $Resource = Invoke-DataverseRest GET $Url -Subscription $Subscription
    }
    throw "Trigger did not finish provisioning in state $State. Inspect its source-registration status before retrying."
}

function Wait-DataverseConnection {
    param($Outputs, [string] $ConnectionUrl)
    $subscription = $Outputs.AZURE_SUBSCRIPTION_ID
    $connection = Invoke-DataverseRest GET "${ConnectionUrl}?api-version=2026-05-01-preview" -Subscription $subscription
    if ($connection.properties.overallStatus -eq 'Connected') { return }
    Write-Host 'Authorize Dataverse with an account permitted to register the selected source events.'
    $link = az connector-namespace connection list-consent-links `
        --subscription $subscription -g $Outputs.resourceGroupName --namespace $Outputs.connectorNamespaceName `
        --connection-name $Outputs.connectorNamespaceConnectionName `
        --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" --query 'value[0].link' -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $link -or $link -eq 'null') {
        $link = az connector-namespace connection list-consent-links `
            --subscription $subscription -g $Outputs.resourceGroupName --namespace $Outputs.connectorNamespaceName `
            --connection-name $Outputs.connectorNamespaceConnectionName `
            --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" --query link -o tsv 2>$null
    }
    if ($LASTEXITCODE -ne 0 -or -not $link -or $link -eq 'null') { throw 'Could not obtain a Dataverse consent link.' }
    Write-Host "Consent URL: $link"
    try { Start-Process $link | Out-Null } catch { Write-Host 'Open the consent URL in your browser.' }
    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 3
        $connection = Invoke-DataverseRest GET "${ConnectionUrl}?api-version=2026-05-01-preview" -Subscription $subscription
        if ($connection.properties.overallStatus -eq 'Connected') { return }
    } while ((Get-Date) -lt $deadline)
    throw 'Timed out waiting for Dataverse authorization. Complete consent and rerun azd hooks run postdeploy.'
}

function Invoke-DataverseSetup {
    param(
        [ValidateSet('Poll', 'Webhook')] [string] $Mode,
        [string] $SampleRoot,
        [string] $CallbackBaseUrl,
        [string] $LocalHostId,
        [switch] $Reconfigure,
        [switch] $ForceLocalSettings
    )
    $localCallback = -not [string]::IsNullOrWhiteSpace($CallbackBaseUrl)
    if ($localCallback) {
        $uri = $null
        if ($Mode -ne 'Webhook' -or -not [uri]::TryCreate($CallbackBaseUrl, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') {
            throw 'CallbackBaseUrl must be the public HTTPS tunnel origin, without credentials, path, query, or fragment.'
        }
    } elseif ($LocalHostId) { throw 'LocalHostId requires CallbackBaseUrl.' }
    $raw = azd env get-values --output json
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected azd environment.' }
    $outputs = ConvertFrom-DataverseJson ($raw -join "`n")
    foreach ($name in @('resourceGroupName', 'functionAppName', 'connectorNamespaceName', 'connectorNamespaceConnectionName', 'AZURE_SUBSCRIPTION_ID')) {
        if ([string]::IsNullOrWhiteSpace([string]$outputs[$name])) { throw "Missing azd output $name. Run azd provision first." }
    }
    $location = if ($outputs.connectorNamespaceLocation) { $outputs.connectorNamespaceLocation } else { $outputs.CONNECTOR_NAMESPACE_LOCATION }
    if ([string]::IsNullOrWhiteSpace($location)) {
        throw 'Missing Connector Namespace location. Run azd provision to select resource regions first.'
    }
    $subscription = $outputs.AZURE_SUBSCRIPTION_ID
    $namespaceId = "/subscriptions/$subscription/resourceGroups/$($outputs.resourceGroupName)/providers/Microsoft.Web/connectorGateways/$($outputs.connectorNamespaceName)"
    $root = "https://management.azure.com$namespaceId"
    $connectionUrl = "$root/connections/$([uri]::EscapeDataString($outputs.connectorNamespaceConnectionName))"
    Wait-DataverseConnection $outputs $connectionUrl
    $exported = Invoke-DataverseRest GET "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.Web/locations/$location/managedApis/commondataservice?api-version=2022-09-01-preview&export=true" -Subscription $subscription
    $swagger = if ($exported.properties.apiDefinitions.value) { $exported.properties.apiDefinitions.value } else { $exported }
    if ($swagger -is [string]) { $swagger = ConvertFrom-DataverseJson $swagger }
    if (-not $swagger.paths) { throw 'The Dataverse connector exported no operation metadata.' }
    $savedSetting = if ($Mode -eq 'Poll') { 'DATAVERSE_POLLING_TRIGGER_INPUTS' } else { 'DATAVERSE_WEBHOOK_TRIGGER_INPUTS' }
    if ($outputs[$savedSetting] -and -not $Reconfigure) {
        try {
            $triggers = ConvertFrom-DataverseJson ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($outputs[$savedSetting])))
        } catch { throw "Invalid saved selections. Clear $savedSetting and rerun setup." }
        Write-Host "Reusing saved selections from $savedSetting. Pass -Reconfigure to choose again."
    } else {
        $cache = @{}
        $invokePicker = {
            param($Id, $Values)
            $cacheKey = $Id + (ConvertTo-DataverseCanonicalJson $Values)
            if (-not $cache.ContainsKey($cacheKey)) {
                $request = New-DataverseOperationRequest $swagger $Id $Values
                $result = Invoke-DataverseRest POST "$connectionUrl/dynamicInvoke?api-version=2026-05-01-preview" @{ request = $request } $subscription
                if ($null -eq $result.response -or [string]$result.response.statusCode -notin @('200', '201', 'OK', 'Created')) {
                    throw "Connector picker $Id failed. Check Dataverse permissions; no values were guessed."
                }
                $body = $result.response.body
                if ($body -is [string]) { $body = ConvertFrom-DataverseJson $body }
                $cache[$cacheKey] = $body
            }
            return ,$cache[$cacheKey]
        }
        $triggers = Read-DataverseTriggers $swagger $invokePicker
    }
    Assert-DataverseSelections $triggers $swagger
    $key = $null
    if ($Mode -eq 'Webhook') {
        if ($localCallback) { $key = Get-DataverseLocalKey $SampleRoot $LocalHostId } else {
            if (-not $outputs.functionAppDefaultHostname) { throw 'Missing functionAppDefaultHostname. Run azd provision first.' }
            $CallbackBaseUrl = "https://$($outputs.functionAppDefaultHostname)"
            for ($attempt = 0; $attempt -lt 30; $attempt++) {
                $key = az functionapp keys list --subscription $subscription -g $outputs.resourceGroupName `
                    -n $outputs.functionAppName --query systemKeys.connector_extension -o tsv 2>$null
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($key)) { break }
                if ($attempt -lt 29) { Start-Sleep -Seconds 3 }
            }
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($key)) { throw 'The deployed host returned no connector_extension system key. Check host startup.' }
        }
    }
    $existing = @{}
    $page = "$root/triggerConfigs?api-version=2026-05-01-preview"
    while ($page) {
        $result = Invoke-DataverseRest GET $page -Subscription $subscription
        foreach ($resource in $result.value) {
            if ($existing.ContainsKey($resource.name)) { throw 'Ambiguous trigger configuration inventory.' }
            $existing[$resource.name] = $resource
        }
        $page = $result.nextLink
        if ($page -and -not $page.StartsWith("$root/triggerConfigs?", [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe trigger inventory continuation URL.' }
    }
    $plan = @(
        foreach ($definition in Get-DataverseTriggerDefinitions) {
            $name = if ($Mode -eq 'Poll') { "dataverse-$($definition.functionName.ToLowerInvariant())" } else { "$($outputs.connectorNamespaceConnectionName)-$($definition.functionName.ToLowerInvariant())" }
            if ($name -cnotmatch '^[a-z0-9-]+$') { throw 'Unsafe generated trigger name.' }
            $selected = @($triggers | Where-Object { $_.functionName -ceq $definition.functionName })
            $properties = [ordered]@{
                connectionDetails = @{ connectionName = $outputs.connectorNamespaceConnectionName; connectorName = 'commondataservice' }
                operationName = $definition.operationName
                parameters = @(if ($selected.Count) { $selected[0].parameters })
                metadata = @{
                    destinationType = 'functionApp'
                    functionAppName = $outputs.functionAppName
                    functionAppResourceGroup = $outputs.resourceGroupName
                    functionAppSubscriptionId = $subscription
                    functionName = $definition.functionName
                }
                state = 'Enabled'
                type = 'NotSpecified'
                description = "Dataverse $($definition.operationName) -> $($definition.functionName)"
            }
            if ($Mode -eq 'Poll') { $properties.deliveryMode = 'Poll' } else {
                $properties.notificationDetails = @{
                    callbackUrl = "$($CallbackBaseUrl.TrimEnd('/'))/runtime/webhooks/connector?functionName=$($definition.functionName)"
                    authentication = @{ type = 'QueryString'; name = 'code'; value = $key }
                }
            }
            $resource = $existing[$name]
            if ($resource) { Assert-DataverseOwned $resource $properties $Mode "$namespaceId/triggerConfigs/$name" }
            # Old hooks may have left an action cleanup marker after an uncertain source registration.
            if ($selected.Count -and $definition.functionName -eq 'OnDataverseActionPerformed' -and -not $resource) {
                $journalHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                    [Text.Encoding]::UTF8.GetBytes("$namespaceId|$($outputs.connectorNamespaceConnectionName)|/subscriptions/$subscription/resourceGroups/$($outputs.resourceGroupName)/providers/Microsoft.Web/sites/$($outputs.functionAppName)|$Mode"))).ToLowerInvariant()
                if (Test-Path -LiteralPath (Join-Path $SampleRoot ".azure/dataverse-action-cleanup-$journalHash.json")) {
                    throw 'A previous action registration has pending source cleanup. Verify exact-owned cleanup before creating its missing configuration.'
                }
            }
            @{ definition = $definition; name = $name; selected = [bool]$selected.Count; properties = $properties; resource = $resource }
        }
    )
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $triggers -Depth 100 -Compress)))
    azd env set $savedSetting $encoded
    if ($LASTEXITCODE -ne 0) { throw 'Could not save Dataverse trigger selections.' }
    $values = @{ AzureWebJobsStorage = 'UseDevelopmentStorage=true'; FUNCTIONS_WORKER_RUNTIME = 'dotnet-isolated' }
    $endpoint = $null
    foreach ($item in $plan) {
        $name = $item.name
        $function = $item.definition.functionName
        $values["AzureWebJobs.$function.Disabled"] = (-not $item.selected).ToString().ToLowerInvariant()
        if ($Mode -eq 'Poll') { $values["${function}TriggerConfigName"] = $name }
        $url = "$root/triggerConfigs/${name}?api-version=2026-05-01-preview"
        if (-not $item.selected) {
            if ($item.resource -and $item.resource.properties.state -ne 'Disabled') {
                $preserved = $item.resource.properties
                [void]$preserved.Remove('pollingEndpoints')
                [void]$preserved.Remove('provisioningState')
                $preserved.state = 'Disabled'
                $disabled = Invoke-DataverseRest PUT $url @{ properties = $preserved } $subscription
                $null = Wait-DataverseTrigger $disabled $url $subscription Disabled $false
            }
            Write-Host "$function skipped; any owned configuration is disabled, not deleted."
            continue
        }
        $current = $item.resource.properties
        $unchanged = $current -and $current.state -ceq 'Enabled' -and $current.provisioningState -notin @('Failed', 'Canceled', 'Cancelled') -and
            (ConvertTo-DataverseCanonicalJson @($current.parameters | Sort-Object name)) -ceq (ConvertTo-DataverseCanonicalJson @($item.properties.parameters | Sort-Object name))
        if ($Mode -eq 'Webhook') {
            $unchanged = $unchanged -and (ConvertTo-DataverseCanonicalJson $current.notificationDetails) -ceq (ConvertTo-DataverseCanonicalJson $item.properties.notificationDetails)
        }
        $created = if ($unchanged) { $item.resource } else { Invoke-DataverseRest PUT $url @{ properties = $item.properties } $subscription }
        $created = Wait-DataverseTrigger $created $url $subscription Enabled ($Mode -eq 'Poll')
        if ($Mode -eq 'Poll') {
            $candidate = Get-DataversePollingEndpoint $created.properties.pollingEndpoints.receiveUri $name
            if ($endpoint -and $endpoint -cne $candidate) { throw 'Selected Poll triggers returned inconsistent namespace endpoints.' }
            $endpoint = $candidate
        }
        Write-Host "$function configured for $Mode delivery."
    }
    if ($Mode -eq 'Poll') {
        if (-not $endpoint) { throw 'No Poll receive endpoint was returned.' }
        $values.ConnectorNamespace__pollingEndpoint = $endpoint
    }
    $cloudValues = @{}
    foreach ($name in $values.Keys) {
        if ($name -notin @('AzureWebJobsStorage', 'FUNCTIONS_WORKER_RUNTIME')) { $cloudValues[$name] = $values[$name] }
    }
    $settingsFile = Join-Path ([IO.Path]::GetTempPath()) "dataverse-appsettings-$([guid]::NewGuid().ToString('N')).json"
    $owned = $false
    try {
        $stream = New-PrivateStagingStream $settingsFile
        $owned = $true
        try { $stream.Write([Text.UTF8Encoding]::new($false).GetBytes(($cloudValues | ConvertTo-Json -Depth 10))) } finally { $stream.Dispose() }
        az functionapp config appsettings set --subscription $subscription -g $outputs.resourceGroupName `
            -n $outputs.functionAppName --settings "@$settingsFile" -o none 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Could not configure the deployed function listeners. Rerun the hook after resolving the app settings error.' }
    } finally {
        if ($owned -and [IO.File]::Exists($settingsFile)) { [IO.File]::Delete($settingsFile) }
    }
    Write-LocalSettings $values -Force:$ForceLocalSettings
    Write-Host 'Existing local settings are preserved unless -ForceLocalSettings is supplied; regenerate after changing selections.'
    Write-Host 'Dataverse setup complete. Source provisioning is not proof of event delivery; verify with a sample-owned fixture.'
}
