#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/local-settings.sh"
temp_dir=""
cleanup_notif_files() {
    result=$?
    trap - EXIT
    if [ -n "$temp_dir" ]; then
        cleanup_failed=false
        rm -f -- "$temp_dir/notification.json" || cleanup_failed=true
        rm -f -- "$temp_dir/parameters.json" || cleanup_failed=true
        rmdir -- "$temp_dir" || cleanup_failed=true
        if [ "$cleanup_failed" = true ]; then
            echo 'Could not clean owned callback staging files.' >&2
            [ "$result" -ne 0 ] || result=1
        fi
    fi
    exit "$result"
}
trap cleanup_notif_files EXIT

if [ "$#" -ne 0 ]; then
    echo "ERROR: Usage: bash postdeploy.sh" >&2
    exit 1
fi

echo "Post-deployment configuration..."

# --- Pre-flight: verify the connector-namespace CLI extension is installed ----
if ! az extension show --name connector-namespace --query name -o tsv 2>/dev/null; then
    echo "ERROR: The 'connector-namespace' Azure CLI extension is required."
    echo "Install: curl -fsSL https://aka.ms/connector-namespace-cli-install | sh"
    exit 1
fi

# --- Read azd outputs --------------------------------------------------------
command -v jq >/dev/null || { echo 'Install jq before running this script.' >&2; exit 1; }
outputs="$(azd env get-values --output json)" ||
    { echo "ERROR: Could not read the selected azd environment." >&2; exit 1; }
read_output() {
    jq --binary -er --arg name "$1" '.[$name] | select(type == "string" and test("\\S"))' <<<"$outputs" ||
        { echo "Missing required azd output $1." >&2; return 1; }
}
resourceGroupName="$(read_output resourceGroupName)"
connectorNamespaceName="$(read_output connectorNamespaceName)"
connectorNamespaceConnectionName="$(read_output connectorNamespaceConnectionName)"
functionAppName="$(read_output functionAppName)"
functionAppDefaultHostname="$(read_output functionAppDefaultHostname)"
subscriptionId="$(read_output AZURE_SUBSCRIPTION_ID)"
ONEDRIVE_FOLDER_ID="$(jq --binary -r '.ONEDRIVE_FOLDER_ID // ""' <<<"$outputs")"

onedriveConnectionName="$connectorNamespaceConnectionName"

write_local_settings '{"IsEncrypted":false,"Values":{"AzureWebJobsStorage":"UseDevelopmentStorage=true","FUNCTIONS_WORKER_RUNTIME":"dotnet-isolated"}}'

get_connection_status() {
    local raw_status
    raw_status=$(az connector-namespace connection show \
        -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
        -n "$onedriveConnectionName" \
        --query "properties.overallStatus" -o tsv 2>/dev/null) ||
        { echo 'Could not read the OneDrive connection status.' >&2; return 1; }
    printf '%s\n' "${raw_status%$'\r'}"
}

# --- Authorize the OneDrive connection (OAuth consent) ----------------------
echo ""
echo "Authorizing OneDrive for Business connection..."

currentStatus="$(get_connection_status)"
if [ "$(printf '%s' "$currentStatus" | tr '[:upper:]' '[:lower:]')" = "connected" ]; then
    echo "   already Connected; skipping consent flow"
else
    consentParameters="[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]"
    consentJson=""
    link=""

    for i in $(seq 1 5); do
        consentJson=$(az connector-namespace connection list-consent-links \
            -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
            --connection-name "$onedriveConnectionName" \
            --parameters "$consentParameters" \
            -o json 2>/dev/null || true)
        if [ -n "$consentJson" ]; then
            link=$(az connector-namespace connection list-consent-links \
                -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
                --connection-name "$onedriveConnectionName" \
                --parameters "$consentParameters" \
                --query "value[0].link" -o tsv 2>/dev/null || true)
            link="${link%$'\r'}"
            if [ -z "$link" ] || [ "$link" = null ]; then
                link=$(az connector-namespace connection list-consent-links \
                    -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
                    --connection-name "$onedriveConnectionName" \
                    --parameters "$consentParameters" \
                    --query "link" -o tsv 2>/dev/null || true)
                link="${link%$'\r'}"
            fi
            [ -n "$link" ] && [ "$link" != null ] && break
        fi
        echo "   list-consent-links attempt $i failed; retrying in 5s..."
        sleep 5
    done

    if [ -z "$consentJson" ]; then
        echo "ERROR: list-consent-links returned no output after retries"
        exit 1
    fi

    if [ -z "$link" ] || [ "$link" = null ]; then
        echo "ERROR: list-consent-links returned no link."
        exit 1
    fi

    echo "   Opening browser for OAuth consent..."
    echo "   (if no tab opens, paste this URL manually: $link)"
    xdg-open "$link" 2>/dev/null || open "$link" 2>/dev/null || echo "   Please open the URL above manually."

    deadline=$((SECONDS + 300))
    lastStatus=""
    authorized=false
    while [ $SECONDS -lt $deadline ]; do
        status="$(get_connection_status)"
        if [ "$status" != "$lastStatus" ]; then
            echo "   status: ${status:-?}"
            lastStatus="$status"
        fi
        if [ "$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]')" = "connected" ]; then
            echo "   Connection authenticated"
            authorized=true
            break
        fi
        sleep 3
    done

    if [ "$authorized" != "true" ]; then
        echo "ERROR: OneDrive connection is not Connected. Complete OAuth consent, then re-run: azd hooks run postdeploy"
        exit 1
    fi
