#!/usr/bin/env bash
set -euo pipefail
umask 077

settings_temp=""
cleanup() { if [ -n "$settings_temp" ]; then rm -f "$settings_temp"; fi; }
trap cleanup EXIT

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
    jq -er --arg name "$1" '.[$name] | select(type == "string" and test("\\S"))' <<< "$outputs" ||
        { echo "ERROR: Missing azd output $1. Run azd provision first." >&2; return 1; }
}
resource_group="$(required_value resourceGroupName)"
namespace="$(required_value connectorNamespaceName)"
connection="$(required_value connectorNamespaceConnectionName)"
endpoint="$(required_value connectorPollingEndpoint)"
trigger_settings="$(jq -er '
    .triggerConfigSettings | if type == "string" then fromjson else . end |
    if type == "object" then . else error("Expected triggerConfigSettings object") end
' <<< "$outputs")"

values="$(jq -n --arg endpoint "$endpoint" '{
    AzureWebJobsStorage: "UseDevelopmentStorage=true",
    FUNCTIONS_WORKER_RUNTIME: "dotnet-isolated",
    ConnectorNamespace__pollingEndpoint: $endpoint
}')"
for function_name in OnNewFileContent OnUpdatedFileContent OnNewFile OnUpdatedFile; do
    setting="${function_name}TriggerConfigName"
    value="$(jq -er --arg name "$setting" '.[$name] | select(type == "string" and test("\\S"))' <<< "$trigger_settings")" ||
        { echo "ERROR: Missing trigger configuration setting $setting." >&2; exit 1; }
    values="$(jq --arg name "$setting" --arg value "$value" '. + {($name): $value}' <<< "$values")"
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
settings_path="$script_dir/../../local.settings.json"
if [ -e "$settings_path" ] && [ "$force" != true ]; then
    echo "Existing local.settings.json preserved. Use --force-local-settings to regenerate it."
else
    settings_temp="$(mktemp "$(dirname "$settings_path")/.local-settings.XXXXXX")" ||
        { echo "ERROR: Could not create temporary local settings file." >&2; exit 1; }
    jq -n --argjson values "$values" '{IsEncrypted: false, Values: $values}' > "$settings_temp"
    mv -f "$settings_temp" "$settings_path"
    settings_temp=""
    echo "Created ignored local.settings.json using developer credentials and Azurite."
fi

get_connection_status() {
    az connector-namespace connection show \
        -g "$resource_group" --namespace "$namespace" -n "$connection" \
        --query properties.overallStatus -o tsv | tr -d '\r'
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
        --query 'value[0].link' -o tsv 2>/dev/null | tr -d '\r')" || link=""
    if [ -z "$link" ] || [ "$link" = null ]; then
        link="$(az connector-namespace connection list-consent-links \
            -g "$resource_group" --namespace "$namespace" --connection-name "$connection" \
            --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" \
            --query link -o tsv 2>/dev/null | tr -d '\r')" || link=""
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
