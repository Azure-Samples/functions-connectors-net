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
    'connectorPollingEndpoint', 'onUpdatedFileTriggerConfigName')) {
    if ([string]::IsNullOrWhiteSpace([string]$outputs.$name)) {
        throw "Missing azd output $name. Run azd provision first."
    }
}

$localSettingsPath = Join-Path $PSScriptRoot '../../local.settings.json'
if ((Test-Path -LiteralPath $localSettingsPath) -and -not $ForceLocalSettings) {
    Write-Host 'Existing local.settings.json preserved. Use -ForceLocalSettings to regenerate it.'
}
else {
    $localSettings = @{
        IsEncrypted = $false
        Values = @{
            AzureWebJobsStorage = 'UseDevelopmentStorage=true'
            FUNCTIONS_WORKER_RUNTIME = 'dotnet-isolated'
            ConnectorNamespace__pollingEndpoint = $outputs.connectorPollingEndpoint
            OnUpdatedFileTriggerConfigName = $outputs.onUpdatedFileTriggerConfigName
        }
    }
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
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the Azure Blob connection status.' }
    return $status
}

if ((Get-ConnectionStatus) -eq 'Connected') {
    Write-Host 'Azure Blob connection is already authorized.'
    return
}

Write-Host 'Authorize Azure Blob with the developer account granted access to the monitored storage account.'
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
    if ($LASTEXITCODE -eq 0 -and $consentLink -and $consentLink -ne 'null') { break }
    $consentLink = $null
    if ($attempt -lt 5) { Start-Sleep -Seconds 5 }
}

if (-not $consentLink -or $consentLink -eq 'null') {
    throw 'Could not obtain an Azure Blob consent link.'
}

Write-Host "Consent URL: $consentLink"
try {
    Start-Process $consentLink | Out-Null
} catch {
    Write-Warning "Could not open the browser: $_. Open the consent URL manually."
}

$deadline = (Get-Date).AddMinutes(5)
do {
    Start-Sleep -Seconds 3
    if ((Get-ConnectionStatus) -eq 'Connected') {
        Write-Host 'Azure Blob connection authorized. The Poll trigger configuration is provisioned.'
        return
    }
} while ((Get-Date) -lt $deadline)

throw 'Timed out waiting for the Azure Blob connection to become Connected.'
