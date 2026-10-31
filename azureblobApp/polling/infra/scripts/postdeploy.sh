#!/usr/bin/env bash
set -euo pipefail
umask 077

forceLocalSettings=false
for argument in "$@"; do
    case "$argument" in
        --force-local-settings|-ForceLocalSettings) forceLocalSettings=true ;;
        *) echo "ERROR: Unknown argument: $argument" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! az extension show --name connector-namespace --query name -o tsv >/dev/null 2>&1; then
    echo "ERROR: Install the connector-namespace Azure CLI extension before running this script." >&2
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
        echo "ERROR: Missing azd output $1. Run azd provision first." >&2
        return 1
    fi
    printf '%s' "$value"
}

resourceGroupName=$(read_output resourceGroupName)
connectorNamespaceName=$(read_output connectorNamespaceName)
connectionName=$(read_output connectorNamespaceConnectionName)
pollingEndpoint=$(read_output connectorPollingEndpoint)
triggerConfigName=$(read_output onUpdatedFileTriggerConfigName)

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

localSettingsPath="$SCRIPT_DIR/../../local.settings.json"
if [[ -e "$localSettingsPath" && "$forceLocalSettings" != true ]]; then
    echo "Existing local.settings.json preserved. Use --force-local-settings to regenerate it."
else
    if ! settingsTemp=$(mktemp "$SCRIPT_DIR/../../.local-settings.XXXXXX"); then
        echo "ERROR: Could not create the local settings staging file." >&2
        exit 1
    fi
    trap 'rm -f "$settingsTemp"' EXIT
    printf '{\n  "IsEncrypted": false,\n  "Values": {\n    "AzureWebJobsStorage": "UseDevelopmentStorage=true",\n    "FUNCTIONS_WORKER_RUNTIME": "dotnet-isolated",\n    "ConnectorNamespace__pollingEndpoint": "%s",\n    "OnUpdatedFileTriggerConfigName": "%s"\n  }\n}\n' \
        "$(json_escape "$pollingEndpoint")" "$(json_escape "$triggerConfigName")" > "$settingsTemp"
    mv "$settingsTemp" "$localSettingsPath"
    echo "Created ignored local.settings.json using developer credentials and Azurite."
fi

get_connection_status() {
    local status
    if ! status=$(az connector-namespace connection show \
        -g "$resourceGroupName" --namespace "$connectorNamespaceName" -n "$connectionName" \
        --query properties.overallStatus -o tsv); then
        echo "ERROR: Could not read the Azure Blob connection status." >&2
        return 1
    fi
    printf '%s' "${status//$'\r'/}"
}

status=$(get_connection_status)
if [[ "$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]')" == connected ]]; then
    echo "Azure Blob connection is already authorized."
    exit 0
fi

echo "Authorize Azure Blob with the developer account granted access to the monitored storage account."
consentParameters="[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]"
link=""
for attempt in 1 2 3 4 5; do
    if ! link=$(az connector-namespace connection list-consent-links \
        -g "$resourceGroupName" --namespace "$connectorNamespaceName" --connection-name "$connectionName" \
        --parameters "$consentParameters" --query 'value[0].link' -o tsv 2>/dev/null); then
        link=""
    fi
    link="${link//$'\r'/}"
    if [[ -z "$link" || "$link" == null ]]; then
        if ! link=$(az connector-namespace connection list-consent-links \
            -g "$resourceGroupName" --namespace "$connectorNamespaceName" --connection-name "$connectionName" \
            --parameters "$consentParameters" --query link -o tsv 2>/dev/null); then
            link=""
        fi
    fi
    link="${link//$'\r'/}"
    [[ -n "$link" && "$link" != null ]] && break
    link=""
    if [[ "$attempt" -lt 5 ]]; then sleep 5; fi
done
if [[ -z "$link" ]]; then
    echo "ERROR: Could not obtain an Azure Blob consent link." >&2
    exit 1
fi

echo "Consent URL: $link"
xdg-open "$link" 2>/dev/null || open "$link" 2>/dev/null || \
    echo "Could not open the browser. Open the printed consent URL manually."

deadline=$((SECONDS + 300))
while [[ "$SECONDS" -lt "$deadline" ]]; do
    sleep 3
    status=$(get_connection_status)
    if [[ "$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]')" == connected ]]; then
        echo "Azure Blob connection authorized. The Poll trigger configuration is provisioned."
        exit 0
    fi
done
echo "ERROR: Timed out waiting for the Azure Blob connection to become Connected." >&2
exit 1
