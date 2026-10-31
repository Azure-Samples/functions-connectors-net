param([switch] $ForceLocalSettings)

$ErrorActionPreference = 'Stop'

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
    'OnDataverseRowChanged', 'OnDataverseActionPerformed')) {
    $setting = "${functionName}TriggerConfigName"
    if ([string]::IsNullOrWhiteSpace($triggerSettings.$setting)) {
        throw "Missing $setting in triggerConfigSettings."
    }
    $localValues[$setting] = $triggerSettings.$setting
}
$disabledSetting = 'AzureWebJobs.OnDataverseActionPerformed.Disabled'
if ([string]::IsNullOrWhiteSpace([string]$triggerSettings.$disabledSetting)) {
    throw "Missing $disabledSetting in triggerConfigSettings."
}
$localValues[$disabledSetting] = [string]$triggerSettings.$disabledSetting
if ([string]$triggerSettings.$disabledSetting -eq 'true') {
    $name = 'dataverse-ondataverseactionperformed'
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
$localSettingsPath = Join-Path $PSScriptRoot '../../local.settings.json'
if ((Test-Path -LiteralPath $localSettingsPath) -and -not $ForceLocalSettings) {
    Write-Host 'Existing local.settings.json preserved. Use -ForceLocalSettings to regenerate it.'
} else {
    $localSettings = @{ IsEncrypted = $false; Values = $localValues }
    [IO.File]::WriteAllText(
        $localSettingsPath,
        ($localSettings | ConvertTo-Json -Depth 4),
        [Text.UTF8Encoding]::new($false))
    Write-Host 'Created ignored local.settings.json using developer credentials and Azurite.'
}

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
        return
    }
} while ((Get-Date) -lt $deadline)

throw 'Timed out waiting for the Dataverse connection to become Connected.'
