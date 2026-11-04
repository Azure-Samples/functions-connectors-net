#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$script_dir/../.." && pwd)"
source "$script_dir/local-settings.sh"

force=false
case "${1:-}" in
    "") ;;
    --force-local-settings) force=true; shift ;;
    *) echo "ERROR: Usage: bash postdeploy.sh [--force-local-settings]" >&2; exit 1 ;;
esac
if [ "$#" -ne 0 ]; then
    echo "ERROR: Usage: bash postdeploy.sh [--force-local-settings]" >&2
    exit 1
fi

command -v jq >/dev/null || { echo "ERROR: Install jq before running this script." >&2; exit 1; }
az extension show --name connector-namespace --query name -o tsv >/dev/null ||
    { echo "ERROR: Install the connector-namespace Azure CLI extension." >&2; exit 1; }

outputs="$(azd env get-values --output json)"
required_value() {
    jq --binary -er --arg name "$1" '.[$name] | select(type == "string" and test("\\S"))' <<< "$outputs" ||
        { echo "ERROR: Missing azd output $1. Run azd provision first." >&2; return 1; }
}
resource_group="$(required_value resourceGroupName)"
namespace="$(required_value connectorNamespaceName)"
connection="$(required_value connectorNamespaceConnectionName)"
endpoint="$(required_value connectorPollingEndpoint)"
trigger_settings="$(jq --binary -er '
    .triggerConfigSettings | if type == "string" then fromjson else . end |
    if type == "object" then . else error("Expected triggerConfigSettings object") end
' <<< "$outputs")"

values="$(jq --binary -n --arg endpoint "$endpoint" '{
    AzureWebJobsStorage: "UseDevelopmentStorage=true",
    FUNCTIONS_WORKER_RUNTIME: "dotnet-isolated",
    ConnectorNamespace__pollingEndpoint: $endpoint
}')"
for function_name in OnNewFileContent OnUpdatedFileContent OnNewFile OnUpdatedFile; do
    setting="${function_name}TriggerConfigName"
    value="$(jq --binary -er --arg name "$setting" '.[$name] | select(type == "string" and test("\\S"))' <<< "$trigger_settings")" ||
        { echo "ERROR: Missing trigger configuration setting $setting." >&2; exit 1; }
    values="$(jq --binary --arg name "$setting" --arg value "$value" '. + {($name): $value}' <<< "$values")"
done

write_local_settings "$(jq --binary -n --argjson values "$values" '{IsEncrypted: false, Values: $values}')" "$force"

get_connection_status() {
    local raw_status
    raw_status=$(az connector-namespace connection show \
        -g "$resource_group" --namespace "$namespace" -n "$connection" \
        --query properties.overallStatus -o tsv) ||
        { echo 'Could not read the OneDrive connection status.' >&2; return 1; }
    printf '%s\n' "${raw_status%$'\r'}"
}
status="$(get_connection_status)" ||
    { echo "ERROR: Could not read the OneDrive connection status." >&2; exit 1; }
if [ "$status" = Connected ]; then
    echo "OneDrive connection is already authorized."
    exit 0
fi

link=""
for ((attempt = 1; attempt <= 5; attempt++)); do
    link="$(az connector-namespace connection list-consent-links \
        -g "$resource_group" --namespace "$namespace" --connection-name "$connection" \
        --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" \
        --query 'value[0].link' -o tsv 2>/dev/null)" || link=""
    link="${link%$'\r'}"
    if [ -z "$link" ] || [ "$link" = null ]; then
        link="$(az connector-namespace connection list-consent-links \
            -g "$resource_group" --namespace "$namespace" --connection-name "$connection" \
            --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" \
            --query link -o tsv 2>/dev/null)" || link=""
        link="${link%$'\r'}"
    fi
    if [ -n "$link" ] && [ "$link" != null ]; then break; fi
    if [ "$attempt" -lt 5 ]; then sleep 5; fi
done
if [ -z "$link" ] || [ "$link" = null ]; then
    echo "ERROR: Could not obtain a OneDrive consent link after five attempts." >&2
    exit 1
fi

echo "Consent URL: $link"
if command -v xdg-open >/dev/null; then
    xdg-open "$link" || echo "Open the consent URL in your browser."
elif command -v open >/dev/null; then
    open "$link" || echo "Open the consent URL in your browser."
else
    echo "Open the consent URL in your browser."
fi

deadline=$((SECONDS + 300))
while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 3
    status="$(get_connection_status)" ||
        { echo "ERROR: Could not read the OneDrive connection status." >&2; exit 1; }
    if [ "$status" = Connected ]; then
        echo "OneDrive connection authorized. All four Poll trigger configurations are provisioned."
        exit 0
    fi
done
echo "ERROR: Timed out waiting for the OneDrive connection to become Connected." >&2
exit 1
