#requires -Version 7.3
param([switch] $ForceLocalSettings)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-settings.ps1')
. (Join-Path $PSScriptRoot 'action-cleanup.ps1')

if (-not (az extension show --name connector-namespace --query name -o tsv 2>$null)) {
    throw 'Install the connector-namespace Azure CLI extension before running this script.'
}

$raw = azd env get-values --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected azd environment.' }
$outputsJson = $raw -join "`n"
$outputs = $outputsJson | ConvertFrom-Json

foreach ($name in @(
    'resourceGroupName', 'connectorNamespaceName', 'connectorNamespaceConnectionName',
    'connectorPollingEndpoint', 'triggerConfigSettings', 'AZURE_SUBSCRIPTION_ID')) {
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
    'OnDataverseRowChanged', 'OnDataverseActionPerformed',
    'OnDataverseRowAdded', 'OnDataverseRowModified', 'OnDataverseRowDeleted')) {
    $setting = "${functionName}TriggerConfigName"
    if ([string]::IsNullOrWhiteSpace($triggerSettings.$setting)) {
        throw "Missing $setting in triggerConfigSettings."
    }
    $localValues[$setting] = $triggerSettings.$setting
}
$optionalTriggers = @(
    @{ functionName = 'OnDataverseActionPerformed'; operationName = 'BusinessEventsTrigger' }
    @{ functionName = 'OnDataverseRowAdded'; operationName = 'GetOnNewItems_V2' }
    @{ functionName = 'OnDataverseRowModified'; operationName = 'GetOnUpdatedItems_V2' }
    @{ functionName = 'OnDataverseRowDeleted'; operationName = 'GetOnDeletedItems_V2' }
)
foreach ($trigger in $optionalTriggers) {
    $setting = "AzureWebJobs.$($trigger.functionName).Disabled"
    if ([string]$triggerSettings.$setting -notin @('true', 'false')) {
        throw "Missing or invalid $setting in triggerConfigSettings."
    }
    $localValues[$setting] = [string]$triggerSettings.$setting
}
$actionContext = Get-DataverseActionContext $outputs Poll
$actionJournal = Get-DataverseActionJournal (Join-Path $PSScriptRoot '../..') $actionContext
$uri = "https://management.azure.com/subscriptions/$($outputs.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($outputs.resourceGroupName)/providers/Microsoft.Web/connectorGateways/$($outputs.connectorNamespaceName)/triggerConfigs"
$inventoryFile = Join-Path ([IO.Path]::GetTempPath()) "dataverse-poll-inventory-$([Guid]::NewGuid().ToString('N')).json"
$inventoryOwned = $false
$inventoryFailure = $null
try {
    $stream = New-PrivateStagingStream $inventoryFile
    $inventoryOwned = $true
    $stream.Dispose()
    # Read the raw response; Windows CLI console output can discard Unicode.
    az rest --method get --url "${uri}?api-version=2026-05-01-preview" --output-file $inventoryFile -o none 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect existing Dataverse subscriptions.' }
    $inventoryJson = Get-Content -LiteralPath $inventoryFile -Raw -Encoding utf8
} catch {
    $inventoryFailure = $_
    throw
} finally {
    try {
        if ($inventoryOwned -and [IO.File]::Exists($inventoryFile)) { [IO.File]::Delete($inventoryFile) }
    } catch {
        if ($null -eq $inventoryFailure) { throw 'Could not clean private Dataverse inventory staging file.' }
        Write-Warning 'Could not clean private inventory staging file; original failure preserved.'
    }
}
$jsonOptions = [System.Text.Json.JsonDocumentOptions]::new()
$jsonOptions.MaxDepth = 100
$inventoryDom = [System.Text.Json.Nodes.JsonNode]::Parse($inventoryJson, $null, $jsonOptions)
$serializerOptions = [System.Text.Json.JsonSerializerOptions]::new()
$serializerOptions.MaxDepth = 100
$configNodes = @{}
foreach ($node in $inventoryDom['value'].AsArray()) {
    $configNodes[$node['name'].ToString()] = $node
}
$configs = $inventoryJson | ConvertFrom-Json -AsHashtable
foreach ($trigger in $optionalTriggers) {
    $name = $triggerSettings."$($trigger.functionName)TriggerConfigName"
    $desiredState = if ($localValues["AzureWebJobs.$($trigger.functionName).Disabled"] -eq 'true') { 'Disabled' } else { 'Enabled' }
    $existing = @($configs.value | Where-Object name -CEQ $name)
    if ($existing.Count -gt 1) { throw "Ambiguous Dataverse configuration '$name'." }
    $creating = $existing.Count -eq 0
    $isAction = $trigger.operationName -eq 'BusinessEventsTrigger'
    if ($creating) {
        if ($desiredState -eq 'Disabled') { continue }
        if (-not $isAction) { throw "Selected Dataverse configuration '$name' is missing. Run azd provision first." }
    }
    $config = if ($creating) { $null } else { $existing[0] }
    if (-not $creating) {
        $properties = $config.properties
        $destination = $properties.metadata
        if ($config.id -ine "$uri/$name".Replace('https://management.azure.com', '') -or
            $properties.deliveryMode -cne 'Poll' -or
            $properties.operationName -cne $trigger.operationName -or
            $properties.connectionDetails.connectionName -cne $outputs.connectorNamespaceConnectionName -or
            $properties.connectionDetails.connectorName -cne 'commondataservice' -or
            $destination.destinationType -cne 'functionApp' -or
            $destination.functionAppName -ine $outputs.functionAppName -or
            $destination.functionAppResourceGroup -ine $outputs.resourceGroupName -or
            $destination.functionAppSubscriptionId -ine $outputs.AZURE_SUBSCRIPTION_ID -or
            $destination.functionName -cne $trigger.functionName) {
            throw "Refusing to change Dataverse configuration '$name' with a different source or destination binding."
        }
    }
    if ($isAction) {
        if ($name -cne $actionContext.triggerName) { throw 'Unexpected Dataverse action configuration name.' }
        if ($desiredState -eq 'Enabled') {
            $desiredSelectors = [ordered]@{ organization = $outputs.dataverseEnvironmentUrl.TrimEnd('/') }
            $outputDom = [System.Text.Json.Nodes.JsonNode]::Parse($outputsJson, $null, $jsonOptions)
            foreach ($pair in @(
                @('catalog', 'eventCatalog'), @('category', 'eventCategory'),
                @('entityname', 'eventTable'), @('sdkmessagename', 'eventAction'))) {
                $value = $outputDom[$pair[1]]
                if ($null -eq $value -or [string]::IsNullOrWhiteSpace($value.GetValue[string]())) {
                    throw "Missing action selector $($pair[1]). Run azd provision first."
                }
                $outputs.($pair[1]) = $value.GetValue[string]()
                $desiredSelectors[$pair[0]] = $outputs.($pair[1])
            }
            if (-not $creating) {
                $currentSelectors = @{}
                foreach ($parameter in $properties.parameters) {
                    if ($currentSelectors.ContainsKey($parameter.name)) { throw 'Ambiguous Dataverse action selector.' }
                    $currentSelectors[$parameter.name] = [string]$parameter.value
                }
                Assert-DataverseActionContext $desiredSelectors $currentSelectors
            }
        }
        Protect-DataverseActionRegistration $actionContext $actionJournal $config $outputs -BeforeCreate:($desiredState -eq 'Enabled')
    } else {
        if ([string]::IsNullOrWhiteSpace([string]$outputs.dataverseEntitySetName)) {
            throw 'Missing dataverseEntitySetName output. Run azd provision before reconciling separate row configurations.'
        }
        if (@($properties.parameters).Count -ne 2) { throw "Unexpected Dataverse selectors for '$name'." }
        $expected = @{ dataset = $outputs.dataverseEnvironmentUrl.TrimEnd('/'); table = $outputs.dataverseEntitySetName }
        $selectors = @{}
        foreach ($parameter in $properties.parameters) {
            if ($selectors.ContainsKey($parameter.name)) { throw "Ambiguous Dataverse selector for '$name'." }
            $selectors[$parameter.name] = $parameter.value
        }
        Assert-DataverseActionContext $expected $selectors
    }
    if (-not $creating -and $properties.state -ceq $desiredState) { continue }
    if ($creating) {
        $parameters = @(
            foreach ($selector in $desiredSelectors.Keys) { @{ name = $selector; value = $desiredSelectors[$selector] } }
        )
        $newBody = @{
            properties = @{
                connectionDetails = @{ connectionName = $outputs.connectorNamespaceConnectionName; connectorName = 'commondataservice' }
                deliveryMode = 'Poll'
                operationName = $trigger.operationName
                parameters = $parameters
                metadata = @{
                    destinationType = 'functionApp'
                    functionAppName = $outputs.functionAppName
                    functionAppResourceGroup = $outputs.resourceGroupName
                    functionAppSubscriptionId = $outputs.AZURE_SUBSCRIPTION_ID
                    functionName = $trigger.functionName
                }
                state = 'Enabled'
                type = 'NotSpecified'
                description = 'Current Dataverse action-performed operation with Poll delivery.'
            }
        }
        $body = [System.Text.Json.Nodes.JsonNode]::Parse(($newBody | ConvertTo-Json -Depth 10), $null, $jsonOptions)
    } else {
        # Keep existing request values in the JSON DOM; PowerShell converts ISO-looking strings to dates.
        $body = [System.Text.Json.Nodes.JsonNode]::Parse(
            '{"properties":' + $configNodes[$name]['properties'].ToJsonString($serializerOptions) + '}', $null, $jsonOptions)
    }
    [void]$body['properties'].AsObject().Remove('provisioningState')
    [void]$body['properties'].AsObject().Remove('pollingEndpoints')
    $body['properties']['state'] = [System.Text.Json.Nodes.JsonValue]::Create([string]$desiredState)
    $bodyJson = $body.ToJsonString($serializerOptions)
    $bodyFile = Join-Path ([IO.Path]::GetTempPath()) "dataverse-poll-state-$([Guid]::NewGuid().ToString('N')).json"
    $owned = $false
    $failure = $null
    try {
        $stream = New-PrivateStagingStream $bodyFile
        $owned = $true
        $writeFailure = $null
        try {
            $stream.Write([Text.UTF8Encoding]::new($false).GetBytes($bodyJson))
            $stream.Flush($true)
        } catch {
            $writeFailure = $_
            throw
        } finally {
            try { $stream.Dispose() } catch {
                if ($null -eq $writeFailure) { throw 'Could not close private Dataverse state-update staging stream.' }
                Write-Warning 'Could not close private state-update staging stream; original failure preserved.'
            }
        }
        az rest --method put --url "$uri/${name}?api-version=2026-05-01-preview" --body "@$bodyFile" -o none 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Could not set Dataverse configuration '$name' to $desiredState; inspect Connector Namespace before retrying." }
        $raw = az rest --method get --url "$uri/${name}?api-version=2026-05-01-preview" `
            --query '{state:properties.state,deliveryMode:properties.deliveryMode}' -o json 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Could not verify Dataverse configuration '$name' after its state update." }
        $updated = ($raw -join "`n") | ConvertFrom-Json
        if ($updated.state -cne $desiredState -or $updated.deliveryMode -cne 'Poll') {
            throw "Dataverse configuration '$name' did not retain the requested state and Poll delivery."
        }
        Write-Host "Dataverse configuration '$name' is $desiredState; its namespace configuration was retained."
    } catch {
        $failure = $_
        throw
    } finally {
        try {
            if ($owned -and [IO.File]::Exists($bodyFile)) { [IO.File]::Delete($bodyFile) }
        } catch {
            if ($null -eq $failure) { throw 'Could not clean private Dataverse state-update staging file.' }
            Write-Warning 'Could not clean private state-update staging file; original failure preserved.'
        }
    }
}
Write-LocalSettings $localValues -Force:$ForceLocalSettings

