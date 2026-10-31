# Post-deployment configuration for the azureblobApp.
#
# The Azure Blob connection uses Entra ID (OAuth) authentication.
# This script authorizes the connection via interactive consent,
# then creates the trigger config pointing to the function's
# connector webhook URL.

Write-Host "Post-deployment configuration..." -ForegroundColor Yellow

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

$localSettingsPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../local.settings.json'))
if (Test-Path -LiteralPath $localSettingsPath) {
    $item = Get-Item -LiteralPath $localSettingsPath -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        (-not $IsWindows -and [string]$item.UnixMode -notlike '-*')) {
        throw 'local.settings.json must be a regular file.'
    }
    Write-Host 'Existing local.settings.json preserved.'
}
else {
    $settingsTemp = Join-Path (Split-Path $localSettingsPath) ".local-settings-$([Guid]::NewGuid().ToString('N'))"
    try {
        $settings = @{
            IsEncrypted = $false
            Values = @{
                AzureWebJobsStorage = 'UseDevelopmentStorage=true'
                FUNCTIONS_WORKER_RUNTIME = 'dotnet-isolated'
            }
        } | ConvertTo-Json -Depth 3
        if ($IsWindows) {
            $security = [Security.AccessControl.FileSecurity]::new()
            $security.SetAccessRuleProtection($true, $false)
            $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.WindowsIdentity]::GetCurrent().User,
                [Security.AccessControl.FileSystemRights]::FullControl,
                [Security.AccessControl.AccessControlType]::Allow))
            $stream = [IO.FileSystemAclExtensions]::Create(
                [IO.FileInfo]::new($settingsTemp), [IO.FileMode]::CreateNew,
                [Security.AccessControl.FileSystemRights]::Write,
                [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $security)
        }
        else {
            $options = [IO.FileStreamOptions]::new()
            $options.Mode = [IO.FileMode]::CreateNew
            $options.Access = [IO.FileAccess]::Write
            $options.Share = [IO.FileShare]::None
            $options.UnixCreateMode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
            $stream = [IO.FileStream]::new($settingsTemp, $options)
        }
        try {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($settings)
            $stream.Write($bytes, 0, $bytes.Length)
        }
        finally {
            $stream.Dispose()
        }
        $validated = [IO.File]::ReadAllText($settingsTemp) | ConvertFrom-Json -ErrorAction Stop
        if ($validated.IsEncrypted -ne $false -or
            $validated.Values.AzureWebJobsStorage -ne 'UseDevelopmentStorage=true' -or
            $validated.Values.FUNCTIONS_WORKER_RUNTIME -ne 'dotnet-isolated') {
            throw 'Invalid generated local settings.'
        }
        [IO.File]::Move($settingsTemp, $localSettingsPath)
        Write-Host 'Created ignored local.settings.json using Azurite.'
    }
    catch {
        throw "Could not prepare local.settings.json: $_"
    }
    finally {
        if ([IO.File]::Exists($settingsTemp)) {
            Remove-Item -LiteralPath $settingsTemp -Force -ErrorAction Stop
        }
    }
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
$connectorExtensionKey = (az functionapp keys list -g $resourceGroupName -n $functionAppName --query "systemKeys.connector_extension" -o tsv)
if (-not $connectorExtensionKey) {
    Write-Host "ERROR: could not fetch connector_extension system key from $functionAppName." -ForegroundColor Red
    exit 1
}

$functionName  = 'OnUpdatedFile'
$operationName = 'OnUpdatedFiles_V2'
$triggerName   = "$connectorNamespaceConnectionName-$($functionName.ToLower())"
$callbackUrl   = "https://$functionAppHostname/runtime/webhooks/connector?functionName=$functionName"
$notifFile     = Join-Path $PSScriptRoot ".notification-details-$([System.Guid]::NewGuid().ToString('N')).json"
try {
    @{
        callbackUrl = $callbackUrl
        authentication = @{
            type = "QueryString"
            name = "code"
            value = $connectorExtensionKey
        }
    } | ConvertTo-Json -Depth 3 -Compress | Set-Content -Path $notifFile -NoNewline -ErrorAction Stop

    Write-Host "Creating trigger '$triggerName' for $functionName ($operationName)..." -ForegroundColor Yellow

    az connector-namespace trigger delete `
        -g $resourceGroupName --namespace $connectorNamespaceName `
        -n $triggerName --yes 2>$null | Out-Null

    az connector-namespace trigger create `
        -g $resourceGroupName --namespace $connectorNamespaceName `
        -n $triggerName `
        --connection-details "{connectionName:$connectorNamespaceConnectionName,connectorName:azureblob}" `
        --operation-name $operationName `
        --parameters "[{name:dataset,value:'$monitoredStorageAccountName'},{name:folderId,value:'$folderId'}]" `
        --notification-details "@$notifFile" `
        --description "When a blob is added or modified (properties only) (V2)" `
        --metadata "{destinationType:functionApp,functionAppName:$functionAppName,functionAppResourceGroup:$resourceGroupName,functionAppSubscriptionId:$subscriptionId,functionName:$functionName,recurrenceFrequency:Minute,recurrenceInterval:'5'}" `
        -o none

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to create trigger config for $functionName." -ForegroundColor Red
        exit 1
    }
}
finally {
    Remove-Item $notifFile -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Post-deployment configuration complete." -ForegroundColor Green
Write-Host "Upload blobs to the '$containerName' container in storage account '$monitoredStorageAccountName' to fire the trigger." -ForegroundColor Green
Write-Host "Tail logs: az functionapp log tail -g $resourceGroupName -n $functionAppName" -ForegroundColor Green
Write-Host ""