fi

# --- Select OneDrive folder -------------------------------------------------
onedriveFolderId="${ONEDRIVE_FOLDER_ID:-}"
if [ -z "$onedriveFolderId" ]; then
    if [ -t 0 ]; then
        echo ""
        read -rp "Enter OneDrive folder ID to monitor (or press Enter for 'root'): " onedriveFolderId
        onedriveFolderId="${onedriveFolderId:-root}"
    else
        echo "ERROR: Set ONEDRIVE_FOLDER_ID explicitly with 'azd env set' before running non-interactively."
        exit 1
    fi
fi
[[ "$onedriveFolderId" =~ [^[:space:]] ]] ||
    { echo 'OneDrive folderId must be a nonempty string.' >&2; exit 1; }
echo "Using ONEDRIVE_FOLDER_ID=$onedriveFolderId"
azd env set ONEDRIVE_FOLDER_ID "$onedriveFolderId" > /dev/null

# --- Create Connector Namespace trigger configs -----------------------------
echo ""
echo "Fetching connector extension key for $functionAppName..."
existing=$(az connector-namespace trigger list -g "$resourceGroupName" --namespace "$connectorNamespaceName" --query '[].name' -o json 2>/dev/null) ||
    { echo 'Could not list existing webhook trigger configurations.' >&2; exit 1; }
jq --binary -e 'type == "array" and all(.[]; type == "string")' <<<"$existing" >/dev/null ||
    { echo 'Invalid trigger list response.' >&2; exit 1; }
connectorExtensionKey=$(az functionapp keys list -g "$resourceGroupName" -n "$functionAppName" --query "systemKeys.connector_extension" -o tsv 2>/dev/null) ||
    { echo 'Could not fetch the connector_extension system key.' >&2; exit 1; }
connectorExtensionKey="${connectorExtensionKey%$'\r'}"
if [ -z "$connectorExtensionKey" ] || [ "$connectorExtensionKey" = null ]; then
    echo "ERROR: could not fetch connector_extension system key."
    exit 1
fi
candidate_dir=$(mktemp -d "${TMPDIR:-/tmp}/onedrive-callback.XXXXXXXX") ||
    { echo 'Could not create callback staging directory.' >&2; exit 1; }
temp_dir=$candidate_dir

create_trigger() {
    local functionName="$1"
    local operationName="$2"
    local triggerName="${onedriveConnectionName}-$(echo "$functionName" | tr '[:upper:]' '[:lower:]')"
    local callbackUrl="https://${functionAppDefaultHostname}/runtime/webhooks/connector?functionName=${functionName}"
    jq --binary -n --arg url "$callbackUrl" --arg key "$connectorExtensionKey" \
        '{callbackUrl:$url,authentication:{type:"QueryString",name:"code",value:$key}}' > "$temp_dir/notification.json"
    jq --binary -n --arg folder "$onedriveFolderId" '[{name:"folderId",value:$folder}]' > "$temp_dir/parameters.json"

    echo ""
    echo "Configuring trigger '$triggerName' for $functionName ($operationName)..."
    local verb=create
    if jq --binary -e --arg name "$triggerName" 'index($name) != null' <<<"$existing" >/dev/null; then verb=update; fi
    az connector-namespace trigger "$verb" \
        -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
        -n "$triggerName" \
        --connection-details "{connectionName:${onedriveConnectionName},connectorName:onedriveforbusiness}" \
        --operation-name "$operationName" \
        --parameters "@$temp_dir/parameters.json" \
        --notification-details "@$temp_dir/notification.json" \
        --state Enabled \
        --description "OneDrive ${operationName} -> ${functionName}" \
        --metadata "{destinationType:functionApp,functionAppName:${functionAppName},functionAppResourceGroup:${resourceGroupName},functionAppSubscriptionId:${subscriptionId},functionName:${functionName},recurrenceFrequency:Minute,recurrenceInterval:'5'}" \
        -o none 2>/dev/null ||
        { echo "Could not configure webhook trigger $triggerName." >&2; return 1; }
}

create_trigger "OnNewFileContent" "OnNewFileV2"
create_trigger "OnUpdatedFileContent" "OnUpdatedFileV2"
create_trigger "OnNewFile" "OnNewFilesV2"
create_trigger "OnUpdatedFile" "OnUpdatedFilesV2"

echo ""
echo "Post-deployment configuration complete."
echo ""
