param(
    [string] $CallbackBaseUrl,
    [string] $ConnectorExtensionKey
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-settings.ps1')
& (Join-Path $PSScriptRoot 'create-local-settings.ps1')
$raw = azd env get-values --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected azd environment.' }
$outputs = ($raw -join "`n") | ConvertFrom-Json
foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'resourceGroupName', 'functionAppName',
    'functionAppDefaultHostname', 'connectorNamespaceName', 'connectorNamespaceConnectionName', 'triggerDefinitions')) {
    if ($null -eq $outputs.$name -or
        ($outputs.$name -is [string] -and [string]::IsNullOrWhiteSpace($outputs.$name))) {
        throw "Missing azd output $name. Provision first."
    }
}
$triggers = if ($outputs.triggerDefinitions -is [string]) {
    $outputs.triggerDefinitions | ConvertFrom-Json
} else { $outputs.triggerDefinitions }
if ($triggers.Count -ne 2 -or
    (($triggers.functionName | Sort-Object) -join ',') -cne 'OnNewRecord,OnUpdatedRecord') {
    throw 'Expected both distinct Salesforce trigger definitions.'
}
foreach ($trigger in $triggers) {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($trigger.parameters -isnot [array]) { throw 'Invalid Salesforce trigger parameter array.' }
    foreach ($parameter in $trigger.parameters) {
        if ($parameter.name -cnotin @('table', '$filter', '$orderby', '$select') -or
            $parameter.value -isnot [string] -or -not $names.Add($parameter.name) -or
            ($parameter.name -ceq 'table' -and [string]::IsNullOrWhiteSpace($parameter.value))) {
            throw 'Invalid Salesforce trigger parameter array.'
        }
    }
    if ($trigger.operationName -cne $(if ($trigger.functionName -ceq 'OnNewRecord') { 'GetOnNewItems' } else { 'GetOnUpdatedItems' }) -or
        -not $names.Contains('table')) {
        throw 'Invalid Salesforce trigger definition or parameter array.'
    }
}
$isTunnel = -not [string]::IsNullOrEmpty($CallbackBaseUrl)
if ($CallbackBaseUrl -or $ConnectorExtensionKey) {
    $uri = $null
    if (-not [Uri]::TryCreate($CallbackBaseUrl, [UriKind]::Absolute, [ref] $uri) -or
        $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $uri.AbsolutePath -ne '/' -or [string]::IsNullOrWhiteSpace($ConnectorExtensionKey)) {
        throw 'Tunnel delivery requires an HTTPS authority and its local ConnectorExtensionKey. Start the host with --enableAuth.'
    }
} else {
    $key = az functionapp keys list -g $outputs.resourceGroupName -n $outputs.functionAppName `
        --query 'systemKeys.connector_extension' --only-show-errors -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($key) -or $key -eq 'null') {
        throw 'Could not retrieve connector_extension. Deploy the app and allow its host to start first.'
    }
    $ConnectorExtensionKey = ($key -join '').Trim()
    $CallbackBaseUrl = "https://$($outputs.functionAppDefaultHostname)"
}
$baseId = "/subscriptions/$($outputs.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($outputs.resourceGroupName)/providers/Microsoft.Web/connectorGateways/$($outputs.connectorNamespaceName)"
foreach ($trigger in $triggers) {
    if ($trigger.functionName -cnotin @('OnNewRecord', 'OnUpdatedRecord') -or
        $trigger.operationName -cne $(if ($trigger.functionName -ceq 'OnNewRecord') { 'GetOnNewItems' } else { 'GetOnUpdatedItems' })) {
        throw 'Invalid Salesforce trigger definition.'
    }
    $properties = @{
        connectionDetails = @{
            connectionName = $outputs.connectorNamespaceConnectionName
            connectorName = 'salesforce'
        }
        deliveryMode = 'Webhook'
        operationName = $trigger.operationName
        parameters = @($trigger.parameters)
        state = 'Enabled'
        type = 'NotSpecified'
        notificationDetails = @{
            callbackUrl = "$($CallbackBaseUrl.TrimEnd('/'))/runtime/webhooks/connector?functionName=$($trigger.functionName)"
            authentication = @{ type = 'QueryString'; name = 'code'; value = $ConnectorExtensionKey }
        }
        metadata = @{
            recurrenceFrequency = 'Minute'; recurrenceInterval = '5'
        }
    }
    if (-not $isTunnel) {
        $properties.metadata.destinationType = 'functionApp'
        $properties.metadata.functionAppName = $outputs.functionAppName
        $properties.metadata.functionAppResourceGroup = $outputs.resourceGroupName
        $properties.metadata.functionAppSubscriptionId = $outputs.AZURE_SUBSCRIPTION_ID
        $properties.metadata.functionName = $trigger.functionName
    }
    $temp = Join-Path (Join-Path $PSScriptRoot '..\..') ".trigger-$([Guid]::NewGuid().ToString('N')).json"
    $owned = [Collections.Generic.List[string]]::new()
    $failure = $null
    try {
        Write-PrivateJson $temp @{ properties = $properties } $owned
        $null = Get-Content -LiteralPath $temp -Raw | ConvertFrom-Json
        $name = "salesforce-$($trigger.functionName.ToLowerInvariant())"
        az rest --method put --uri "$baseId/triggerConfigs/${name}?api-version=2026-05-01-preview" `
            --body "@$temp" --only-show-errors -o none 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Could not configure $($trigger.functionName) Webhook delivery." }
    }
    catch { $failure = $_; throw }
    finally { Remove-OwnedStaging $owned $failure }
}
Write-Host 'Webhook delivery configured. Manually authorize the Salesforce connection for the approved org before testing.'
