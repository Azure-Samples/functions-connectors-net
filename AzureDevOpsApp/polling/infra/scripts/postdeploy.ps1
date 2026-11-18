$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-settings.ps1')
$raw = azd env get-values --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected azd environment.' }
$outputs = ($raw -join "`n") | ConvertFrom-Json
foreach ($name in @('resourceGroupName', 'connectorNamespaceName', 'connectorPollingEndpoint', 'AZURE_SUBSCRIPTION_ID', 'triggerConfigSettings', 'triggerDefinitions')) {
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
$raw = az connector-namespace trigger list --subscription $outputs.AZURE_SUBSCRIPTION_ID -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName --query '[].{name:name,id:id}' -o json 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Could not list existing Poll trigger configurations.' }
$existing = ($raw -join "`n") | ConvertFrom-Json
foreach ($trigger in $triggers | Where-Object { -not $_.enabled }) {
    $name = "azuredevops-$($trigger.functionName.ToLowerInvariant())"
    $matches = @($existing | Where-Object name -EQ $name)
    if ($matches.Count -eq 0) { continue }
    $id = "/subscriptions/$($outputs.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($outputs.resourceGroupName)/providers/Microsoft.Web/connectorGateways/$($outputs.connectorNamespaceName)/triggerConfigs/$name"
    if ($matches.Count -ne 1 -or $matches[0].id -ine $id) { throw "Invalid resource ID for Poll trigger $name." }
    $uri = "https://management.azure.com$($matches[0].id)?api-version=2026-05-01-preview"
    $path = Join-Path ([IO.Path]::GetTempPath()) "azuredevops-poll-update-$([guid]::NewGuid()).json"
    $owned = $false
    $failure = $null
    try {
        $stream = New-PrivateStagingStream $path
        $owned = $true
        $stream.Dispose()
        az rest --method get --url $uri --output-file $path -o none 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Could not read Poll trigger $name." }
        $current = [System.Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false, $true)))
        if ($current -isnot [System.Text.Json.Nodes.JsonObject]) { throw "Invalid response for Poll trigger $name." }
        $properties = $current['properties']
        if ($properties -isnot [System.Text.Json.Nodes.JsonObject] -or $null -eq $properties['deliveryMode'] -or $properties['deliveryMode'].ToString() -cne 'Poll') {
            throw "Expected Poll delivery mode for trigger $name."
        }
        $null = $properties.Remove('provisioningState')
        $null = $properties.Remove('pollingEndpoints')
        $properties['state'] = [System.Text.Json.Nodes.JsonValue]::Create('Disabled')
        $null = $current.Remove('properties')
        $body = [System.Text.Json.Nodes.JsonObject]::new()
        $body.Add('properties', $properties)
        $stream = [IO.File]::Open($path, [IO.FileMode]::Truncate, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $json = $body.ToJsonString()
            $stream.Write([Text.UTF8Encoding]::new($false).GetBytes($json))
        } catch { $failure = $_; throw }
        finally {
            try { $stream.Dispose() }
            catch {
                if ($null -eq $failure) { throw }
                Write-Warning 'Could not close Poll update staging stream; original failure preserved.'
            }
        }
        az rest --method put --url $uri --body "@$path" --headers Content-Type=application/json -o none 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Could not stop disabled trigger $name." }
    } catch { $failure = $_; throw }
    finally {
        if ($owned) {
            try { [IO.File]::Delete($path) }
            catch {
                if ($null -eq $failure) { throw 'Could not clean owned Poll update staging file.' }
                Write-Warning 'Could not clean owned Poll update staging file; original failure preserved.'
            }
        }
    }
}
Write-Host 'Authorize the Azure DevOps connection separately using a supported authentication type. No consent is performed by this hook.'
