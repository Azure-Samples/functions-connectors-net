#!/usr/bin/env bash
set -euo pipefail
umask 077
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/local-settings.sh"
bash "$script_dir/create-local-settings.sh"
outputs="$(azd env get-values --output json)"
read_output() { connector_jq -er --arg name "$1" '.[$name] | select(type == "string" and length > 0)' <<< "$outputs"; }
subscription="$(read_output AZURE_SUBSCRIPTION_ID)"
group="$(read_output resourceGroupName)"
app="$(read_output functionAppName)"
hostname="$(read_output functionAppDefaultHostname)"
namespace="$(read_output connectorNamespaceName)"
connection="$(read_output connectorNamespaceConnectionName)"
triggers="$(connector_jq -ec '.triggerDefinitions | if type == "string" then fromjson else . end |
  select(type == "array" and length == 2 and ([.[].functionName] | sort) == ["OnNewRecord", "OnUpdatedRecord"])' <<< "$outputs")"
for index in 0 1; do
    trigger="$(connector_jq -c --argjson index "$index" '.[$index]' <<< "$triggers")"
    connector_jq -e '(.functionName == "OnNewRecord" and .operationName == "GetOnNewItems") or
        (.functionName == "OnUpdatedRecord" and .operationName == "GetOnUpdatedItems")' <<< "$trigger" >/dev/null &&
        connector_jq -e '.parameters | type == "array" and
          all(.[]; (.name == "table" or .name == "$filter" or .name == "$orderby" or .name == "$select") and
            (.value | type == "string")) and
          ((map(.name) | unique | length) == length) and
          any(.[]; .name == "table" and (.value | test("\\S")))' <<< "$trigger" >/dev/null ||
        { echo 'Invalid Salesforce trigger definition or parameter array.' >&2; exit 1; }
done
callback_base="${CALLBACK_BASE_URL:-}"
key="${CONNECTOR_EXTENSION_KEY:-}"
is_tunnel=false
if [[ -n "$callback_base" || -n "$key" ]]; then
    is_tunnel=true
    [[ "$callback_base" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ && -n "$key" ]] || {
        echo 'Tunnel delivery requires an HTTPS authority and its local CONNECTOR_EXTENSION_KEY. Start the host with --enableAuth.' >&2
        exit 1
    }
else
    key="$(az functionapp keys list -g "$group" -n "$app" --query systemKeys.connector_extension --only-show-errors -o tsv 2>/dev/null)" ||
        { echo 'Could not retrieve connector_extension.' >&2; exit 1; }
    key="${key%$'\r'}"
    [[ -n "$key" && "$key" != null ]] || { echo 'Could not retrieve connector_extension. Deploy the app and allow its host to start first.' >&2; exit 1; }
    callback_base="https://$hostname"
fi
temp=''
cleanup() {
    result=$?
    trap - EXIT
    if [[ -n "$temp" ]]; then
        rm -f -- "$temp" || { echo 'Could not clean owned callback staging file.' >&2; [[ "$result" -ne 0 ]] || result=1; }
    fi
    exit "$result"
}
trap cleanup EXIT
for index in 0 1; do
    trigger="$(connector_jq -c --argjson index "$index" '.[$index]' <<< "$triggers")"
    function_name="$(connector_jq -er '.functionName | select(. == "OnNewRecord" or . == "OnUpdatedRecord")' <<< "$trigger")"
    operation="$(connector_jq -er '.operationName' <<< "$trigger")"
    expected='GetOnNewItems'
    [[ "$function_name" != OnUpdatedRecord ]] || expected='GetOnUpdatedItems'
    [[ "$operation" == "$expected" ]] || { echo 'Invalid Salesforce trigger definition.' >&2; exit 1; }
    candidate="$(mktemp "$script_dir/../../.trigger-json.XXXXXXXX")" ||
        { result=$?; echo 'Could not create callback staging file.' >&2; exit "$result"; }
    temp="$candidate"
    connector_jq -n --arg connection "$connection" --arg operation "$operation" --arg function "$function_name" \
        --arg callback "${callback_base%/}/runtime/webhooks/connector?functionName=$function_name" \
        --arg key "$key" --arg app "$app" --arg group "$group" --arg subscription "$subscription" \
        --argjson tunnel "$is_tunnel" \
        --argjson parameters "$(connector_jq -ec '.parameters | select(type == "array")' <<< "$trigger")" '{
      properties: {
        connectionDetails: {connectionName: $connection, connectorName: "salesforce"},
        deliveryMode: "Webhook", operationName: $operation, parameters: $parameters,
        state: "Enabled", type: "NotSpecified",
        notificationDetails: {
          callbackUrl: $callback,
          authentication: {type: "QueryString", name: "code", value: $key}
        },
        metadata: ({
          recurrenceFrequency: "Minute", recurrenceInterval: "5"
        } + (if $tunnel then {} else {
          destinationType: "functionApp", functionAppName: $app, functionAppResourceGroup: $group,
          functionAppSubscriptionId: $subscription, functionName: $function
        } end))
      }
    }' > "$temp"
    connector_jq -e '.properties.deliveryMode == "Webhook"' "$temp" > /dev/null
    name="salesforce-$(printf '%s' "$function_name" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    uri="https://management.azure.com/subscriptions/$subscription/resourceGroups/$group/providers/Microsoft.Web/connectorGateways/$namespace/triggerConfigs/$name?api-version=2026-05-01-preview"
    az rest --method put --uri "$uri" --body "@$temp" --only-show-errors -o none 2>/dev/null ||
        { echo "Could not configure $function_name Webhook delivery." >&2; exit 1; }
    rm -f -- "$temp"
    temp=''
done
echo 'Webhook delivery configured. Manually authorize the Salesforce connection for the approved org before testing.'
