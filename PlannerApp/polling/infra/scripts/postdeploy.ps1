param([switch] $LocalSettingsOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-settings.ps1')

$raw = azd env get-values --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected azd environment.' }
$outputs = ($raw -join "`n") | ConvertFrom-Json
foreach ($key in @('resourceGroupName', 'connectorNamespaceName', 'connectorNamespaceConnectionName', 'connectorPollingEndpoint', 'triggerConfigSettings', 'triggerDefinitions')) {
    if ($null -eq $outputs.$key -or [string]::IsNullOrWhiteSpace([string]$outputs.$key)) { throw "Missing azd output $key. Run azd provision first." }
}
$settings = if ($outputs.triggerConfigSettings -is [string]) { $outputs.triggerConfigSettings | ConvertFrom-Json } else { $outputs.triggerConfigSettings }
$definitions = if ($outputs.triggerDefinitions -is [string]) { $outputs.triggerDefinitions | ConvertFrom-Json } else { $outputs.triggerDefinitions }
if ($definitions.Count -ne 3) { throw 'Incomplete Planner trigger definitions.' }
$values = @{
    AzureWebJobsStorage = 'UseDevelopmentStorage=true'
    FUNCTIONS_WORKER_RUNTIME = 'dotnet-isolated'
    ConnectorNamespace__pollingEndpoint = $outputs.connectorPollingEndpoint
}
foreach ($trigger in (Get-Content (Join-Path $PSScriptRoot '../triggers.json') -Raw | ConvertFrom-Json)) {
    $name = "$($trigger.functionName)TriggerConfigName"
    $disabled = "AzureWebJobs.$($trigger.functionName).Disabled"
    if ([string]::IsNullOrWhiteSpace($settings.$name) -or $settings.$disabled -notin @('true', 'false')) { throw "Invalid local configuration for $($trigger.functionName)." }
    $values[$name] = $settings.$name
    $values[$disabled] = $settings.$disabled
}
Publish-LocalSettings -Path (Join-Path $PSScriptRoot '../../local.settings.json') -Values $values
if ($LocalSettingsOnly) { return }

$existing = az connector-namespace trigger list -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName --query '[].{name:name,id:id}' -o json
if ($LASTEXITCODE -ne 0) { throw 'Could not list Planner triggers.' }
$existingConfigs = ($existing -join "`n") | ConvertFrom-Json
foreach ($trigger in $definitions | Where-Object { -not $_.enabled }) {
    $name = "planner-$($trigger.functionName.ToLowerInvariant())"
    $matches = @($existingConfigs | Where-Object { $_.name -eq $name })
    if ($matches.Count -eq 0) { continue }
    if ($matches.Count -ne 1) { throw "Ambiguous Planner trigger $name." }
    $id = $matches[0].id
    $suffix = "/resourceGroups/$($outputs.resourceGroupName)/providers/Microsoft.Web/connectorGateways/$($outputs.connectorNamespaceName)/triggerConfigs/$name"
    if ($id -isnot [string] -or $id -notmatch "^/subscriptions/[^/]+$([regex]::Escape($suffix))$") {
        throw "Missing or invalid resource ID for Planner trigger $name."
    }
    $uri = "https://management.azure.com${id}?api-version=2026-05-01-preview"
    $getFile = Join-Path $PSScriptRoot ".parameters-$([Guid]::NewGuid().ToString('N')).json"
    $bodyFile = Join-Path $PSScriptRoot ".parameters-$([Guid]::NewGuid().ToString('N')).json"
    $owned = @()
    $failure = $null
    try {
        $stream = New-PrivateStagingStream $getFile
        $owned = @($getFile)
        Close-PrivateStagingStream -Stream $stream -PrimaryFailure $null
        az rest --method get --url $uri --output-file $getFile -o none
        if ($LASTEXITCODE -ne 0) { throw "Could not read Planner trigger $name." }
        $rawConfig = [IO.File]::ReadAllText($getFile, [Text.UTF8Encoding]::new($false, $true))
        $config = [System.Text.Json.Nodes.JsonNode]::Parse($rawConfig)
        $properties = $null
        if ($config -is [System.Text.Json.Nodes.JsonObject]) { $properties = $config['properties'] }
        if ($properties -isnot [System.Text.Json.Nodes.JsonObject] -or
            $properties['deliveryMode'] -isnot [System.Text.Json.Nodes.JsonValue] -or $properties['deliveryMode'].ToString() -cne 'Poll' -or
            $properties['connectionDetails'] -isnot [System.Text.Json.Nodes.JsonObject] -or
            $properties['operationName'] -isnot [System.Text.Json.Nodes.JsonValue] -or
            [string]::IsNullOrWhiteSpace($properties['operationName'].ToString()) -or $properties['parameters'] -isnot [System.Text.Json.Nodes.JsonArray]) {
            throw "Planner trigger $name must have a complete Poll configuration."
        }
        [void]$properties.Remove('provisioningState')
        [void]$properties.Remove('pollingEndpoints')
        $properties['state'] = [System.Text.Json.Nodes.JsonNode]::Parse('"Disabled"')
        [void]$config.Remove('properties')
        $body = [System.Text.Json.Nodes.JsonObject]::new()
        $body.Add('properties', $properties)
        $stream = New-PrivateStagingStream $bodyFile
        $owned += $bodyFile
        $streamFailure = $null
        try { Write-PrivateStagingJson -Stream $stream -Value $body }
        catch { $streamFailure = $_; throw }
        finally { Close-PrivateStagingStream -Stream $stream -PrimaryFailure $streamFailure }
        az rest --method put --url $uri --headers 'Content-Type=application/json' --body "@$bodyFile" -o none
        if ($LASTEXITCODE -ne 0) { throw "Could not disable trigger $name." }
    } catch { $failure = $_; throw }
    finally { Clear-OwnedStagingFiles -Paths $owned -PrimaryFailure $failure }
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
