$ErrorActionPreference = 'Stop'
if (-not (az extension show --name connector-namespace --query name -o tsv 2>$null)) {
    throw 'Install the connector-namespace Azure CLI extension before running this script.'
}
$raw = azd env get-values --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected azd environment.' }
$outputs = ($raw -join "`n") | ConvertFrom-Json
foreach ($name in @(
    'resourceGroupName', 'connectorNamespaceName', 'connectorNamespaceConnectionName',
    'functionAppName', 'AZURE_SUBSCRIPTION_ID', 'dataverseEnvironmentUrl', 'dataverseTableName')) {
    if ([string]::IsNullOrWhiteSpace([string]$outputs.$name)) { throw "Missing azd output $name." }
}
if ([string]$outputs.enableActionTrigger -notin @('true', 'false')) {
    throw 'Missing or invalid azd output enableActionTrigger. Run azd provision first.'
}
$actionEnabled = [string]$outputs.enableActionTrigger -eq 'true'
if ($actionEnabled) {
    foreach ($name in @('eventCatalog', 'eventCategory', 'eventTable', 'eventAction')) {
        if ([string]::IsNullOrWhiteSpace([string]$outputs.$name)) { throw "Missing business-event value $name." }
    }
}

$localSettingsPath = Join-Path $PSScriptRoot '../../local.settings.json'
if (Test-Path -LiteralPath $localSettingsPath) {
    $item = Get-Item -LiteralPath $localSettingsPath -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'local.settings.json must be a regular file.'
    }
    Write-Host 'Existing local.settings.json preserved.'
} else {
    $localSettings = @{
        IsEncrypted = $false
        Values = @{
            AzureWebJobsStorage = 'UseDevelopmentStorage=true'
            FUNCTIONS_WORKER_RUNTIME = 'dotnet-isolated'
            'AzureWebJobs.OnDataverseActionPerformed.Disabled' = (-not $actionEnabled).ToString().ToLowerInvariant()
        }
    }
    $stagingPath = Join-Path (Split-Path $localSettingsPath) ".local-settings-$([Guid]::NewGuid().ToString('N')).json"
    try {
        [IO.File]::WriteAllText(
            $stagingPath,
            ($localSettings | ConvertTo-Json -Depth 4),
            [Text.UTF8Encoding]::new($false))
        $validated = Get-Content -LiteralPath $stagingPath -Raw | ConvertFrom-Json -AsHashtable
        if ($validated.IsEncrypted -ne $false -or $validated.Values.Count -ne 3) {
            throw 'Generated local settings failed validation.'
        }
        foreach ($name in $localSettings.Values.Keys) {
            if ($validated.Values[$name] -cne $localSettings.Values[$name]) {
                throw "Generated local setting '$name' failed validation."
            }
        }
        [IO.File]::Move($stagingPath, $localSettingsPath)
        Write-Host 'Created ignored local.settings.json using Azurite.'
    } finally {
        if (Test-Path -LiteralPath $stagingPath) {
            Remove-Item -LiteralPath $stagingPath -ErrorAction Stop
        }
    }
}

if (-not $actionEnabled) {
    $name = "$($outputs.connectorNamespaceConnectionName)-ondataverseactionperformed"
    $uri = "https://management.azure.com/subscriptions/$($outputs.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($outputs.resourceGroupName)/providers/Microsoft.Web/connectorGateways/$($outputs.connectorNamespaceName)/triggerConfigs"
    $raw = az rest --method get --url "${uri}?api-version=2026-05-01-preview" -o json
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect existing Dataverse action subscriptions.' }
    $configs = ($raw -join "`n") | ConvertFrom-Json
    $existing = @($configs.value | Where-Object name -eq $name)
    if ($existing.Count -gt 0) {
        if ($existing.Count -ne 1 -or
            $existing[0].properties.operationName -ne 'BusinessEventsTrigger' -or
            $existing[0].properties.connectionDetails.connectionName -ne $outputs.connectorNamespaceConnectionName) {
            throw "Refusing to delete '$name': it does not match this sample's action subscription."
        }
        az rest --method delete --url "$uri/${name}?api-version=2026-05-01-preview" -o none
        if ($LASTEXITCODE -ne 0) { throw "Could not remove disabled Dataverse action subscription '$name'." }
        Write-Host "Removed sample-owned action subscription '$name' because the action is disabled."
    }
}

