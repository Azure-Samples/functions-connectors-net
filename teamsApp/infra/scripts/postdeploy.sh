#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}Post-deployment configuration...${NC}"

outputs=$(azd env get-values --output json)

if ! command -v jq &> /dev/null; then
  echo -e "${RED}Error: jq is required for this script. Please install jq.${NC}"
  exit 1
fi

subscriptionId=$(echo "$outputs" | jq -r '.AZURE_SUBSCRIPTION_ID')
resourceGroupName=$(echo "$outputs" | jq -r '.resourceGroupName')
connectorNamespaceName=$(echo "$outputs" | jq -r '.connectorNamespaceName')
connectorNamespaceConnectionName=$(echo "$outputs" | jq -r '.connectorNamespaceConnectionName')
functionAppName=$(echo "$outputs" | jq -r '.functionAppName')

# --- Required Teams identifiers ---
teamsGroupId=$(echo "$outputs" | jq -r '.TEAMS_GROUP_ID // empty')
teamsChannelId=$(echo "$outputs" | jq -r '.TEAMS_CHANNEL_ID // empty')

invoke_graph() {
  az rest --method get --url "$1" --resource https://graph.microsoft.com 2>/dev/null
}

select_from_list() {
  local title="$1"
  local json_array="$2"
  local label_prop="$3"

  echo -e "\n${CYAN}${title}${NC}"
  local count
  count=$(echo "$json_array" | jq 'length')
  for ((i=0; i<count; i++)); do
    local label
    label=$(echo "$json_array" | jq -r ".[$i].$label_prop")
    echo "  [$((i+1))] $label"
  done
  while true; do
    read -rp "Enter number (1-$count): " num
    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "$count" ]; then
      echo "$json_array" | jq -r ".[$((num-1))]"
      return
    fi
    echo -e "${YELLOW}Invalid selection.${NC}"
  done
}

if [ -z "$teamsGroupId" ] || [ -z "$teamsChannelId" ]; then
  echo -e "\n${YELLOW}TEAMS_GROUP_ID / TEAMS_CHANNEL_ID not set. Fetching your Teams from Microsoft Graph...${NC}"

  teamsJson=$(invoke_graph 'https://graph.microsoft.com/v1.0/me/joinedTeams?$select=id,displayName')
  teamsArray=$(echo "$teamsJson" | jq '.value')
  teamsCount=$(echo "$teamsArray" | jq 'length')

  if [ -z "$teamsArray" ] || [ "$teamsCount" -eq 0 ]; then
    echo -e "${RED}ERROR: Could not list your joined teams via Microsoft Graph.${NC}"
    echo -e "${RED}       Set the values manually:${NC}"
    echo -e "${RED}         azd env set TEAMS_GROUP_ID   <team / M365 group object id>${NC}"
    echo -e "${RED}         azd env set TEAMS_CHANNEL_ID <channel id>${NC}"
    exit 1
  fi

  if [ -z "$teamsGroupId" ]; then
    selected=$(select_from_list "Select a team:" "$teamsArray" "displayName")
    teamsGroupId=$(echo "$selected" | jq -r '.id')
    azd env set TEAMS_GROUP_ID "$teamsGroupId" >/dev/null
    echo -e "${GREEN}Saved TEAMS_GROUP_ID=$teamsGroupId${NC}"
  fi

  if [ -z "$teamsChannelId" ]; then
    channelsJson=$(invoke_graph "https://graph.microsoft.com/v1.0/teams/$teamsGroupId/channels?\$select=id,displayName")
    channelsArray=$(echo "$channelsJson" | jq '.value')
    channelsCount=$(echo "$channelsArray" | jq 'length')
    if [ -z "$channelsArray" ] || [ "$channelsCount" -eq 0 ]; then
      echo -e "${RED}ERROR: Could not list channels for team $teamsGroupId.${NC}"
      exit 1
    fi
    selected=$(select_from_list "Select a channel:" "$channelsArray" "displayName")
    teamsChannelId=$(echo "$selected" | jq -r '.id')
    azd env set TEAMS_CHANNEL_ID "$teamsChannelId" >/dev/null
    echo -e "${GREEN}Saved TEAMS_CHANNEL_ID=$teamsChannelId${NC}"
  fi
