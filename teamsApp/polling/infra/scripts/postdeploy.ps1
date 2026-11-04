param([switch] $ForceLocalSettings)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-settings.ps1')
& (Join-Path $PSScriptRoot 'validate-triggers.ps1')

if (-not (az extension show --name connector-namespace --query name -o tsv 2>$null)) {
    throw "Install the connector-namespace Azure CLI extension before running this script."
}

$raw = azd env get-values --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected azd environment.' }
$outputs = ($raw -join "`n") | ConvertFrom-Json

foreach ($name in @(
    'resourceGroupName', 'connectorNamespaceName', 'connectorNamespaceConnectionName',
    'connectorPollingEndpoint', 'triggerConfigSettings')) {
    if ([string]::IsNullOrWhiteSpace([string]$outputs.$name)) {
        throw "Missing azd output $name. Run azd provision first."
    }
}

# azd serializes object-valued deployment outputs as JSON environment values.
$triggerSettings = if ($outputs.triggerConfigSettings -is [string]) {
    $outputs.triggerConfigSettings | ConvertFrom-Json
} else {
    $outputs.triggerConfigSettings
}

$localValues = @{
    AzureWebJobsStorage = 'UseDevelopmentStorage=true'
    FUNCTIONS_WORKER_RUNTIME = 'dotnet-isolated'
    ConnectorNamespace__pollingEndpoint = $outputs.connectorPollingEndpoint
}
foreach ($functionName in @(
    'OnNewChannelMessage', 'OnNewChannelMessageMentioningMe', 'OnGroupMembershipAdd', 'OnGroupMembershipRemoval',
    'WebhookChatMessageTrigger', 'WebhookNewMessageTrigger', 'WebhookAtMentionTrigger', 'WebhookKeywordTrigger',
    'WebhookMessageReactionTrigger', 'RecordingTrigger', 'TranscriptTrigger')) {
    $setting = "${functionName}TriggerConfigName"
    if ([string]::IsNullOrWhiteSpace($triggerSettings.$setting)) {
        throw "Missing trigger configuration setting $setting."
    }
    $localValues[$setting] = $triggerSettings.$setting
}
foreach ($functionName in @(
    'WebhookChatMessageTrigger', 'WebhookNewMessageTrigger', 'WebhookAtMentionTrigger', 'WebhookKeywordTrigger',
    'WebhookMessageReactionTrigger', 'RecordingTrigger', 'TranscriptTrigger')) {
    $setting = "AzureWebJobs.$functionName.Disabled"
    if ($triggerSettings.$setting -notin @('true', 'false')) {
        throw "Missing or invalid function enablement setting $setting."
    }
    $localValues[$setting] = $triggerSettings.$setting
}

Write-LocalSettings $localValues -Force:$ForceLocalSettings

$optionalOperations = @(
    'WebhookChatMessageTrigger', 'WebhookNewMessageTrigger', 'WebhookAtMentionTrigger', 'WebhookKeywordTrigger',
    'WebhookMessageReactionTrigger', 'RecordingTrigger', 'TranscriptTrigger')
