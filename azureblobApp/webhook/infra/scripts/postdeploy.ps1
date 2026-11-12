#requires -Version 7.3
# Post-deployment configuration for the azureblobApp.
#
# The Azure Blob connection uses the namespace's managed identity.
# This script waits for connection readiness, then configures the webhook trigger.

Write-Host "Post-deployment configuration..." -ForegroundColor Yellow
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-settings.ps1')

# --- Pre-flight: verify the connector-namespace CLI extension is installed ----
if (-not (az extension show --name connector-namespace --query name -o tsv 2>$null)) {
    Write-Host "ERROR: The 'connector-namespace' Azure CLI extension is required." -ForegroundColor Red
    Write-Host "Install: irm https://aka.ms/connector-namespace-cli-install-ps | iex" -ForegroundColor Red
    exit 1
}

# --- Read azd outputs --------------------------------------------------------
$raw = azd env get-values --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected azd environment.' }
$outputs = ($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop

foreach ($name in @(
    'resourceGroupName', 'connectorNamespaceName', 'connectorNamespaceConnectionName',
    'functionAppName', 'functionAppDefaultHostname', 'monitoredStorageAccountName',
    'AZURE_SUBSCRIPTION_ID')) {
    if ([string]::IsNullOrWhiteSpace([string]$outputs.$name)) {
        throw "Missing azd output $name. Run azd provision first."
    }
}

$resourceGroupName        = $outputs.resourceGroupName
$connectorNamespaceName   = $outputs.connectorNamespaceName
$connectorNamespaceConnectionName = $outputs.connectorNamespaceConnectionName
$functionAppName          = $outputs.functionAppName
$functionAppHostname      = $outputs.functionAppDefaultHostname
$subscriptionId           = $outputs.AZURE_SUBSCRIPTION_ID
$monitoredStorageAccountName = $outputs.monitoredStorageAccountName

Write-LocalSettings @{
    AzureWebJobsStorage = 'UseDevelopmentStorage=true'
    FUNCTIONS_WORKER_RUNTIME = 'dotnet-isolated'
}

$functionName = 'OnUpdatedFile'
$operationName = 'OnUpdatedFiles_V2'
$triggerName = "$connectorNamespaceConnectionName-$($functionName.ToLowerInvariant())"
$raw = az connector-namespace trigger list -g $resourceGroupName --namespace $connectorNamespaceName --query '[].name' -o json 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Could not list existing Azure Blob trigger configurations.' }
try { $existing = ConvertFrom-Json -InputObject ($raw -join "`n") -NoEnumerate -ErrorAction Stop }
catch { throw 'Invalid Azure Blob trigger configuration list.' }
if ($existing -isnot [array] -or @($existing | Where-Object { $_ -isnot [string] }).Count) {
    throw 'Invalid Azure Blob trigger configuration list.'
}
$verb = 'create'
if ($triggerName -in $existing) {
    $verb = 'update'
}

# --- Wait for the managed-identity connection -------------------------------
Write-Host ""
Write-Host "Checking Azure Blob managed-identity connection readiness (no user consent required)..." -ForegroundColor Yellow

$connectionUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/connectorGateways/$connectorNamespaceName/connections/$($connectorNamespaceConnectionName)?api-version=2026-05-01-preview"
$authSet = az rest --method get --url $connectionUrl --query 'properties.parameterValueSet.name' -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Could not read the Azure Blob connection authentication type.' }
if ($authSet -ne 'managedIdentityAuth') {
    throw 'Azure Blob connection is not configured for managedIdentityAuth. Reprovision to create the MI-specific connection; an existing OAuth connection cannot be validated as managed identity.'
}

$deadline = (Get-Date).AddMinutes(5)
$connected = $false
do {
    $status = az connector-namespace connection show `
        -g $resourceGroupName --namespace $connectorNamespaceName `
        -n $connectorNamespaceConnectionName `
        --query "properties.overallStatus" -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the Azure Blob connection status.' }
    if ($status -in @('Ready', 'Connected')) {
        $connected = $true
        break
    }
    Start-Sleep -Seconds 5
} while ((Get-Date) -lt $deadline)

if (-not $connected) {
    throw 'Timed out waiting for the Azure Blob managed-identity connection to become Ready or Connected. Verify the namespace connection access policy and namespace Storage Blob Data Reader access on the monitored storage account. Allow RBAC propagation, then rerun the hook.'
}
Write-Host "   Managed-identity connection is $status" -ForegroundColor Green

# --- Container path for the trigger ----------------------------------------
$containerName  = $outputs.monitoredContainerName
if (-not $containerName) { $containerName = 'connector-input' }
$urlEncodedPath = "%2f$containerName"
$folderIdBytes  = [System.Text.Encoding]::UTF8.GetBytes($urlEncodedPath)
$folderId       = [Convert]::ToBase64String($folderIdBytes)

Write-Host "Container '$containerName' -> folderId '$folderId'" -ForegroundColor DarkGray

# --- Create Connector Namespace trigger config -------------------------------
Write-Host ""
Write-Host "Fetching connector extension key for $functionAppName..." -ForegroundColor Cyan
$connectorExtensionKey = (az functionapp keys list -g $resourceGroupName -n $functionAppName --query "systemKeys.connector_extension" -o tsv 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($connectorExtensionKey) -or $connectorExtensionKey -eq 'null') {
    Write-Host "ERROR: could not fetch connector_extension system key from $functionAppName." -ForegroundColor Red
    exit 1
}

$callbackUrl   = "https://$functionAppHostname/runtime/webhooks/connector?functionName=$functionName"
$notifFile     = Join-Path $PSScriptRoot ".notification-details-$([System.Guid]::NewGuid().ToString('N')).json"
$notifOwned = $false
$failure = $null
try {
    $stream = New-PrivateStagingStream $notifFile
    $notifOwned = $true
    $streamFailure = $null
    try {
        $json = @{
            callbackUrl = $callbackUrl
            authentication = @{
                type = "QueryString"
                name = "code"
                value = $connectorExtensionKey
            }
        } | ConvertTo-Json -Depth 3 -Compress
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } catch { $streamFailure = $_; throw }
    finally {
        try { $stream.Dispose() }
        catch {
            if ($null -eq $streamFailure) { throw 'Could not close owned callback staging stream.' }
            Write-Warning 'Could not close owned staging stream; original failure preserved.'
        }
    }

    Write-Host "Configuring trigger '$triggerName' for $functionName ($operationName)..." -ForegroundColor Yellow

    az connector-namespace trigger $verb `
        -g $resourceGroupName --namespace $connectorNamespaceName `
        -n $triggerName `
        --connection-details "{connectionName:$connectorNamespaceConnectionName,connectorName:azureblob}" `
        --operation-name $operationName `
        --parameters "[{name:dataset,value:'$monitoredStorageAccountName'},{name:folderId,value:'$folderId'}]" `
        --notification-details "@$notifFile" `
        --state Enabled `
        --description "When a blob is added or modified (properties only) (V2)" `
        --metadata "{destinationType:functionApp,functionAppName:$functionAppName,functionAppResourceGroup:$resourceGroupName,functionAppSubscriptionId:$subscriptionId,functionName:$functionName,recurrenceFrequency:Minute,recurrenceInterval:'5'}" `
        -o none 2>$null

    if ($LASTEXITCODE -ne 0) {
        throw "Could not configure Azure Blob trigger $triggerName."
    }
} catch {
    $failure = $_
    throw
}
finally {
    try { if ($notifOwned) { Remove-OwnedStagingFile $notifFile } }
    catch {
        if ($null -eq $failure) { throw 'Could not clean owned callback staging file.' }
        Write-Warning 'Could not clean owned callback staging file; original failure preserved.'
    }
}

Write-Host ""
Write-Host "Post-deployment configuration complete." -ForegroundColor Green
Write-Host "Upload blobs to the '$containerName' container in storage account '$monitoredStorageAccountName' to fire the trigger." -ForegroundColor Green
Write-Host "Tail logs: az functionapp log tail -g $resourceGroupName -n $functionAppName" -ForegroundColor Green
Write-Host ""
