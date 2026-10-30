param([switch] $ForceLocalSettings)

$ErrorActionPreference = 'Stop'

if (-not (az extension show --name connector-namespace --query name -o tsv 2>$null)) {
    throw "Install the connector-namespace Azure CLI extension before running this script."
}

$raw = azd env get-values --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected azd environment.' }
$outputs = ($raw -join "`n") | ConvertFrom-Json

foreach ($name in @(
    'resourceGroupName', 'connectorNamespaceName', 'connectorNamespaceConnectionName',
    'connectorPollingEndpoint', 'triggerConfigSettings', 'triggerDefinitions')) {
    $value = $outputs.$name
    if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
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
foreach ($trigger in (Get-Content (Join-Path $PSScriptRoot '../triggers.json') -Raw | ConvertFrom-Json)) {
    $functionName = $trigger.functionName
    $setting = "${functionName}TriggerConfigName"
    if ([string]::IsNullOrWhiteSpace($triggerSettings.$setting)) {
        throw "Missing trigger configuration setting $setting."
    }
    $localValues[$setting] = $triggerSettings.$setting
    $disabledSetting = "AzureWebJobs.$functionName.Disabled"
    if ($triggerSettings.$disabledSetting -notin @('true', 'false')) {
        throw "Missing or invalid function setting $disabledSetting."
    }
    $localValues[$disabledSetting] = $triggerSettings.$disabledSetting
}

$triggerDefinitions = if ($outputs.triggerDefinitions -is [string]) {
    $outputs.triggerDefinitions | ConvertFrom-Json
} else {
    $outputs.triggerDefinitions
}
if ($triggerDefinitions.Count -ne 10) {
    throw 'Incomplete triggerDefinitions output. Run azd provision first.'
}
$existingTriggers = az connector-namespace trigger list `
    -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName `
    --query '[].name' -o json
if ($LASTEXITCODE -ne 0) { throw 'Could not list existing SharePoint trigger configurations.' }
$existingNames = ($existingTriggers -join "`n") | ConvertFrom-Json
foreach ($trigger in $triggerDefinitions | Where-Object { -not $_.enabled }) {
    $triggerName = "sharepoint-$($trigger.functionName.ToLowerInvariant())"
    if ($triggerName -in $existingNames) {
        az connector-namespace trigger update `
            -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName `
            -n $triggerName --state Disabled -o none
        if ($LASTEXITCODE -ne 0) { throw "Could not disable trigger $triggerName." }
    }
}

$localSettingsPath = Join-Path $PSScriptRoot '../../local.settings.json'
if ((Test-Path -LiteralPath $localSettingsPath) -and -not $ForceLocalSettings) {
    Write-Host 'Existing local.settings.json preserved. Use -ForceLocalSettings to regenerate it.'
}
else {
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
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the SharePoint connection status.' }
    return $status
}

if ((Get-ConnectionStatus) -eq 'Connected') {
    Write-Host 'SharePoint connection is already authorized.'
    return
}

Write-Host 'Authorize the SharePoint connection with an account that can access the monitored site and library.'
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
    throw 'Could not obtain a SharePoint consent link.'
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
        Write-Host 'SharePoint connection authorized. Selected Poll trigger configurations are provisioned.'
        return
    }
} while ((Get-Date) -lt $deadline)

throw 'Timed out waiting for the SharePoint connection to become Connected.'