$deselectedOperations = @($optionalOperations | Where-Object {
    $triggerSettings."AzureWebJobs.$_.Disabled" -eq 'true'
})
if ($deselectedOperations.Count -gt 0) {
    $namespaceId = az resource show -g $outputs.resourceGroupName -n $outputs.connectorNamespaceName `
        --resource-type Microsoft.Web/connectorGateways --api-version 2026-05-01-preview --query id -o tsv
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the Teams Connector Namespace resource ID.' }
    $expectedScope = '/resourceGroups/' + [regex]::Escape($outputs.resourceGroupName) +
        '/providers/Microsoft.Web/connectorGateways/' + [regex]::Escape($outputs.connectorNamespaceName)
    if ($namespaceId -notmatch "^/subscriptions/[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$expectedScope$" -or
        $outputs.resourceGroupName -match '[/\\?#]' -or $outputs.connectorNamespaceName -match '[/\\?#]') {
        throw 'Invalid Teams Connector Namespace resource ID.'
    }
    foreach ($operation in $deselectedOperations) {
        $triggerName = "teams-$($operation.ToLowerInvariant())"
        $uri = "$namespaceId/triggerConfigs/${triggerName}?api-version=2026-05-01-preview"
        $readTemp = Join-Path ([IO.Path]::GetTempPath()) "teams-poll-read-$([guid]::NewGuid().ToString('N')).json"
        $temp = Join-Path ([IO.Path]::GetTempPath()) "teams-poll-state-$([guid]::NewGuid().ToString('N')).json"
        $ownedFiles = @()
        $failure = $null
        try {
            $stream = New-PrivateStagingStream $readTemp
            $ownedFiles += $readTemp
            $stream.Dispose()
            $response = az rest --method get --url $uri --output-file $readTemp -o none 2>&1
            if ($LASTEXITCODE -ne 0) {
                if (($response -join "`n") -match '(?m)^ERROR:\s+Not Found\(|\((ResourceNotFound|NotFound)\)') { continue }
                throw "Could not read optional Teams Poll configuration $triggerName`: $($response -join "`n")"
            }
            $config = [System.Text.Json.Nodes.JsonNode]::Parse(
                [IO.File]::ReadAllText($readTemp, [Text.UTF8Encoding]::new($false, $true)))
            $properties = $config['properties']
            if ($properties -isnot [System.Text.Json.Nodes.JsonObject] -or
                [string]$properties['deliveryMode'] -ne 'Poll' -or [string]$properties['operationName'] -ne $operation -or
                [string]$properties['connectionDetails']['connectorName'] -ne 'teams' -or
                [string]$properties['connectionDetails']['connectionName'] -ne $outputs.connectorNamespaceConnectionName) {
                throw "Optional Teams configuration $triggerName is not the expected sample Poll configuration."
            }
            if ([string]$properties['state'] -eq 'Disabled') { continue }
            $properties.Remove('provisioningState') | Out-Null
            $properties.Remove('pollingEndpoints') | Out-Null
            $properties['state'] = [System.Text.Json.Nodes.JsonValue]::Create('Disabled')
            $config.Remove('properties') | Out-Null
            $body = [System.Text.Json.Nodes.JsonObject]::new()
            $body.Add('properties', $properties)
            $stream = New-PrivateStagingStream $temp
            $ownedFiles += $temp
            try {
                $bytes = [Text.UTF8Encoding]::new($false).GetBytes($body.ToJsonString())
                $stream.Write($bytes)
            } finally { $stream.Dispose() }
            az rest --method put --url $uri --body "@$temp" --headers Content-Type=application/json -o none
            if ($LASTEXITCODE -ne 0) { throw "Could not disable optional Teams Poll configuration $triggerName." }
            Write-Host "Disabled deselected Teams Poll configuration $triggerName."
        } catch { $failure = $_; throw }
        finally {
            $cleanupFailed = $false
            foreach ($path in $ownedFiles) {
                try { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
                catch {
                    $cleanupFailed = $true
                    Write-Warning 'Could not clean owned Poll configuration staging file.'
                }
            }
            if ($cleanupFailed -and $null -eq $failure) { throw 'Could not clean owned Poll configuration staging files.' }
        }
    }
}

function Get-ConnectionStatus {
    $status = az connector-namespace connection show `
        -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName `
        -n $outputs.connectorNamespaceConnectionName `
        --query 'properties.overallStatus' -o tsv
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the Teams connection status.' }
    return $status
}

if ((Get-ConnectionStatus) -eq 'Connected') {
    Write-Host 'Teams connection is already authorized.'
    return
}

Write-Host 'Authorize the Teams connection with the account whose teams to monitor.'
$consentLink = $null
for ($attempt = 1; $attempt -le 5; $attempt++) {
    $consentLink = az connector-namespace connection list-consent-links `
        -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName `
        --connection-name $outputs.connectorNamespaceConnectionName `
        --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" `
        --query 'value[0].link' -o tsv 2>$null

    if (-not $consentLink -or $consentLink -eq 'null') {
        $consentLink = az connector-namespace connection list-consent-links `
            -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName `
            --connection-name $outputs.connectorNamespaceConnectionName `
            --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" `
            --query 'link' -o tsv 2>$null
    }
    if ($consentLink -and $consentLink -ne 'null') { break }
    if ($attempt -lt 5) { Start-Sleep -Seconds 5 }
}

if (-not $consentLink -or $consentLink -eq 'null') {
    throw 'Could not obtain a Teams consent link.'
}

Write-Host "Consent URL: $consentLink"
try {
    Start-Process $consentLink | Out-Null
} catch {
    Write-Host 'Open the consent URL in your browser.'
}

$deadline = (Get-Date).AddMinutes(5)
do {
    Start-Sleep -Seconds 3
    if ((Get-ConnectionStatus) -eq 'Connected') {
        Write-Host 'Teams connection authorized. Poll trigger configurations are provisioned for the selected events.'
        return
    }
} while ((Get-Date) -lt $deadline)

throw 'Timed out waiting for the Teams connection to become Connected.'
