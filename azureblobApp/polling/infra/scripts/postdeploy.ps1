#requires -Version 7.3
param([switch] $ForceLocalSettings)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-settings.ps1')

if (-not (az extension show --name connector-namespace --query name -o tsv 2>$null)) {
    throw 'Install the connector-namespace Azure CLI extension before running this script.'
}

$raw = azd env get-values --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected azd environment.' }
$outputs = ($raw -join "`n") | ConvertFrom-Json

foreach ($name in @(
    'resourceGroupName', 'connectorNamespaceName', 'connectorNamespaceConnectionName',
    'connectorPollingEndpoint', 'onUpdatedFileTriggerConfigName', 'AZURE_SUBSCRIPTION_ID')) {
    if ([string]::IsNullOrWhiteSpace([string]$outputs.$name)) {
        throw "Missing azd output $name. Run azd provision first."
    }
}

Write-LocalSettings @{
    AzureWebJobsStorage = 'UseDevelopmentStorage=true'
    FUNCTIONS_WORKER_RUNTIME = 'dotnet-isolated'
    ConnectorNamespace__pollingEndpoint = $outputs.connectorPollingEndpoint
    OnUpdatedFileTriggerConfigName = $outputs.onUpdatedFileTriggerConfigName
} -ForceLocalSettings:$ForceLocalSettings

$connectionUrl = "https://management.azure.com/subscriptions/$($outputs.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($outputs.resourceGroupName)/providers/Microsoft.Web/connectorGateways/$($outputs.connectorNamespaceName)/connections/$($outputs.connectorNamespaceConnectionName)?api-version=2026-05-01-preview"
$authSet = az rest --method get --url $connectionUrl --query 'properties.parameterValueSet.name' -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Could not read the Azure Blob connection authentication type.' }
if ($authSet -ne 'managedIdentityAuth') {
    throw 'Azure Blob connection is not configured for managedIdentityAuth. Reprovision to create the MI-specific connection; an existing OAuth connection cannot be validated as managed identity.'
}

function Get-ConnectionStatus {
    $status = az connector-namespace connection show `
        -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName `
        -n $outputs.connectorNamespaceConnectionName `
        --query 'properties.overallStatus' -o tsv
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the Azure Blob connection status.' }
    return $status
}

Write-Host 'Checking Azure Blob managed-identity connection readiness (no user consent required).'
$deadline = (Get-Date).AddMinutes(5)
do {
    $status = Get-ConnectionStatus
    if ($status -in @('Ready', 'Connected')) {
        Write-Host "Azure Blob managed-identity connection is $status. The Poll trigger configuration is provisioned."
        return
    }
    Start-Sleep -Seconds 5
} while ((Get-Date) -lt $deadline)

throw 'Timed out waiting for the Azure Blob managed-identity connection to become Ready or Connected. Verify the namespace connection access policy and namespace Storage Blob Data Reader access on the monitored storage account. Allow RBAC propagation, then rerun the hook.'
