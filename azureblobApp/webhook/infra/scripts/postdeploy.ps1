#requires -Version 7.3
# Post-deployment configuration for the azureblobApp.
#
# The Azure Blob connection uses Entra ID (OAuth) authentication.
# This script authorizes the connection via interactive consent,
# then configures the trigger pointing to the function's
# connector webhook URL.

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

# --- Authorize the Azure Blob connection (OAuth consent) --------------------
Write-Host ""
Write-Host "Authorizing Azure Blob Storage connection..." -ForegroundColor Yellow

$currentStatus = az connector-namespace connection show `
    -g $resourceGroupName --namespace $connectorNamespaceName `
    -n $connectorNamespaceConnectionName `
    --query "properties.overallStatus" -o tsv 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Could not read the Azure Blob connection status.' }

if ($currentStatus -and $currentStatus.ToLower() -eq 'connected') {
    Write-Host "   already Connected; skipping consent flow" -ForegroundColor Green
} else {
    $consentParameters = "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]"
    $link = $null

    for ($i = 0; $i -lt 5; $i++) {
        $link = az connector-namespace connection list-consent-links `
            -g $resourceGroupName --namespace $connectorNamespaceName `
            --connection-name $connectorNamespaceConnectionName `
            --parameters $consentParameters `
            --query "value[0].link" -o tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $link -or $link -eq 'null') {
            $link = az connector-namespace connection list-consent-links `
                -g $resourceGroupName --namespace $connectorNamespaceName `
                --connection-name $connectorNamespaceConnectionName `
                --parameters $consentParameters `
                --query "link" -o tsv 2>$null
        }
        if ($LASTEXITCODE -eq 0 -and $link -and $link -ne 'null') { break }
        $link = $null

        if ($i -lt 4) {
            Write-Host "   list-consent-links attempt $($i + 1) failed; retrying in 5s..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }

    if (-not $link) {
        Write-Host "ERROR: could not obtain consent link after retries." -ForegroundColor Red
        exit 1
    }

    Write-Host "   opening browser for OAuth consent..." -ForegroundColor Cyan
    Write-Host "   (if no tab opens, paste this URL manually: $link)" -ForegroundColor Cyan
    try { Start-Process $link | Out-Null } catch { Write-Warning "Could not open the browser: $_. Open the printed consent URL manually." }

    $deadline = (Get-Date).AddMinutes(5)
    $authorized = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $status = az connector-namespace connection show `
            -g $resourceGroupName --namespace $connectorNamespaceName `
            -n $connectorNamespaceConnectionName `
            --query "properties.overallStatus" -o tsv 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Could not read the Azure Blob connection status.' }
        Write-Host "   status: $status"
        if ($status -and $status.ToLower() -eq 'connected') {
            $authorized = $true
            break
        }
    }

    if (-not $authorized) {
        Write-Host "ERROR: Connection did not reach 'Connected' status within 5 minutes." -ForegroundColor Red
        exit 1
    }
    Write-Host "   Connection authenticated" -ForegroundColor Green
}

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
