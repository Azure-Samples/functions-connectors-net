#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_notif_files=()
settings_temp=""
cleanup_notif_files() {
    for f in "${_notif_files[@]}"; do rm -f "$f"; done
    if [ -n "$settings_temp" ]; then rm -f "$settings_temp"; fi
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
outputs="$(azd env get-values)" ||
    { echo "ERROR: Could not read the selected azd environment." >&2; exit 1; }
eval "$outputs"

: "${resourceGroupName:?required azd output missing}"
: "${connectorNamespaceName:?required azd output missing}"
: "${connectorNamespaceConnectionName:?required azd output missing}"
: "${functionAppName:?required azd output missing}"
: "${functionAppDefaultHostname:?required azd output missing}"

onedriveConnectionName="$connectorNamespaceConnectionName"

settings_path="$SCRIPT_DIR/../../local.settings.json"
if [ -e "$settings_path" ] || [ -L "$settings_path" ]; then
    if [ ! -f "$settings_path" ]; then
        echo "ERROR: local.settings.json must be a regular file, not a directory." >&2
        exit 1
    fi
    echo "Existing local.settings.json preserved."
else
    command -v jq >/dev/null ||
        { echo "ERROR: Install jq before generating local.settings.json." >&2; exit 1; }
    settings_temp="$(mktemp "$(dirname "$settings_path")/.local-settings.XXXXXX")" ||
        { echo "ERROR: Could not create temporary local settings file." >&2; exit 1; }
    cp "$SCRIPT_DIR/../../local.settings.example.json" "$settings_temp" ||
        { echo "ERROR: Could not copy the local settings template." >&2; exit 1; }
    jq -es 'length == 1 and .[0] == {
        IsEncrypted: false,
        Values: {
            AzureWebJobsStorage: "UseDevelopmentStorage=true",
            FUNCTIONS_WORKER_RUNTIME: "dotnet-isolated"
        }
    }' "$settings_temp" >/dev/null ||
        { echo "ERROR: Expected only local Azurite storage and the isolated worker runtime in the settings template." >&2; exit 1; }
    mv -n "$settings_temp" "$settings_path" ||
        { echo "ERROR: Could not move local settings into place." >&2; exit 1; }
    if [ -e "$settings_temp" ]; then
        echo "ERROR: local.settings.json appeared during generation; existing settings were not overwritten." >&2
        exit 1
    fi
    settings_temp=""
    echo "Created ignored local.settings.json for Azurite and the isolated worker."
fi

get_connection_status() {
    az connector-namespace connection show \
        -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
        -n "$onedriveConnectionName" \
        --query "properties.overallStatus" -o tsv 2>/dev/null || true
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
            if [ -z "$link" ]; then
                link=$(az connector-namespace connection list-consent-links \
                    -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
                    --connection-name "$onedriveConnectionName" \
                    --parameters "$consentParameters" \
                    --query "link" -o tsv 2>/dev/null || true)
            fi
            [ -n "$link" ] && break
        fi
        echo "   list-consent-links attempt $i failed; retrying in 5s..."
        sleep 5
    done

    if [ -z "$consentJson" ]; then
        echo "ERROR: list-consent-links returned no output after retries"
        exit 1
    fi

    if [ -z "$link" ]; then
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
echo "Using ONEDRIVE_FOLDER_ID=$onedriveFolderId"
azd env set ONEDRIVE_FOLDER_ID "$onedriveFolderId" > /dev/null

# --- Create Connector Namespace trigger configs -----------------------------
echo ""
echo "Fetching connector extension key for $functionAppName..."
connectorExtensionKey=$(az functionapp keys list -g "$resourceGroupName" -n "$functionAppName" --query "systemKeys.connector_extension" -o tsv)
if [ -z "$connectorExtensionKey" ]; then
    echo "ERROR: could not fetch connector_extension system key."
    exit 1
fi

create_trigger() {
    local functionName="$1"
    local operationName="$2"
    local parameters="$3"
    local triggerName="${onedriveConnectionName}-$(echo "$functionName" | tr '[:upper:]' '[:lower:]')"
    local callbackUrl="https://${functionAppDefaultHostname}/runtime/webhooks/connector?functionName=${functionName}"
    local notifFile
    notifFile="$(mktemp)" ||
        { echo "ERROR: Could not create temporary notification file." >&2; exit 1; }
    _notif_files+=("$notifFile")
    printf '{"callbackUrl":"%s","authentication":{"type":"QueryString","name":"code","value":"%s"}}' "$callbackUrl" "$connectorExtensionKey" > "$notifFile"

    echo ""
    echo "Creating trigger '$triggerName' for $functionName ($operationName)..."

    az connector-namespace trigger delete \
        -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
        -n "$triggerName" --yes 2>/dev/null || true

    az connector-namespace trigger create \
        -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
        -n "$triggerName" \
        --connection-details "{connectionName:${onedriveConnectionName},connectorName:onedriveforbusiness}" \
        --operation-name "$operationName" \
        --parameters "$parameters" \
        --notification-details "@${notifFile}" \
        --description "OneDrive ${operationName} -> ${functionName}" \
        --metadata "{destinationType:functionApp,functionAppName:${functionAppName},functionAppResourceGroup:${resourceGroupName},functionAppSubscriptionId:${AZURE_SUBSCRIPTION_ID},functionName:${functionName},recurrenceFrequency:Minute,recurrenceInterval:'5'}" \
        -o none

    rm -f "$notifFile"
}

create_trigger "OnNewFileContent" "OnNewFileV2" "[{name:folderId,value:'$onedriveFolderId'}]"
create_trigger "OnUpdatedFileContent" "OnUpdatedFileV2" "[{name:folderId,value:'$onedriveFolderId'}]"
create_trigger "OnNewFile" "OnNewFilesV2" "[{name:folderId,value:'$onedriveFolderId'}]"
create_trigger "OnUpdatedFile" "OnUpdatedFilesV2" "[{name:folderId,value:'$onedriveFolderId'}]"

echo ""
echo "Post-deployment configuration complete."
echo ""