fi

# Fetch the connector extension system key
echo -e "${CYAN}Fetching connector extension key for ${functionAppName}...${NC}"
connectorExtensionKey=$(az functionapp keys list -g "${resourceGroupName}" -n "${functionAppName}" --query "systemKeys.connector_extension" -o tsv)

# --- Helper: create a trigger config on the Connector Namespace ---
create_trigger_config() {
  local functionName="$1"
  local operationName="$2"
  local description="$3"
  local parametersJson="$4"  # JSON array string

  local triggerName="${connectorNamespaceConnectionName}-$(echo "${functionName}" | tr '[:upper:]' '[:lower:]')"
  local callbackUrl="https://${functionAppName}.azurewebsites.net/runtime/webhooks/connector?functionName=${functionName}&code=${connectorExtensionKey}"
  local apiUrl="https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${resourceGroupName}/providers/Microsoft.Web/connectorGateways/${connectorNamespaceName}/triggerconfigs/${triggerName}?api-version=2026-05-01-preview"

  local body
  body=$(cat <<JSON
{
  "properties": {
    "description": "${description}",
    "connectionDetails": {
      "connectorName": "teams",
      "connectionName": "${connectorNamespaceConnectionName}"
    },
    "operationName": "${operationName}",
    "parameters": ${parametersJson},
    "notificationDetails": {
      "callbackUrl": "${callbackUrl}"
    }
  }
}
JSON
)

  echo -e "${CYAN}  Creating trigger: ${functionName} -> ${operationName}${NC}"
  az rest --method PUT --url "${apiUrl}" --body "${body}" > /dev/null
}

# --- Create trigger configs for all 4 functions ---
echo -e "${YELLOW}Creating Connector Namespace trigger configs...${NC}"

create_trigger_config "OnNewChannelMessage" "OnNewChannelMessage" \
  "When a new channel message is added" \
  "[{\"name\":\"groupId\",\"value\":\"${teamsGroupId}\"},{\"name\":\"channelId\",\"value\":\"${teamsChannelId}\"}]"

create_trigger_config "OnNewChannelMessageMentioningMe" "OnNewChannelMessageMentioningMe" \
  "When I am mentioned in a channel message" \
  "[{\"name\":\"groupId\",\"value\":\"${teamsGroupId}\"},{\"name\":\"channelId\",\"value\":\"${teamsChannelId}\"}]"

create_trigger_config "OnGroupMembershipAdd" "OnGroupMembershipAdd" \
  "When a new team member is added" \
  "[{\"name\":\"groupId\",\"value\":\"${teamsGroupId}\"}]"

create_trigger_config "OnGroupMembershipRemoval" "OnGroupMembershipRemoval" \
  "When a team member is removed" \
  "[{\"name\":\"groupId\",\"value\":\"${teamsGroupId}\"}]"

echo -e "${GREEN}✅ All trigger configs created.${NC}"

# --- Authorize the teams connection via Azure CLI ---
echo ""
echo -e "${YELLOW}Authorizing teams connection...${NC}"

if ! az extension show --name connector-namespace >/dev/null 2>&1; then
  echo -e "${CYAN}Installing 'connector-namespace' Azure CLI extension...${NC}"
  az extension add \
    --source https://github.com/anthonychu/azure-cli-extensions/releases/download/connector-namespace-0.1.0/connector_namespace-0.1.0-py2.py3-none-any.whl \
    --yes
fi

echo -e "${CYAN}-> A browser tab will open. Sign in with the Teams account you want to monitor.${NC}"
az connector-namespace connection authorize \
  --resource-group "${resourceGroupName}" \
  --namespace-name "${connectorNamespaceName}" \
  --name "${connectorNamespaceConnectionName}"

echo ""
echo -e "${GREEN}✅ Done. All 4 Teams triggers are configured.${NC}"
echo -e "${GREEN}   Tail logs:  az functionapp log tail -g ${resourceGroupName} -n ${functionAppName}${NC}"
echo ""
