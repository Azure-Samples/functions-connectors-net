param([string] $CallbackBaseUrl, [string] $ConnectorExtensionKey, [switch] $LocalSettingsOnly)
$ErrorActionPreference = 'Stop'
$localCallback = -not [string]::IsNullOrWhiteSpace($CallbackBaseUrl)
. (Join-Path $PSScriptRoot 'local-settings.ps1')

if ($CallbackBaseUrl -and (-not $CallbackBaseUrl.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase) -or [string]::IsNullOrWhiteSpace($ConnectorExtensionKey))) {
    throw 'Local callbacks require a public HTTPS CallbackBaseUrl and the local ConnectorExtensionKey.'
}
if ($ConnectorExtensionKey -and -not $CallbackBaseUrl) { throw 'CallbackBaseUrl is required with ConnectorExtensionKey.' }
$raw = azd env get-values --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected azd environment.' }
$outputs = ($raw -join "`n") | ConvertFrom-Json
foreach ($key in @('resourceGroupName', 'connectorNamespaceName', 'connectorNamespaceConnectionName', 'functionAppName', 'triggerConfigSettings', 'triggerDefinitions')) {
    if ($null -eq $outputs.$key -or [string]::IsNullOrWhiteSpace([string]$outputs.$key)) { throw "Missing azd output $key. Run azd provision first." }
}
$settings = if ($outputs.triggerConfigSettings -is [string]) { $outputs.triggerConfigSettings | ConvertFrom-Json } else { $outputs.triggerConfigSettings }
$definitions = if ($outputs.triggerDefinitions -is [string]) { $outputs.triggerDefinitions | ConvertFrom-Json } else { $outputs.triggerDefinitions }
if ($definitions.Count -ne 3) { throw 'Incomplete Planner trigger definitions.' }
$values = @{ AzureWebJobsStorage = 'UseDevelopmentStorage=true'; FUNCTIONS_WORKER_RUNTIME = 'dotnet-isolated' }
foreach ($trigger in (Get-Content (Join-Path $PSScriptRoot '../triggers.json') -Raw | ConvertFrom-Json)) {
    $disabled = "AzureWebJobs.$($trigger.functionName).Disabled"
    if ($settings.$disabled -notin @('true', 'false')) { throw "Invalid local configuration for $($trigger.functionName)." }
    $values[$disabled] = $settings.$disabled
}
Publish-LocalSettings -Path (Join-Path $PSScriptRoot '../../local.settings.json') -Values $values
if ($LocalSettingsOnly) { return }
if ([string]::IsNullOrWhiteSpace($outputs.AZURE_SUBSCRIPTION_ID)) { throw 'Missing AZURE_SUBSCRIPTION_ID.' }
$existing = az connector-namespace trigger list -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName --query '[].name' -o json
if ($LASTEXITCODE -ne 0) { throw 'Could not list Planner triggers.' }
$existingNames = ($existing -join "`n") | ConvertFrom-Json
if (-not $CallbackBaseUrl) {
    if ([string]::IsNullOrWhiteSpace($outputs.functionAppDefaultHostname)) { throw 'Missing functionAppDefaultHostname.' }
    $ConnectorExtensionKey = az functionapp keys list -g $outputs.resourceGroupName -n $outputs.functionAppName --query 'systemKeys.connector_extension' -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ConnectorExtensionKey)) { throw 'Could not retrieve connector_extension system key. Deploy the app first.' }
    $CallbackBaseUrl = "https://$($outputs.functionAppDefaultHostname)"
}
foreach ($trigger in $definitions) {
    $name = "planner-$($trigger.functionName.ToLowerInvariant())"
    if (-not $trigger.enabled) {
        if ($name -in $existingNames) {
            az connector-namespace trigger update -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName -n $name --state Disabled -o none
            if ($LASTEXITCODE -ne 0) { throw "Could not disable trigger $name." }
        }
        continue
    }
    $notificationFile = Join-Path $PSScriptRoot ".notification-$([Guid]::NewGuid().ToString('N')).json"
    $parametersFile = Join-Path $PSScriptRoot ".parameters-$([Guid]::NewGuid().ToString('N')).json"
    $owned = [Collections.Generic.List[string]]::new()
    $failure = $null
    try {
        $documents = @(
            @{ path = $notificationFile; value = @{
                callbackUrl = "$($CallbackBaseUrl.TrimEnd('/'))/runtime/webhooks/connector?functionName=$($trigger.functionName)"
                authentication = @{ type = 'QueryString'; name = 'code'; value = $ConnectorExtensionKey }
            } },
            @{ path = $parametersFile; value = @($trigger.parameters) }
        )
        foreach ($document in $documents) {
            $stream = New-PrivateStagingStream $document.path
            $owned.Add($document.path)
            $streamFailure = $null
            try { Write-PrivateStagingJson $stream $document.value }
            catch { $streamFailure = $_; throw }
            finally { Close-PrivateStagingStream -Stream $stream -PrimaryFailure $streamFailure }
        }
        $verb = if ($name -in $existingNames) { 'update' } else { 'create' }
        $metadata = @{
            recurrenceFrequency='Minute'; recurrenceInterval='6'
        }
        if (-not $localCallback) {
            $metadata += @{
                destinationType='functionApp'; functionAppName=$outputs.functionAppName
                functionAppResourceGroup=$outputs.resourceGroupName; functionAppSubscriptionId=$outputs.AZURE_SUBSCRIPTION_ID
                functionName=$trigger.functionName
            }
        }
        az connector-namespace trigger $verb -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName -n $name `
            --connection-details "{connectionName:$($outputs.connectorNamespaceConnectionName),connectorName:planner}" `
            --operation-name $trigger.operationName --parameters "@$parametersFile" --notification-details "@$notificationFile" `
            --description $trigger.description --state Enabled `
            --metadata ($metadata | ConvertTo-Json -Compress) -o none 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Could not configure Planner trigger $name." }
    } catch { $failure = $_; throw }
    finally { Clear-OwnedStagingFiles -Paths $owned.ToArray() -PrimaryFailure $failure }
}
function Get-ConnectionStatus {
    $status = az connector-namespace connection show -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName -n $outputs.connectorNamespaceConnectionName --query 'properties.overallStatus' -o tsv
    if ($LASTEXITCODE -ne 0) { throw 'Could not read Planner OAuth connection status.' }
    return $status
}
if ((Get-ConnectionStatus) -eq 'Connected') { Write-Host 'Planner connection already authorized.'; return }
$link = az connector-namespace connection list-consent-links -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName --connection-name $outputs.connectorNamespaceConnectionName --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" --query 'value[0].link || link' -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($link) -or $link -eq 'null') { throw 'Could not obtain Planner OAuth consent link.' }
Write-Host "Authorize with a Planner-enabled account that belongs to the selected group. Open: $link"
$deadline = (Get-Date).AddMinutes(5)
do {
    Start-Sleep -Seconds 3
    if ((Get-ConnectionStatus) -eq 'Connected') { Write-Host 'Planner OAuth connection authorized.'; return }
} while ((Get-Date) -lt $deadline)
throw 'Timed out waiting for Planner OAuth consent.'
