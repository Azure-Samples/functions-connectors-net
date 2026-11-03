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
$outputs = ($raw -join "`n") | ConvertFrom-Json

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
    @{ functionName = 'OnDataverseActionPerformed' }
    @{ functionName = 'OnDataverseRowAdded' }
    @{ functionName = 'OnDataverseRowModified' }
    @{ functionName = 'OnDataverseRowDeleted' }
)
$disabledTriggers = @()
foreach ($trigger in $optionalTriggers) {
    $setting = "AzureWebJobs.$($trigger.functionName).Disabled"
    if ([string]$triggerSettings.$setting -notin @('true', 'false')) {
        throw "Missing or invalid $setting in triggerConfigSettings."
    }
    $localValues[$setting] = [string]$triggerSettings.$setting
    if ([string]$triggerSettings.$setting -eq 'true') { $disabledTriggers += $trigger }
}
$actionContext = Get-DataverseActionContext $outputs Poll
$actionJournal = Get-DataverseActionJournal (Join-Path $PSScriptRoot '../..') $actionContext
$actionDisabled = $localValues['AzureWebJobs.OnDataverseActionPerformed.Disabled'] -eq 'true'
if ($disabledTriggers.Count -gt 0 -or -not $actionDisabled) {
    $uri = "https://management.azure.com/subscriptions/$($outputs.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($outputs.resourceGroupName)/providers/Microsoft.Web/connectorGateways/$($outputs.connectorNamespaceName)/triggerConfigs"
    $raw = az rest --method get --url "${uri}?api-version=2026-05-01-preview" `
        --query '{value:value[].{id:id,name:name,properties:{connectionDetails:properties.connectionDetails,operationName:properties.operationName,parameters:properties.parameters,deliveryMode:properties.deliveryMode,notificationDetails:{callbackUrl:properties.notificationDetails.callbackUrl}}}}' -o json
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect existing Dataverse subscriptions.' }
    $configs = ($raw -join "`n") | ConvertFrom-Json
    $actionConfigs = @($configs.value | Where-Object name -EQ $actionContext.triggerName)
    if ($actionConfigs.Count -gt 1) { throw 'Ambiguous Dataverse action configuration.' }
    if (-not $actionDisabled -and $actionConfigs.Count -eq 0) {
        throw 'Enabled Dataverse action configuration is missing. Run azd provision first.'
    }
    Protect-DataverseActionRegistration $actionContext $actionJournal $actionConfigs[0] $outputs
    foreach ($trigger in $disabledTriggers) {
        $name = "dataverse-$($trigger.functionName.ToLowerInvariant())"
        $existing = @($configs.value | Where-Object name -eq $name)
        if ($existing.Count -gt 0) {
            az rest --method delete --url "$uri/${name}?api-version=2026-05-01-preview" -o none
            if ($LASTEXITCODE -ne 0) { throw "Could not remove disabled Dataverse subscription '$name'." }
            Write-Host "Removed Connector Namespace configuration '$name' because its function is disabled."
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

if ((Get-ConnectionStatus) -eq 'Connected') {
    Write-Host 'Dataverse connection is already authorized.'
    if ($actionDisabled) { Assert-DataverseActionSourceCleanup $actionJournal }
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
        Write-Host 'Dataverse connection authorized. The Poll trigger configuration is provisioned.'
        if ($actionDisabled) { Assert-DataverseActionSourceCleanup $actionJournal }
        return
    }
} while ((Get-Date) -lt $deadline)

throw 'Timed out waiting for the Dataverse connection to become Connected.'
