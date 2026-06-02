Write-Host "Post-deployment configuration..." -ForegroundColor Yellow

# Outputs from azd
$outputs = azd env get-values --output json | ConvertFrom-Json

$subscriptionId = (az account show --query id -o tsv)
$resourceGroupName = $outputs.resourceGroupName
$connectorNamespaceName = $outputs.connectorNamespaceName
$connectorNamespaceConnectionName = $outputs.connectorNamespaceConnectionName
$functionAppName = $outputs.functionAppName

# Fetch the connector extension system key
Write-Host "Fetching connector extension key for $functionAppName..." -ForegroundColor Cyan
$connectorExtensionKey = (az functionapp keys list -g $resourceGroupName -n $functionAppName --query "systemKeys.connector_extension" -o tsv)

# --- Helper: create a trigger config on the Connector Namespace ---
function New-TriggerConfig {
    param(
        [Parameter(Mandatory)] [string] $FunctionName,
        [Parameter(Mandatory)] [string] $OperationName,
        [Parameter(Mandatory)] [string] $Description,
        [object[]] $Parameters = @()
    )

    $triggerName = "$connectorNamespaceConnectionName-$($FunctionName.ToLower())"
    $callbackUrl = "https://$functionAppName.azurewebsites.net/runtime/webhooks/connector?functionName=$FunctionName&code=$connectorExtensionKey"
    $apiUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/connectorGateways/$connectorNamespaceName/triggerconfigs/${triggerName}?api-version=2026-05-01-preview"

    $body = @{
        properties = @{
            description = $Description
            connectionDetails = @{
                connectorName = "office365"
                connectionName = $connectorNamespaceConnectionName
            }
            operationName = $OperationName
            parameters = $Parameters
            notificationDetails = @{
                callbackUrl = $callbackUrl
            }
        }
    } | ConvertTo-Json -Depth 5

    Write-Host "  Creating trigger: $FunctionName -> $OperationName" -ForegroundColor Cyan

    $bodyFile = [System.IO.Path]::GetTempFileName()
    $body | Out-File -FilePath $bodyFile -Encoding utf8
    az rest --method PUT --url $apiUrl --body "@$bodyFile" --headers "Content-Type=application/json" | Out-Null
    Remove-Item $bodyFile -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Failed to create trigger config for $FunctionName." -ForegroundColor Red
        exit 1
    }
}

# --- Create trigger configs for all 5 functions ---
Write-Host "Creating Connector Namespace trigger configs..." -ForegroundColor Yellow

New-TriggerConfig `
    -FunctionName "OnNewEmail" `
    -OperationName "OnNewEmailV3" `
    -Description "When a new email arrives" `
    -Parameters @(
        @{ name = "folderPath"; value = "Inbox" }
        @{ name = "importance"; value = "High" }
    )

New-TriggerConfig `
    -FunctionName "OnFlaggedEmail" `
    -OperationName "OnFlaggedEmailV4" `
    -Description "When an email is flagged" `
    -Parameters @(
        @{ name = "folderPath"; value = "Inbox" }
    )

New-TriggerConfig `
    -FunctionName "OnNewMentionMeEmail" `
    -OperationName "OnNewMentionMeEmailV3" `
    -Description "When a new email mentioning me arrives" `
    -Parameters @(
        @{ name = "folderPath"; value = "Inbox" }
    )

New-TriggerConfig `
    -FunctionName "OnNewCalendarEvent" `
    -OperationName "CalendarGetOnNewItemsV3" `
    -Description "When a new calendar event is created" `
    -Parameters @(
        @{ name = "table"; value = "Calendar" }
    )

New-TriggerConfig `
    -FunctionName "OnUpcomingEvent" `
    -OperationName "OnUpcomingEventsV3" `
    -Description "When an upcoming event is starting soon" `
    -Parameters @(
        @{ name = "table"; value = "Calendar" }
    )

Write-Host "All trigger configs created." -ForegroundColor Green

# --- Authorize the office365 connection via Azure CLI ---
Write-Host ""
Write-Host "Authorizing office365 connection..." -ForegroundColor Yellow

$ext = az extension show --name connector-namespace 2>$null
if (-not $ext) {
  Write-Host "Installing 'connector-namespace' Azure CLI extension..." -ForegroundColor Cyan
  az extension add `
    --source https://github.com/anthonychu/azure-cli-extensions/releases/download/connector-namespace-0.1.0/connector_namespace-0.1.0-py2.py3-none-any.whl `
    --yes
}

Write-Host "-> A browser tab will open. Sign in with the mailbox account whose Inbox you want to monitor." -ForegroundColor Cyan
az connector-namespace connection authorize `
  --resource-group $resourceGroupName `
  --namespace-name $connectorNamespaceName `
  --name $connectorNamespaceConnectionName

Write-Host ""
Write-Host "Done. All 5 Office 365 triggers are configured." -ForegroundColor Green
Write-Host "Tail logs: az functionapp log tail -g $resourceGroupName -n $functionAppName" -ForegroundColor Green
Write-Host ""
