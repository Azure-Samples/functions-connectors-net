Write-Host "Post-deployment configuration..." -ForegroundColor Yellow

# Outputs from azd
$outputs = azd env get-values --output json | ConvertFrom-Json

$subscriptionId = (az account show --query id -o tsv)
$resourceGroupName = $outputs.resourceGroupName
$connectorNamespaceName = $outputs.connectorNamespaceName
$connectorNamespaceConnectionName = $outputs.connectorNamespaceConnectionName
$functionAppName = $outputs.functionAppName

# --- Required Teams identifiers ---
# Teams triggers are scoped to a specific team (and channel for message triggers).
# Read from azd env vars or prompt the user via Microsoft Graph.
$teamsGroupId   = $outputs.TEAMS_GROUP_ID
$teamsChannelId = $outputs.TEAMS_CHANNEL_ID

function Select-FromList {
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [object[]] $Items,
        [Parameter(Mandatory)] [string] $LabelProperty
    )
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $Items[$i].$LabelProperty)
    }
    while ($true) {
        $answer = Read-Host "Enter number (1-$($Items.Count))"
        if ($null -eq $answer) {
            throw "No input available. Set TEAMS_GROUP_ID / TEAMS_CHANNEL_ID via 'azd env set'."
        }
        $num = 0
        if ([int]::TryParse($answer, [ref]$num) -and $num -ge 1 -and $num -le $Items.Count) {
            return $Items[$num - 1]
        }
        Write-Host "Invalid selection." -ForegroundColor Yellow
    }
}

function Invoke-Graph {
    param([Parameter(Mandatory)][string] $Url)
    $raw = az rest --method get --url $Url --resource https://graph.microsoft.com 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    return ($raw | ConvertFrom-Json)
}

if (-not $teamsGroupId -or -not $teamsChannelId) {
    Write-Host ""
    Write-Host "TEAMS_GROUP_ID / TEAMS_CHANNEL_ID not set. Fetching your Teams from Microsoft Graph..." -ForegroundColor Yellow

    $teamsResponse = Invoke-Graph -Url 'https://graph.microsoft.com/v1.0/me/joinedTeams?$select=id,displayName'
    if (-not $teamsResponse -or -not $teamsResponse.value -or $teamsResponse.value.Count -eq 0) {
        Write-Host "ERROR: Could not list your joined teams via Microsoft Graph." -ForegroundColor Red
        Write-Host "       Set the values manually:" -ForegroundColor Red
        Write-Host "         azd env set TEAMS_GROUP_ID   <team / M365 group object id>" -ForegroundColor Red
        Write-Host "         azd env set TEAMS_CHANNEL_ID <channel id>" -ForegroundColor Red
        exit 1
    }

    if (-not $teamsGroupId) {
        $team = Select-FromList -Title 'Select a team:' -Items $teamsResponse.value -LabelProperty 'displayName'
        $teamsGroupId = $team.id
        azd env set TEAMS_GROUP_ID $teamsGroupId | Out-Null
        Write-Host "Saved TEAMS_GROUP_ID=$teamsGroupId" -ForegroundColor Green
    }

    if (-not $teamsChannelId) {
        $channelsResponse = Invoke-Graph -Url "https://graph.microsoft.com/v1.0/teams/$teamsGroupId/channels?`$select=id,displayName"
        if (-not $channelsResponse -or -not $channelsResponse.value -or $channelsResponse.value.Count -eq 0) {
            Write-Host "ERROR: Could not list channels for team $teamsGroupId." -ForegroundColor Red
            exit 1
        }
        $channel = Select-FromList -Title 'Select a channel:' -Items $channelsResponse.value -LabelProperty 'displayName'
        $teamsChannelId = $channel.id
        azd env set TEAMS_CHANNEL_ID $teamsChannelId | Out-Null
        Write-Host "Saved TEAMS_CHANNEL_ID=$teamsChannelId" -ForegroundColor Green
    }
}

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
                connectorName = "teams"
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

# --- Create trigger configs for all 4 functions ---
Write-Host "Creating Connector Namespace trigger configs..." -ForegroundColor Yellow

New-TriggerConfig `
    -FunctionName "OnNewChannelMessage" `
    -OperationName "OnNewChannelMessage" `
    -Description "When a new channel message is added" `
    -Parameters @(
        @{ name = "groupId"; value = $teamsGroupId }
        @{ name = "channelId"; value = $teamsChannelId }
    )

New-TriggerConfig `
    -FunctionName "OnNewChannelMessageMentioningMe" `
    -OperationName "OnNewChannelMessageMentioningMe" `
    -Description "When I am mentioned in a channel message" `
    -Parameters @(
        @{ name = "groupId"; value = $teamsGroupId }
        @{ name = "channelId"; value = $teamsChannelId }
    )

New-TriggerConfig `
    -FunctionName "OnGroupMembershipAdd" `
    -OperationName "OnGroupMembershipAdd" `
    -Description "When a new team member is added" `
    -Parameters @(
        @{ name = "groupId"; value = $teamsGroupId }
    )

New-TriggerConfig `
    -FunctionName "OnGroupMembershipRemoval" `
    -OperationName "OnGroupMembershipRemoval" `
    -Description "When a team member is removed" `
    -Parameters @(
        @{ name = "groupId"; value = $teamsGroupId }
    )

Write-Host "All trigger configs created." -ForegroundColor Green

# --- Authorize the teams connection via Azure CLI ---
Write-Host ""
Write-Host "Authorizing teams connection..." -ForegroundColor Yellow

$ext = az extension show --name connector-namespace 2>$null
if (-not $ext) {
  Write-Host "Installing 'connector-namespace' Azure CLI extension..." -ForegroundColor Cyan
  az extension add `
    --source https://github.com/anthonychu/azure-cli-extensions/releases/download/connector-namespace-0.1.0/connector_namespace-0.1.0-py2.py3-none-any.whl `
    --yes
}

Write-Host "-> A browser tab will open. Sign in with the Teams account you want to monitor." -ForegroundColor Cyan
az connector-namespace connection authorize `
  --resource-group $resourceGroupName `
  --namespace-name $connectorNamespaceName `
  --name $connectorNamespaceConnectionName

Write-Host ""
Write-Host "Done. All 4 Teams triggers are configured." -ForegroundColor Green
Write-Host "Tail logs: az functionapp log tail -g $resourceGroupName -n $functionAppName" -ForegroundColor Green
Write-Host ""