function Get-ConnectionStatus {
    $status = az connector-namespace connection show `
        -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName `
        -n $outputs.connectorNamespaceConnectionName `
        --query 'properties.overallStatus' -o tsv
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the Dataverse connection status.' }
    return $status
}

function Check-SourceStatus {
    foreach ($functionName in @('OnDataverseRowChanged') + @($optionalTriggers.functionName | Where-Object { $localValues["AzureWebJobs.$_.Disabled"] -eq 'false' })) {
        $name = $triggerSettings."${functionName}TriggerConfigName"
        $raw = az rest --method get --url "$uri/$name/triggerStatuses/latest?api-version=2026-05-01-preview" `
            --query '{status:lastExecutionStatus,code:lastExecutionStatusCode,started:lastExecutionStartTime,error:lastExecutionError}' -o json 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Could not read source status for '$name'; inspect Connector Namespace before testing events." }
        $status = ($raw -join "`n") | ConvertFrom-Json -AsHashtable
        if ($status.status -eq 'Failed' -or $status.error.Count -gt 0) {
            throw "Dataverse source execution failed for '$name'. Inspect its Connector Namespace trigger status for source registration errors; details were not logged."
        }
        if ($status.started -and ($status.status -eq 'Succeeded' -or
            ($status.status -eq 'Skipped' -and $status.code -in @('Accepted', 'OK')))) {
            Write-Host "Latest source execution succeeded for '$name'; event delivery is not verified."
        } else {
            Write-Warning "Source registration/execution for '$name' is pending or unverified. Rerun the hook after initialization and inspect Connector Namespace before testing events."
        }
    }
}

if ((Get-ConnectionStatus) -eq 'Connected') {
    Write-Host 'Dataverse connection is already authorized.'
    Check-SourceStatus
    return
}

Write-Host 'Authorize Dataverse with an account permitted to register organization-scoped event subscriptions.'
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
    throw 'Could not obtain a Dataverse consent link.'
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
        Check-SourceStatus
        Write-Host 'Dataverse connection authorized. Check the reported source status before testing events.'
        return
    }
} while ((Get-Date) -lt $deadline)

throw 'Timed out waiting for the Dataverse connection to become Connected.'
