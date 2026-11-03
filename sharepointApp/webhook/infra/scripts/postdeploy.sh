#!/bin/bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/local-settings.sh"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}Post-deployment configuration...${NC}"

if ! command -v jq &> /dev/null; then
  echo -e "${RED}Error: jq is required for this script. Please install jq.${NC}"
  exit 1
fi

if ! az extension show --name connector-namespace --query name -o tsv 2>/dev/null; then
  echo -e "${RED}ERROR: The 'connector-namespace' Azure CLI extension is required.${NC}"
  echo -e "${RED}Install: curl -fsSL https://aka.ms/connector-namespace-cli-install | sh${NC}"
  exit 1
fi

outputs=$(azd env get-values --output json)

for name in resourceGroupName connectorNamespaceName connectorNamespaceConnectionName \
  functionAppName functionAppDefaultHostname AZURE_SUBSCRIPTION_ID sharepointSiteUrl sharepointLibraryName; do
  if ! echo "$outputs" | connector_jq -e --arg name "$name" \
    '.[$name] | if type == "string" then test("\\S") and . != "null" else false end' >/dev/null; then
    echo "ERROR: Missing or invalid azd output ${name}. Run azd provision first." >&2
    exit 1
  fi
done

resourceGroupName=$(echo "$outputs" | connector_jq -r '.resourceGroupName')
connectorNamespaceName=$(echo "$outputs" | connector_jq -r '.connectorNamespaceName')
connectorNamespaceConnectionName=$(echo "$outputs" | connector_jq -r '.connectorNamespaceConnectionName')
functionAppName=$(echo "$outputs" | connector_jq -r '.functionAppName')
functionAppDefaultHostname=$(echo "$outputs" | connector_jq -r '.functionAppDefaultHostname')
subscriptionId=$(echo "$outputs" | connector_jq -r '.AZURE_SUBSCRIPTION_ID')
sharepointSiteUrl=$(echo "$outputs" | connector_jq -r '.sharepointSiteUrl')
sharepointLibraryName=$(echo "$outputs" | connector_jq -r '.sharepointLibraryName')
triggerDefinitions=$(echo "$outputs" | connector_jq -ce '.triggerDefinitions | if type == "string" then fromjson else . end | select(type == "array" and length == 10)')
existingNames=$(az connector-namespace trigger list -g "${resourceGroupName}" --namespace "${connectorNamespaceName}" --query '[].name' -o json)

echo -e "${CYAN}Fetching connector extension key for ${functionAppName}...${NC}"
connectorExtensionKey=$(az functionapp keys list -g "${resourceGroupName}" -n "${functionAppName}" --query "systemKeys.connector_extension" -o tsv)
connectorExtensionKey="${connectorExtensionKey%$'\r'}"
if [[ -z "${connectorExtensionKey}" ]]; then
  echo -e "${RED}ERROR: could not fetch connector_extension system key from ${functionAppName}.${NC}"
  exit 1
fi

echo -e "${YELLOW}Creating Connector Namespace trigger configs...${NC}"
echo -e "${CYAN}  SharePoint site: ${sharepointSiteUrl}${NC}"
echo -e "${CYAN}  Library: ${sharepointLibraryName}${NC}"

temp_dir=''
cleanup_callback() {
  result=$?
  trap - EXIT
  if [[ -n "$temp_dir" ]]; then
    cleanup_failed=false
    rm -f -- "$temp_dir/notification.json" || cleanup_failed=true
    rm -f -- "$temp_dir/parameters.json" || cleanup_failed=true
    rmdir -- "$temp_dir" || cleanup_failed=true
    if [[ "$cleanup_failed" == true ]]; then
      echo 'Could not clean owned callback staging files.' >&2
      [[ "$result" -ne 0 ]] || result=1
    fi
  fi
  exit "$result"
}
trap cleanup_callback EXIT
candidate_dir=$(mktemp -d "${TMPDIR:-/tmp}/sharepoint-callback.XXXXXXXX") ||
  { echo 'Could not create callback staging directory.' >&2; exit 1; }
