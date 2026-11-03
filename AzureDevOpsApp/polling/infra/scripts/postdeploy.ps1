$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-settings.ps1')
$raw = azd env get-values --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected azd environment.' }
$outputs = ($raw -join "`n") | ConvertFrom-Json
foreach ($name in @('resourceGroupName', 'connectorNamespaceName', 'connectorPollingEndpoint', 'triggerConfigSettings', 'triggerDefinitions')) {
    $value = $outputs.$name
    if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) { throw "Missing azd output $name." }
}
$settings = if ($outputs.triggerConfigSettings -is [string]) { $outputs.triggerConfigSettings | ConvertFrom-Json } else { $outputs.triggerConfigSettings }
$triggers = if ($outputs.triggerDefinitions -is [string]) { $outputs.triggerDefinitions | ConvertFrom-Json } else { $outputs.triggerDefinitions }
if (@($triggers).Count -ne 9) { throw 'Expected nine Azure DevOps trigger definitions.' }
$values = @{
    FUNCTIONS_WORKER_RUNTIME = 'dotnet-isolated'
    AzureWebJobsStorage = 'UseDevelopmentStorage=true'
    ConnectorNamespace__pollingEndpoint = [string]$outputs.connectorPollingEndpoint
}
foreach ($trigger in $triggers) {
    $name = "$($trigger.functionName)TriggerConfigName"
    $disabled = "AzureWebJobs.$($trigger.functionName).Disabled"
    if ([string]::IsNullOrWhiteSpace($settings.$name) -or $settings.$disabled -notin @('true', 'false')) {
        throw "Invalid trigger settings for $($trigger.functionName)."
    }
    $values[$name] = [string]$settings.$name
    $values[$disabled] = [string]$settings.$disabled
}
Write-LocalSettings $values
$raw = az connector-namespace trigger list -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName --query '[].name' -o json 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Could not list existing Poll trigger configurations.' }
$existing = ($raw -join "`n") | ConvertFrom-Json
foreach ($trigger in $triggers | Where-Object { -not $_.enabled }) {
    $name = "azuredevops-$($trigger.functionName.ToLowerInvariant())"
    if ($name -in $existing) {
        az connector-namespace trigger update -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName -n $name --state Disabled -o none 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Could not stop disabled trigger $name." }
    }
}
Write-Host 'Authorize the Azure DevOps connection separately using a supported authentication type. No consent is performed by this hook.'
