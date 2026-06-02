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
office365FunctionName=$(echo "$outputs" | jq -r '.office365FunctionName')
entraAppClientId=$(echo "$outputs" | jq -r '.entraAppClientId')
triggerIdentityResourceId=$(echo "$outputs" | jq -r '.triggerIdentityResourceId')

# --- Create Connector Namespace trigger config ---
echo -e "${YELLOW}Creating Connector Namespace trigger config...${NC}"

triggerName="${connectorNamespaceConnectionName}-trigger"

# Anonymous webhook auth on /runtime/webhooks/connector is opted into via
# `extensions.connector.system.webhookAuthorizationLevel = "Anonymous"` in
# host.json. That drops the `code=` requirement, leaving built-in
# authentication (validating the trigger UAMI's AAD token) as the single
# enforcement point.
callbackUrl="https://${functionAppName}.azurewebsites.net/runtime/webhooks/connector?functionName=${office365FunctionName}"

apiUrl="https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${resourceGroupName}/providers/Microsoft.Web/connectorGateways/${connectorNamespaceName}/triggerconfigs/${triggerName}?api-version=2026-05-01-preview"

# notificationDetails.authentication tells the connector to attach an Entra ID
# token (minted from the user-assigned MI referenced by `identity`) when calling
# the callbackUrl. The token's audience must match an allowedAudience configured
# on the function app's EasyAuth -- we use the Entra app's clientId.
body=$(cat <<JSON
{
  "properties": {
    "description": "Office 365 Outlook trigger config (secured with MI + built-in authentication)",
    "connectionDetails": {
      "connectorName": "office365",
      "connectionName": "${connectorNamespaceConnectionName}"
    },
    "operationName": "OnNewEmailV3",
    "parameters": [
      {
        "name": "folderPath",
        "value": "Inbox"
      },
      {
        "name": "importance",
        "value": "High"
      }
    ],
    "notificationDetails": {
      "callbackUrl": "${callbackUrl}",
      "httpMethod": "Post",
      "authentication": {
        "type": "ManagedServiceIdentity",
        "audience": "${entraAppClientId}",
        "identity": "${triggerIdentityResourceId}"
      }
    }
  }
}
JSON
)

echo -e "${CYAN}  API URL: ${apiUrl}${NC}"
echo -e "${CYAN}  Callback URL: ${callbackUrl}${NC}"
echo -e "${CYAN}  Token audience: ${entraAppClientId}${NC}"

az rest --method PUT --url "${apiUrl}" --body "${body}"

echo -e "${GREEN}✅ Connector Namespace trigger config created.${NC}"

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
echo -e "${GREEN}✅ Done. New emails in the connected Inbox will fire the OnNewEmail function.${NC}"
echo -e "${GREEN}   Tail logs:  az functionapp log tail -g ${resourceGroupName} -n ${functionAppName}${NC}"
echo ""
