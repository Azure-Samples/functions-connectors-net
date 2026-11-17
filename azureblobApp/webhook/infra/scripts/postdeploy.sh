#!/usr/bin/env bash
# Post-deployment configuration for the azureblobApp.
#
# The Azure Blob connection uses the namespace's managed identity.
# This script waits for connection readiness, then configures the webhook trigger.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/local-settings.sh"
command -v jq >/dev/null 2>&1 || { echo 'ERROR: jq 1.6 or later is required for the Bash hook.' >&2; exit 1; }
notifFile=''
cleanup_callback() {
    result=$?
    trap - EXIT
    if [[ -n "$notifFile" ]]; then
        rm -f -- "$notifFile" || { echo 'Could not clean owned callback staging file.' >&2; [[ "$result" -ne 0 ]] || result=1; }
    fi
    exit "$result"
}
trap cleanup_callback EXIT

echo "Post-deployment configuration..."

# --- Pre-flight: verify the connector-namespace CLI extension is installed ----
if ! az extension show --name connector-namespace --query name -o tsv 2>/dev/null; then
    echo "ERROR: The 'connector-namespace' Azure CLI extension is required."
    echo "Install: curl -fsSL https://aka.ms/connector-namespace-cli-install | sh"
    exit 1
fi

# --- Read azd outputs --------------------------------------------------------
if ! environmentValues=$(azd env get-values); then
    echo "ERROR: Could not read the selected azd environment." >&2
    exit 1
fi

read_output() {
    local value
    if ! value=$(azd env get-value "$1"); then
        echo "ERROR: Could not read azd output $1." >&2
        return 1
    fi
    value="${value%$'\r'}"
    if [[ -z "${value//[[:space:]]/}" || "$value" == "null" ]]; then
        if [[ -z "${2:-}" ]]; then
            echo "ERROR: Missing azd output $1. Run azd provision first." >&2
            return 1
        fi
        value="$2"
    fi
    printf '%s' "$value"
}

resourceGroupName=$(read_output resourceGroupName)
connectorNamespaceName=$(read_output connectorNamespaceName)
connectorNamespaceConnectionName=$(read_output connectorNamespaceConnectionName)
functionAppName=$(read_output functionAppName)
functionAppDefaultHostname=$(read_output functionAppDefaultHostname)
monitoredStorageAccountName=$(read_output monitoredStorageAccountName)
if printf '%s\n' "$environmentValues" | grep '^monitoredContainerName=' >/dev/null; then
    monitoredContainerName=$(read_output monitoredContainerName connector-input)
else
    monitoredContainerName=connector-input
fi
AZURE_SUBSCRIPTION_ID=$(read_output AZURE_SUBSCRIPTION_ID)

localSettings='{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "dotnet-isolated"
  }
}'
write_local_settings "$localSettings"

functionName="OnUpdatedFile"
operationName="OnUpdatedFiles_V2"
triggerName="${connectorNamespaceConnectionName}-onupdatedfile"
existing=$(az connector-namespace trigger list -g "$resourceGroupName" --namespace "$connectorNamespaceName" --query '[].name' -o json 2>/dev/null) ||
    { echo 'Could not list existing Azure Blob trigger configurations.' >&2; exit 1; }
connector_jq -e 'type == "array" and all(.[]; type == "string")' <<<"$existing" >/dev/null 2>/dev/null ||
    { echo 'Invalid Azure Blob trigger configuration list.' >&2; exit 1; }
verb=create
if connector_jq -e --arg name "$triggerName" 'index($name) != null' <<<"$existing" >/dev/null; then
    verb=update
fi

# --- Wait for the managed-identity connection -------------------------------
echo ""
echo "Checking Azure Blob managed-identity connection readiness (no user consent required)..."

connectionUrl="https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$resourceGroupName/providers/Microsoft.Web/connectorGateways/$connectorNamespaceName/connections/$connectorNamespaceConnectionName?api-version=2026-05-01-preview"
authSet=$(az rest --method get --url "$connectionUrl" --query properties.parameterValueSet.name -o tsv) ||
    { echo 'Could not read the Azure Blob connection authentication type.' >&2; exit 1; }