temp_dir="$candidate_dir"
while IFS= read -r triggerSpec
do
  functionName=$(echo "$triggerSpec" | connector_jq -r '.functionName')
  operationName=$(echo "$triggerSpec" | connector_jq -r '.operationName')
  description=$(echo "$triggerSpec" | connector_jq -r '.description')
  triggerName="${connectorNamespaceConnectionName}-$(echo "${functionName}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$(echo "$triggerSpec" | connector_jq -r '.enabled')" != "true" ]]; then
    if echo "$existingNames" | connector_jq -e --arg name "$triggerName" 'index($name) != null' >/dev/null; then
      az connector-namespace trigger update \
        -g "${resourceGroupName}" --namespace "${connectorNamespaceName}" \
        -n "${triggerName}" --state Disabled -o none
    fi
    echo "  Skipping opt-in trigger: ${functionName}"
    continue
  fi
  callbackUrl="https://${functionAppDefaultHostname}/runtime/webhooks/connector?functionName=${functionName}"
  notifFile="$temp_dir/notification.json"
  paramsFile="$temp_dir/parameters.json"
  connector_jq -n --arg url "$callbackUrl" --arg key "$connectorExtensionKey" \
    '{callbackUrl:$url,authentication:{type:"QueryString",name:"code",value:$key}}' > "$notifFile"
  echo "$triggerSpec" | connector_jq '.parameters' > "$paramsFile"

  echo -e "${CYAN}  Creating trigger: ${functionName} -> ${operationName}${NC}"

  verb=create
  if echo "$existingNames" | connector_jq -e --arg name "$triggerName" 'index($name) != null' >/dev/null; then verb=update; fi
  az connector-namespace trigger "$verb" \
    -g "${resourceGroupName}" --namespace "${connectorNamespaceName}" \
    -n "${triggerName}" \
    --connection-details "{connectionName:${connectorNamespaceConnectionName},connectorName:sharepointonline}" \
    --operation-name "${operationName}" \
    --parameters "@${paramsFile}" \
    --notification-details "@${notifFile}" \
    --description "${description}" \
    --metadata "{destinationType:functionApp,functionAppName:${functionAppName},functionAppResourceGroup:${resourceGroupName},functionAppSubscriptionId:${subscriptionId},functionName:${functionName},recurrenceFrequency:Minute,recurrenceInterval:'5'}" \
    -o none 2>/dev/null || { echo "Could not configure trigger $functionName." >&2; exit 1; }

  rm -f "$notifFile" "$paramsFile"
done < <(echo "$triggerDefinitions" | connector_jq -c '.[]')

echo -e "${GREEN}✅ All trigger configs created.${NC}"
echo ""
echo -e "${YELLOW}Authorizing sharepointonline connection...${NC}"

currentStatus=$(az connector-namespace connection show \
  -g "${resourceGroupName}" --namespace "${connectorNamespaceName}" \
  -n "${connectorNamespaceConnectionName}" \
  --query "properties.overallStatus" -o tsv 2>/dev/null || true)
currentStatus="${currentStatus%$'\r'}"

if [[ "${currentStatus}" == "Connected" ]]; then
  echo -e "${GREEN}Connection is already authorized.${NC}"
else
  echo -e "${CYAN}-> A browser tab will open. Sign in with the account that has access to the SharePoint site.${NC}"

  consentLink=""
  for attempt in 1 2 3 4 5; do
    consentLink=$(az connector-namespace connection list-consent-links \
      -g "${resourceGroupName}" --namespace "${connectorNamespaceName}" \
      --connection-name "${connectorNamespaceConnectionName}" \
      --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" \
      --query "value[0].link" -o tsv 2>/dev/null || true)
    consentLink="${consentLink%$'\r'}"

    if [[ -z "${consentLink}" || "${consentLink}" == "null" ]]; then
      consentLink=$(az connector-namespace connection list-consent-links \
        -g "${resourceGroupName}" --namespace "${connectorNamespaceName}" \
        --connection-name "${connectorNamespaceConnectionName}" \
        --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" \
        --query "link" -o tsv 2>/dev/null || true)
      consentLink="${consentLink%$'\r'}"
    fi

    if [[ -n "${consentLink}" && "${consentLink}" != "null" ]]; then
      break
    fi

    if [[ "${attempt}" != "5" ]]; then
      echo -e "${YELLOW}list-consent-links attempt ${attempt} failed. Retrying in 5 seconds...${NC}"
      sleep 5
    fi
  done

  if [[ -z "${consentLink}" || "${consentLink}" == "null" ]]; then
    echo -e "${RED}Failed to create consent link.${NC}"
    exit 1
  fi

  echo -e "${CYAN}Consent URL: ${consentLink}${NC}"

  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "${consentLink}" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then
    open "${consentLink}" >/dev/null 2>&1 || true
  else
    echo -e "${YELLOW}Unable to open a browser automatically. Paste the consent URL into your browser.${NC}"
  fi

  deadline=$((SECONDS + 300))
  lastPrintedStatus="${currentStatus}"
  echo -e "${CYAN}Connection status: ${currentStatus}${NC}"

  while (( SECONDS < deadline )); do
    sleep 3
    currentStatus=$(az connector-namespace connection show \
      -g "${resourceGroupName}" --namespace "${connectorNamespaceName}" \
      -n "${connectorNamespaceConnectionName}" \
      --query "properties.overallStatus" -o tsv 2>/dev/null || true)
    currentStatus="${currentStatus%$'\r'}"

    if [[ "${currentStatus}" != "${lastPrintedStatus}" ]]; then
      echo -e "${CYAN}Connection status: ${currentStatus}${NC}"
      lastPrintedStatus="${currentStatus}"
    fi

    if [[ "${currentStatus}" == "Connected" ]]; then
      break
    fi
  done

  if [[ "${currentStatus}" != "Connected" ]]; then
    echo -e "${RED}Timed out waiting for the connection to reach Connected status.${NC}"
    exit 1
  fi
fi

echo ""
echo -e "${GREEN}✅ Done. Selected SharePoint triggers are configured; prerequisite-dependent triggers remain opt-in.${NC}"
echo -e "${GREEN}   Tail logs:  az functionapp log tail -g ${resourceGroupName} -n ${functionAppName}${NC}"
echo ""
