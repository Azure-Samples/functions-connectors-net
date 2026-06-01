Write-Host "Post-deployment configuration..." -ForegroundColor Yellow

# Outputs from azd
$outputs = azd env get-values --output json | ConvertFrom-Json

$subscriptionId = (az account show --query id -o tsv)
$resourceGroupName = $outputs.resourceGroupName
$connectorNamespaceName = $outputs.connectorNamespaceName
$connectorNamespaceConnectionName = $outputs.connectorNamespaceConnectionName
$functionAppName = $outputs.functionAppName
$office365FunctionName = $outputs.office365FunctionName
$entraAppClientId = $outputs.entraAppClientId
$triggerIdentityResourceId = $outputs.triggerIdentityResourceId

# --- Create Connector Namespace trigger config ---
Write-Host "Creating Connector Namespace trigger config..." -ForegroundColor Yellow

$triggerName = "$connectorNamespaceConnectionName-trigger"

# Anonymous webhook auth on /runtime/webhooks/connector is opted into via
# extensions.connector.system.webhookAuthorizationLevel = "Anonymous" in
# host.json. That drops the `code=` requirement, leaving built-in
# authentication (validating the trigger UAMI's AAD token) as the single
# enforcement point.
$callbackUrl = "https://$functionAppName.azurewebsites.net/runtime/webhooks/connector?functionName=$office365FunctionName"

$apiUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/connectorGateways/$connectorNamespaceName/triggerconfigs/${triggerName}?api-version=2026-05-01-preview"

$body = @{
  properties = @{
    description = "Office 365 Outlook trigger config (secured with MI + built-in authentication)"
    connectionDetails = @{
      connectorName = "office365"
      connectionName = $connectorNamespaceConnectionName
    }
    operationName = "OnNewEmailV3"
    parameters = @(
      @{ name = "folderPath"; value = "Inbox" }
      @{ name = "importance"; value = "High" }
    )
    notificationDetails = @{
      callbackUrl = $callbackUrl
      httpMethod = "Post"
      authentication = @{
        type = "ManagedServiceIdentity"
        audience = $entraAppClientId
        identity = $triggerIdentityResourceId
      }
    }
  }
} | ConvertTo-Json -Depth 10 -Compress

Write-Host "  API URL: $apiUrl" -ForegroundColor Cyan
Write-Host "  Callback URL: $callbackUrl" -ForegroundColor Cyan
Write-Host "  Token audience: $entraAppClientId" -ForegroundColor Cyan

$bodyJson = $body
$tmpFile = [System.IO.Path]::GetTempFileName()
$bodyJson | Out-File -FilePath $tmpFile -Encoding utf8

az rest --method PUT --url $apiUrl --body "@$tmpFile" --headers "Content-Type=application/json" | Out-Null

Remove-Item $tmpFile

Write-Host "Connector Namespace trigger config created." -ForegroundColor Green

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
Write-Host "Done. New emails in the connected Inbox will fire the OnNewEmail function." -ForegroundColor Green
Write-Host "Tail logs: az functionapp log tail -g $resourceGroupName -n $functionAppName" -ForegroundColor Green
Write-Host ""