if [[ "${authSet%$'\r'}" != managedIdentityAuth ]]; then
    echo 'Azure Blob connection is not configured for managedIdentityAuth. Reprovision to create the MI-specific connection; an existing OAuth connection cannot be validated as managed identity.' >&2
    exit 1
fi

get_connection_status() {
    local status
    if ! status=$(az connector-namespace connection show \
        -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
        -n "$connectorNamespaceConnectionName" \
        --query "properties.overallStatus" -o tsv); then
        echo "ERROR: Could not read the Azure Blob connection status." >&2
        return 1
    fi
    printf '%s' "${status%$'\r'}"
}

deadline=$((SECONDS + 300))
connected=false
while true; do
    status=$(get_connection_status)
    if [[ "$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]')" =~ ^(ready|connected)$ ]]; then
        connected=true
        break
    fi
    [[ "$SECONDS" -lt "$deadline" ]] || break
    sleep 5
done

if [ "$connected" != "true" ]; then
    echo "ERROR: Timed out waiting for the Azure Blob managed-identity connection to become Ready or Connected. Verify the namespace connection access policy and namespace Storage Blob Data Reader access on the monitored storage account. Allow RBAC propagation, then rerun the hook." >&2
    exit 1
fi
echo "   Managed-identity connection is $status"

# --- Container path for the trigger ----------------------------------------
containerName="${monitoredContainerName:-connector-input}"
urlEncodedPath="%2f${containerName}"
folderId=$(printf '%s' "$urlEncodedPath" | base64 | tr -d '\r\n')
echo "Container '${containerName}' -> folderId '${folderId}'"

# --- Create Connector Namespace trigger config -------------------------------
echo ""
echo "Fetching connector extension key for $functionAppName..."
connectorExtensionKey=$(az functionapp keys list -g "$resourceGroupName" -n "$functionAppName" --query "systemKeys.connector_extension" -o tsv 2>/dev/null) ||
    { echo 'ERROR: Could not read connector_extension system key.' >&2; exit 1; }
connectorExtensionKey="${connectorExtensionKey%$'\r'}"
if [[ -z "${connectorExtensionKey//[[:space:]]/}" || "$connectorExtensionKey" == null ]]; then
    echo "ERROR: could not fetch connector_extension system key."
    exit 1
fi

callbackUrl="https://${functionAppDefaultHostname}/runtime/webhooks/connector?functionName=${functionName}"
if ! acquiredNotif=$(mktemp "$SCRIPT_DIR/.notification-details.XXXXXXXX"); then
    echo "ERROR: Could not create the notification request file." >&2
    exit 1
fi
notifFile="$acquiredNotif"
connector_jq -n --arg url "$callbackUrl" --arg key "$connectorExtensionKey" \
    '{callbackUrl:$url,authentication:{type:"QueryString",name:"code",value:$key}}' > "$notifFile" ||
    { echo 'Could not write callback staging file.' >&2; exit 1; }

echo ""
echo "Configuring trigger '${triggerName}' for ${functionName} (${operationName})..."

az connector-namespace trigger "$verb" \
    -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
    -n "$triggerName" \
    --connection-details "{connectionName:${connectorNamespaceConnectionName},connectorName:azureblob}" \
    --operation-name "$operationName" \
    --parameters "[{name:dataset,value:'${monitoredStorageAccountName}'},{name:folderId,value:'${folderId}'}]" \
    --notification-details "@${notifFile}" \
    --state Enabled \
    --description "When a blob is added or modified (properties only) (V2)" \
    --metadata "{destinationType:functionApp,functionAppName:${functionAppName},functionAppResourceGroup:${resourceGroupName},functionAppSubscriptionId:${AZURE_SUBSCRIPTION_ID},functionName:${functionName},recurrenceFrequency:Minute,recurrenceInterval:'5'}" \
    -o none 2>/dev/null ||
    { echo "Could not configure Azure Blob trigger $triggerName." >&2; exit 1; }

rm -f -- "$notifFile" || { echo 'Could not clean owned callback staging file.' >&2; exit 1; }
notifFile=''

echo ""
echo "Post-deployment configuration complete."
echo "Upload blobs to the '${containerName}' container in storage account '${monitoredStorageAccountName}' to fire the trigger."
echo "Tail logs: az functionapp log tail -g $resourceGroupName -n $functionAppName"
echo ""