function Get-ConnectionStatus {
    $status = az connector-namespace connection show `
        -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName `
        -n $outputs.connectorNamespaceConnectionName --query 'properties.overallStatus' -o tsv
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the Dataverse connection status.' }
    return $status
}
if ((Get-ConnectionStatus) -ne 'Connected') {
    $link = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $link = az connector-namespace connection list-consent-links `
            -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName `
            --connection-name $outputs.connectorNamespaceConnectionName `
            --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" `
            --query 'value[0].link' -o tsv 2>$null
        if (-not $link -or $link -eq 'null') {
            $link = az connector-namespace connection list-consent-links `
                -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName `
                --connection-name $outputs.connectorNamespaceConnectionName `
                --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" `
                --query 'link' -o tsv 2>$null
        }
        if ($link -and $link -ne 'null') { break }
        if ($attempt -lt 5) { Start-Sleep -Seconds 5 }
    }
    if (-not $link -or $link -eq 'null') { throw 'Could not obtain a Dataverse consent link.' }
    Write-Host "Consent URL: $link"
    try { Start-Process $link | Out-Null } catch { Write-Host 'Open the consent URL in your browser.' }
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-ConnectionStatus) -ne 'Connected') {
        if ((Get-Date) -ge $deadline) { throw 'Timed out waiting for Dataverse OAuth consent.' }
        Start-Sleep -Seconds 5
    }
} else {
    Write-Host 'Dataverse connection is already authorized; preserving OAuth consent.'
}

$key = az functionapp keys list -g $outputs.resourceGroupName -n $outputs.functionAppName `
    --query systemKeys.connector_extension -o tsv
if ($LASTEXITCODE -ne 0 -or -not $key) { throw 'Connector extension system key unavailable.' }
$hostname = az resource show -g $outputs.resourceGroupName -n $outputs.functionAppName `
    --resource-type Microsoft.Web/sites --query properties.defaultHostName -o tsv
if ($LASTEXITCODE -ne 0 -or -not $hostname) { throw 'Function hostname unavailable.' }
$organization = $outputs.dataverseEnvironmentUrl.TrimEnd('/')
$triggers = @(
    @{
        functionName = 'OnDataverseRowChanged'
        operationName = 'SubscribeWebhookTrigger'
        parameters = @(
            @{ name = 'organization'; value = $organization }
            @{ name = 'entityname'; value = $outputs.dataverseTableName }
            @{ name = 'message'; value = '7' }
            @{ name = 'scope'; value = '4' }
        )
    }
)
if ($actionEnabled) {
    $triggers += @{
        functionName = 'OnDataverseActionPerformed'
        operationName = 'BusinessEventsTrigger'
        parameters = @(
            @{ name = 'organization'; value = $organization }
            @{ name = 'catalog'; value = $outputs.eventCatalog }
            @{ name = 'category'; value = $outputs.eventCategory }
            @{ name = 'entityname'; value = $outputs.eventTable }
            @{ name = 'sdkmessagename'; value = $outputs.eventAction }
        )
    }
}
$failed = @()
foreach ($trigger in $triggers) {
    $name = "$($outputs.connectorNamespaceConnectionName)-$($trigger.functionName.ToLowerInvariant())"
    $bodyFile = Join-Path $PSScriptRoot ".notification-details-$([Guid]::NewGuid().ToString('N')).json"
    $body = @{
        properties = @{
            connectionDetails = @{ connectionName = $outputs.connectorNamespaceConnectionName; connectorName = 'commondataservice' }
            operationName = $trigger.operationName
            parameters = $trigger.parameters
            state = 'Enabled'
            type = 'NotSpecified'
            notificationDetails = @{
                callbackUrl = "https://$hostname/runtime/webhooks/connector?functionName=$($trigger.functionName)"
                authentication = @{ type = 'QueryString'; name = 'code'; value = $key }
            }
        }
    }
    try {
        [IO.File]::WriteAllText($bodyFile, ($body | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        Write-Host "Creating current Dataverse trigger '$name' ($($trigger.operationName))..."
        $uri = "https://management.azure.com/subscriptions/$($outputs.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($outputs.resourceGroupName)/providers/Microsoft.Web/connectorGateways/$($outputs.connectorNamespaceName)/triggerConfigs/${name}?api-version=2026-05-01-preview"
        az rest --method put --url $uri --body "@$bodyFile" -o none
        if ($LASTEXITCODE -ne 0) { $failed += $trigger.operationName }
    } finally {
        Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
    }
}
if ($failed.Count -gt 0) { throw "Dataverse trigger registration failed: $($failed -join ', '). See the service errors above." }
Write-Host 'Current Dataverse webhook trigger configuration complete.'
