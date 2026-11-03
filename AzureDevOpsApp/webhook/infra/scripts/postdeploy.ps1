param([string] $CallbackBaseUrl, [string] $ConnectorExtensionKey)
$localCallback = -not [string]::IsNullOrWhiteSpace($CallbackBaseUrl)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-settings.ps1')
if (($CallbackBaseUrl -and (-not $CallbackBaseUrl.StartsWith('https://') -or [string]::IsNullOrWhiteSpace($ConnectorExtensionKey))) -or
    ($ConnectorExtensionKey -and -not $CallbackBaseUrl)) {
    throw 'Local callbacks require both a public HTTPS CallbackBaseUrl and local ConnectorExtensionKey.'
}
$raw = azd env get-values --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected azd environment.' }
$outputs = ($raw -join "`n") | ConvertFrom-Json
foreach ($name in @('resourceGroupName', 'connectorNamespaceName', 'connectorNamespaceConnectionName', 'functionAppName', 'AZURE_SUBSCRIPTION_ID', 'triggerConfigSettings', 'triggerDefinitions')) {
    $value = $outputs.$name
    if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) { throw "Missing azd output $name." }
}
$settings = if ($outputs.triggerConfigSettings -is [string]) { $outputs.triggerConfigSettings | ConvertFrom-Json } else { $outputs.triggerConfigSettings }
$triggers = if ($outputs.triggerDefinitions -is [string]) { $outputs.triggerDefinitions | ConvertFrom-Json } else { $outputs.triggerDefinitions }
if (@($triggers).Count -ne 9) { throw 'Expected nine Azure DevOps trigger definitions.' }
$values = @{ FUNCTIONS_WORKER_RUNTIME = 'dotnet-isolated'; AzureWebJobsStorage = 'UseDevelopmentStorage=true' }
foreach ($trigger in $triggers) {
    $disabled = "AzureWebJobs.$($trigger.functionName).Disabled"
    if ($settings.$disabled -notin @('true', 'false')) { throw "Invalid setting $disabled." }
    $values[$disabled] = [string]$settings.$disabled
}
Write-LocalSettings $values
$raw = az connector-namespace trigger list -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName --query '[].name' -o json 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Could not list existing Webhook trigger configurations.' }
$existing = ($raw -join "`n") | ConvertFrom-Json
if (-not $CallbackBaseUrl) {
    if ([string]::IsNullOrWhiteSpace($outputs.functionAppDefaultHostname)) { throw 'Missing functionAppDefaultHostname.' }
    $ConnectorExtensionKey = az functionapp keys list -g $outputs.resourceGroupName -n $outputs.functionAppName --query systemKeys.connector_extension -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ConnectorExtensionKey) -or $ConnectorExtensionKey -eq 'null') { throw 'Missing connector_extension system key. Deploy the app first.' }
    $CallbackBaseUrl = "https://$($outputs.functionAppDefaultHostname)"
}
foreach ($trigger in $triggers) {
    $name = "azuredevops-$($trigger.functionName.ToLowerInvariant())"
    if (-not $trigger.enabled) {
        if ($name -in $existing) {
            az connector-namespace trigger update -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName -n $name --state Disabled -o none 2>$null
            if ($LASTEXITCODE -ne 0) { throw "Could not stop trigger $name." }
        }
        continue
    }
    $notification = Join-Path ([IO.Path]::GetTempPath()) "azuredevops-notification-$([guid]::NewGuid()).json"
    $parameters = Join-Path ([IO.Path]::GetTempPath()) "azuredevops-parameters-$([guid]::NewGuid()).json"
    $ownedFiles = [Collections.Generic.List[string]]::new()
    $failure = $null
    try {
        $metadata = @{
            recurrenceFrequency = 'Minute'; recurrenceInterval = '5'
        }
        if (-not $localCallback) {
            $metadata.destinationType = 'functionApp'
            $metadata.functionAppName = $outputs.functionAppName
            $metadata.functionAppResourceGroup = $outputs.resourceGroupName
            $metadata.functionAppSubscriptionId = $outputs.AZURE_SUBSCRIPTION_ID
            $metadata.functionName = $trigger.functionName
        }
        $documents = @(
            @{ path = $notification; value = @{
                callbackUrl = "$($CallbackBaseUrl.TrimEnd('/'))/runtime/webhooks/connector?functionName=$($trigger.functionName)"
                authentication = @{ type = 'QueryString'; name = 'code'; value = $ConnectorExtensionKey }
            } },
            @{ path = $parameters; value = @($trigger.parameters) }
        )
        foreach ($document in $documents) {
            $stream = New-PrivateStagingStream $document.path
            $ownedFiles.Add($document.path)
            $streamFailure = $null
            try {
                $json = ConvertTo-Json -InputObject $document.value -Depth 4 -Compress
                $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
                $stream.Write($bytes)
                $stream.Flush($true)
            } catch { $streamFailure = $_; throw }
            finally {
                try { $stream.Dispose() }
                catch {
                    if ($null -eq $streamFailure) { throw 'Could not close owned callback staging stream.' }
                    Write-Warning 'Could not close owned staging stream; original failure preserved.'
                }
            }
        }
        $verb = if ($name -in $existing) { 'update' } else { 'create' }
        az connector-namespace trigger $verb -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName -n $name `
            --connection-details "{connectionName:$($outputs.connectorNamespaceConnectionName),connectorName:visualstudioteamservices}" `
            --operation-name $trigger.operationName --parameters "@$parameters" --notification-details "@$notification" --state Enabled `
            --metadata (ConvertTo-Json -InputObject $metadata -Compress) -o none 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Could not configure Webhook trigger $name." }
    } catch {
        $failure = $_
        throw
    } finally {
        $cleanupFailed = $false
        foreach ($path in $ownedFiles) {
            try {
                if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
            } catch {
                $cleanupFailed = $true
                Write-Warning 'Could not clean owned callback staging file.'
            }
        }
        if ($cleanupFailed -and $null -eq $failure) { throw 'Callback staging cleanup failed.' }
    }
}
Write-Host 'Webhook callbacks configured. Authorize the Azure DevOps connection separately; this hook does not perform consent.'
