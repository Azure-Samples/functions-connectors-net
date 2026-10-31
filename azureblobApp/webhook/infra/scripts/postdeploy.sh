#!/usr/bin/env bash
# Post-deployment configuration for the azureblobApp.
#
# The Azure Blob connection uses Entra ID (OAuth) authentication.
# This script authorizes the connection via interactive consent,
# then creates the trigger config pointing at the function's connector webhook URL.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_notif_files=()
cleanup_notif_files() { for f in "${_notif_files[@]}"; do rm -f "$f"; done; }
trap cleanup_notif_files EXIT

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
    value="${value//$'\r'/}"
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

localSettingsPath="$SCRIPT_DIR/../../local.settings.json"
if [[ -L "$localSettingsPath" || ( -e "$localSettingsPath" && ! -f "$localSettingsPath" ) ]]; then
    echo "ERROR: local.settings.json must be a regular file." >&2
    exit 1
elif [[ -f "$localSettingsPath" ]]; then
    echo "Existing local.settings.json preserved."
else
    if ! settingsTemp=$(mktemp "$SCRIPT_DIR/../../.local-settings.XXXXXX"); then
        echo "ERROR: Could not create the local settings staging file." >&2
        exit 1
    fi
    _notif_files+=("$settingsTemp")
    localSettings='{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "dotnet-isolated"
  }
}'
    printf '%s\n' "$localSettings" > "$settingsTemp"
    if [[ "$(cat "$settingsTemp")" != "$localSettings" ]]; then
        echo "ERROR: Could not validate the generated local settings." >&2
        exit 1
    fi
    mv -n "$settingsTemp" "$localSettingsPath"
    if [[ -d "$localSettingsPath" ]]; then
        _notif_files+=("$localSettingsPath/${settingsTemp##*/}")
        echo "ERROR: local.settings.json became a directory during setup." >&2
        exit 1
    fi
    if [[ -e "$settingsTemp" ]]; then
        echo "ERROR: local.settings.json appeared during setup; existing settings preserved." >&2
        exit 1
    fi
    echo "Created ignored local.settings.json using Azurite."
fi

# --- Authorize the Azure Blob connection (OAuth consent) --------------------
echo ""
echo "Authorizing Azure Blob Storage connection..."

get_connection_status() {
    local status
    if ! status=$(az connector-namespace connection show \
        -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
        -n "$connectorNamespaceConnectionName" \
        --query "properties.overallStatus" -o tsv); then
        echo "ERROR: Could not read the Azure Blob connection status." >&2
        return 1
    fi
    printf '%s' "${status//$'\r'/}"
}

currentStatus=$(get_connection_status)

if [ "$(echo "$currentStatus" | tr '[:upper:]' '[:lower:]')" = "connected" ]; then
    echo "   already Connected; skipping consent flow"
else
    consentParams="[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]"
    link=""
    for attempt in 1 2 3 4 5; do
        link=$(az connector-namespace connection list-consent-links \
            -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
            --connection-name "$connectorNamespaceConnectionName" \
            --parameters "$consentParams" \
            --query "value[0].link" -o tsv 2>/dev/null || true)

        if [ -z "$link" ] || [ "$link" = "null" ]; then
            link=$(az connector-namespace connection list-consent-links \
                -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
                --connection-name "$connectorNamespaceConnectionName" \
                --parameters "$consentParams" \
                --query "link" -o tsv 2>/dev/null || true)
        fi

        [ -n "$link" ] && [ "$link" != "null" ] && break
        link=""
        if [ "$attempt" -lt 5 ]; then
            echo "   list-consent-links attempt ${attempt} failed; retrying in 5s..."
            sleep 5
        fi
    done

    if [ -z "$link" ]; then
        echo "ERROR: could not obtain consent link after retries."
        exit 1
    fi

    echo "   opening browser for OAuth consent..."
    echo "   (if no tab opens, paste this URL manually: $link)"
    xdg-open "$link" 2>/dev/null || open "$link" 2>/dev/null || echo "   (could not open browser — please open the URL above manually)"

    deadline=$((SECONDS + 300))
    authorized=false
    while [ $SECONDS -lt $deadline ]; do
        sleep 5
        status=$(get_connection_status)
        echo "   status: ${status:-unknown}"
        if [ "$(echo "$status" | tr '[:upper:]' '[:lower:]')" = "connected" ]; then
            authorized=true
            break
        fi
    done

    if [ "$authorized" != "true" ]; then
        echo "ERROR: Connection did not reach 'Connected' status within 5 minutes."
        exit 1
    fi
    echo "   Connection authenticated"
fi

# --- Container path for the trigger ----------------------------------------
containerName="${monitoredContainerName:-connector-input}"
urlEncodedPath="%2f${containerName}"
folderId=$(printf '%s' "$urlEncodedPath" | base64 | tr -d '\r\n')
echo "Container '${containerName}' -> folderId '${folderId}'"

# --- Create Connector Namespace trigger config -------------------------------
echo ""
echo "Fetching connector extension key for $functionAppName..."
connectorExtensionKey=$(az functionapp keys list -g "$resourceGroupName" -n "$functionAppName" --query "systemKeys.connector_extension" -o tsv)
if [ -z "$connectorExtensionKey" ]; then
    echo "ERROR: could not fetch connector_extension system key."
    exit 1
fi

functionName="OnUpdatedFile"
operationName="OnUpdatedFiles_V2"
triggerName="${connectorNamespaceConnectionName}-$(echo "$functionName" | tr '[:upper:]' '[:lower:]')"
callbackUrl="https://${functionAppDefaultHostname}/runtime/webhooks/connector?functionName=${functionName}"
if ! notifFile=$(mktemp); then
    echo "ERROR: Could not create the notification request file." >&2
    exit 1
fi
_notif_files+=("$notifFile")
printf '{"callbackUrl":"%s","authentication":{"type":"QueryString","name":"code","value":"%s"}}' "$callbackUrl" "$connectorExtensionKey" > "$notifFile"

echo ""
echo "Creating trigger '${triggerName}' for ${functionName} (${operationName})..."

az connector-namespace trigger delete \
    -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
    -n "$triggerName" --yes 2>/dev/null || true

az connector-namespace trigger create \
    -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
    -n "$triggerName" \
    --connection-details "{connectionName:${connectorNamespaceConnectionName},connectorName:azureblob}" \
    --operation-name "$operationName" \
    --parameters "[{name:dataset,value:'${monitoredStorageAccountName}'},{name:folderId,value:'${folderId}'}]" \
    --notification-details "@${notifFile}" \
    --description "When a blob is added or modified (properties only) (V2)" \
    --metadata "{destinationType:functionApp,functionAppName:${functionAppName},functionAppResourceGroup:${resourceGroupName},functionAppSubscriptionId:${AZURE_SUBSCRIPTION_ID},functionName:${functionName},recurrenceFrequency:Minute,recurrenceInterval:'5'}" \
    -o none

rm -f "$notifFile"

echo ""
echo "Post-deployment configuration complete."
echo "Upload blobs to the '${containerName}' container in storage account '${monitoredStorageAccountName}' to fire the trigger."
echo "Tail logs: az functionapp log tail -g $resourceGroupName -n $functionAppName"
echo ""
