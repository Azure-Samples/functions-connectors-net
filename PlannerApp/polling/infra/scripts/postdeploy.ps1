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

$existing = az connector-namespace trigger list -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName --query '[].name' -o json
if ($LASTEXITCODE -ne 0) { throw 'Could not list Planner triggers.' }
$existingNames = ($existing -join "`n") | ConvertFrom-Json
foreach ($trigger in $definitions | Where-Object { -not $_.enabled }) {
    $name = "planner-$($trigger.functionName.ToLowerInvariant())"
    if ($name -in $existingNames) {
        az connector-namespace trigger update -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName -n $name --state Disabled -o none
        if ($LASTEXITCODE -ne 0) { throw "Could not disable trigger $name." }
    }
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
