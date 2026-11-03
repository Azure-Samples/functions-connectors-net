#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/local-settings.sh"
local_only=false
case "${1:-}" in
    '') ;;
    --local-settings-only) local_only=true; shift ;;
    *) echo 'ERROR: unsupported argument.' >&2; exit 1 ;;
esac
[[ $# -eq 0 ]] || { echo 'ERROR: unexpected arguments.' >&2; exit 1; }
outputs=$(azd env get-values --output json)
get_output() { connector_jq -er --arg key "$1" '.[$key] | select(. != null and . != "")' <<< "$outputs"; }
rg=$(get_output resourceGroupName)
namespace=$(get_output connectorNamespaceName)
connection=$(get_output connectorNamespaceConnectionName)
endpoint=$(get_output connectorPollingEndpoint)
settings=$(get_output triggerConfigSettings | connector_jq 'if type == "string" then fromjson else . end')
definitions=$(get_output triggerDefinitions | connector_jq 'if type == "string" then fromjson else . end')
connector_jq -e 'type == "array" and length == 3' <<< "$definitions" > /dev/null
values=$(connector_jq -n --arg endpoint "$endpoint" --argjson settings "$settings" '
    {AzureWebJobsStorage:"UseDevelopmentStorage=true", FUNCTIONS_WORKER_RUNTIME:"dotnet-isolated",
     ConnectorNamespace__pollingEndpoint:$endpoint} + ($settings | with_entries(
       select(.key | test("^(On(NewTask|CompleteTask|TaskAssignedToMe)TriggerConfigName|AzureWebJobs\\.On(NewTask|CompleteTask|TaskAssignedToMe)\\.Disabled)$"))))')
publish_local_settings "$script_dir/../../local.settings.json" "$(connector_jq -n --argjson values "$values" '{IsEncrypted:false,Values:$values}')"
$local_only && exit 0
existing=$(az connector-namespace trigger list -g "$rg" --namespace "$namespace" --query '[].name' -o json)
while IFS= read -r name; do
    if connector_jq -e --arg name "$name" 'index($name) != null' <<< "$existing" > /dev/null; then
        az connector-namespace trigger update -g "$rg" --namespace "$namespace" -n "$name" --state Disabled -o none
    fi
done < <(connector_jq -r '.[] | select(.enabled == false) | "planner-" + (.functionName | ascii_downcase)' <<< "$definitions")
connection_status() {
    local value
    value=$(az connector-namespace connection show -g "$rg" --namespace "$namespace" -n "$connection" --query 'properties.overallStatus' -o tsv) ||
        { echo 'ERROR: could not read Planner OAuth connection status.' >&2; return 1; }
    printf '%s\n' "${value%$'\r'}"
}
status=$(connection_status)
if [[ "$status" == Connected ]]; then echo 'Planner connection already authorized.'; exit 0; fi
link=$(az connector-namespace connection list-consent-links -g "$rg" --namespace "$namespace" --connection-name "$connection" \
    --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" --query 'value[0].link || link' -o tsv)
link=${link%$'\r'}
[[ -n "$link" && "$link" != null ]] || { echo 'ERROR: could not obtain Planner OAuth consent link.' >&2; exit 1; }
echo "Authorize with a Planner-enabled account that belongs to the selected group. Open: $link"
for ((attempt=0; attempt<100; attempt++)); do
    sleep 3
    status=$(connection_status)
    if [[ "$status" == Connected ]]; then echo 'Planner OAuth connection authorized.'; exit 0; fi
done
echo 'ERROR: timed out waiting for Planner OAuth consent.' >&2
exit 1
