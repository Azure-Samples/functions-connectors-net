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
existing=$(az connector-namespace trigger list -g "$rg" --namespace "$namespace" --query '[].{name:name,id:id}' -o json)
disable_poll_trigger() (
    local uri=$1 name=$2 body stage='' response_file='' acquired file
    cleanup_poll_update() {
        local result=$?
        trap - EXIT
        for file in "$response_file" "$stage"; do
            if [[ -n "$file" ]]; then
                rm -f -- "$file" || { echo 'ERROR: Poll update staging cleanup failed.' >&2; [[ "$result" -ne 0 ]] || result=1; }
            fi
        done
        exit "$result"
    }
    trap cleanup_poll_update EXIT
    acquired=$(mktemp "$script_dir/.parameters-XXXXXXXX") ||
        { echo 'ERROR: could not create Poll response staging file.' >&2; exit 1; }
    response_file=$acquired
    az rest --method get --url "$uri" --output-file "$response_file" -o none ||
        { echo "ERROR: could not read Planner trigger $name." >&2; exit 1; }
    body=$(connector_jq -ce '
        .properties | if type == "object" and .deliveryMode == "Poll" and
          (.connectionDetails | type == "object") and (.operationName | type == "string" and length > 0) and
          (.parameters | type == "array")
        then {properties:(del(.provisioningState,.pollingEndpoints) | .state="Disabled")}
        else error("Expected complete Poll configuration") end' "$response_file") ||
        { echo "ERROR: Planner trigger $name must have a complete Poll configuration." >&2; exit 1; }
    acquired=$(mktemp "$script_dir/.parameters-XXXXXXXX") ||
        { echo 'ERROR: could not create Poll update staging file.' >&2; exit 1; }
    stage=$acquired
    printf '%s\n' "$body" > "$stage" ||
        { echo 'ERROR: could not write Poll update staging file.' >&2; exit 1; }
    az rest --method put --url "$uri" --headers 'Content-Type=application/json' --body "@$stage" -o none ||
        { echo "ERROR: could not disable trigger $name." >&2; exit 1; }
)
while IFS= read -r name; do
    entry=$(connector_jq -c --arg name "$name" '
      if type != "array" then error("Expected trigger list") else
        map(select(.name == $name)) | if length == 0 then null elif length == 1 then .[0]
        else error("Ambiguous Planner trigger") end end' <<< "$existing")
    [[ "$entry" != null ]] || continue
    id=$(connector_jq -er --arg rg "$rg" --arg namespace "$namespace" --arg name "$name" '
      .id | select(type == "string") |
      select((split("/") | map(ascii_downcase)) as $p |
        ($p | length) == 11 and $p[0] == "" and $p[1] == "subscriptions" and ($p[2] | length) > 0 and
        $p[3] == "resourcegroups" and $p[4] == ($rg | ascii_downcase) and $p[5] == "providers" and
        $p[6] == "microsoft.web" and $p[7] == "connectorgateways" and $p[8] == ($namespace | ascii_downcase) and
        $p[9] == "triggerconfigs" and $p[10] == ($name | ascii_downcase))' <<< "$entry") ||
        { echo "ERROR: missing or invalid resource ID for Planner trigger $name." >&2; exit 1; }
    disable_poll_trigger "https://management.azure.com${id}?api-version=2026-05-01-preview" "$name"
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
