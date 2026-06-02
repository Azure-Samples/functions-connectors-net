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
      "connectorName": "office365",
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

# --- Create trigger configs for all 5 functions ---
echo -e "${YELLOW}Creating Connector Namespace trigger configs...${NC}"

create_trigger_config "OnNewEmail" "OnNewEmailV3" \
  "When a new email arrives" \
  '[{"name":"folderPath","value":"Inbox"},{"name":"importance","value":"High"}]'

create_trigger_config "OnFlaggedEmail" "OnFlaggedEmailV4" \
  "When an email is flagged" \
  '[{"name":"folderPath","value":"Inbox"}]'

create_trigger_config "OnNewMentionMeEmail" "OnNewMentionMeEmailV3" \
  "When a new email mentioning me arrives" \
  '[{"name":"folderPath","value":"Inbox"}]'

create_trigger_config "OnNewCalendarEvent" "CalendarGetOnNewItemsV3" \
  "When a new calendar event is created" \
  '[{"name":"table","value":"Calendar"}]'

create_trigger_config "OnUpcomingEvent" "OnUpcomingEventsV3" \
  "When an upcoming event is starting soon" \
  '[{"name":"table","value":"Calendar"}]'

echo -e "${GREEN}✅ All trigger configs created.${NC}"

# --- Authorize the office365 connection via Azure CLI ---
echo ""
echo -e "${YELLOW}Authorizing office365 connection...${NC}"

if ! az extension show --name connector-namespace >/dev/null 2>&1; then
  echo -e "${CYAN}Installing 'connector-namespace' Azure CLI extension...${NC}"
  az extension add \
    --source https://github.com/anthonychu/azure-cli-extensions/releases/download/connector-namespace-0.1.0/connector_namespace-0.1.0-py2.py3-none-any.whl \
    --yes
fi

echo -e "${CYAN}-> A browser tab will open. Sign in with the mailbox account whose Inbox you want to monitor.${NC}"
az connector-namespace connection authorize \
  --resource-group "${resourceGroupName}" \
  --namespace-name "${connectorNamespaceName}" \
  --name "${connectorNamespaceConnectionName}"

echo ""
echo -e "${GREEN}✅ Done. All 5 Office 365 triggers are configured.${NC}"
echo -e "${GREEN}   Tail logs:  az functionapp log tail -g ${resourceGroupName} -n ${functionAppName}${NC}"
echo ""
