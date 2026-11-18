#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/local-settings.sh"
local_only=false callback='' key=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --local-settings-only) local_only=true; shift ;;
        --callback-base-url) callback=${2:?Missing callback URL}; shift 2 ;;
        --connector-extension-key) key=${2:?Missing connector extension key}; shift 2 ;;
        *) echo 'ERROR: unsupported argument.' >&2; exit 1 ;;
    esac
done
local_callback=false
if [[ -n "$callback" || -n "$key" ]]; then
    [[ "$callback" == https://* && -n "$key" ]] || { echo 'ERROR: local callbacks require a public HTTPS URL and local connector_extension key.' >&2; exit 1; }
    local_callback=true
fi
outputs=$(azd env get-values --output json)
get_output() { connector_jq -er --arg name "$1" '.[$name] | select(. != null and . != "")' <<< "$outputs"; }
rg=$(get_output resourceGroupName)
namespace=$(get_output connectorNamespaceName)
connection=$(get_output connectorNamespaceConnectionName)
app=$(get_output functionAppName)
settings=$(get_output triggerConfigSettings | connector_jq 'if type == "string" then fromjson else . end')
definitions=$(get_output triggerDefinitions | connector_jq 'if type == "string" then fromjson else . end')
connector_jq -e 'type == "array" and length == 3' <<< "$definitions" > /dev/null
values=$(connector_jq -n --argjson settings "$settings" '
    {AzureWebJobsStorage:"UseDevelopmentStorage=true", FUNCTIONS_WORKER_RUNTIME:"dotnet-isolated"} +
    ($settings | with_entries(select(.key | test("^AzureWebJobs\\.On(NewTask|CompleteTask|TaskAssignedToMe)\\.Disabled$"))))')
publish_local_settings "$script_dir/../../local.settings.json" "$(connector_jq -n --argjson values "$values" '{IsEncrypted:false,Values:$values}')"
$local_only && exit 0
subscription=$(get_output AZURE_SUBSCRIPTION_ID)
existing=$(az connector-namespace trigger list -g "$rg" --namespace "$namespace" --query '[].name' -o json)
if [[ -z "$callback" ]]; then
    callback="https://$(get_output functionAppDefaultHostname)"
    key=$(az functionapp keys list -g "$rg" -n "$app" --query 'systemKeys.connector_extension' -o tsv)
    key=${key%$'\r'}
    [[ -n "$key" && "$key" != null ]] || { echo 'ERROR: deploy the app first; connector_extension key unavailable.' >&2; exit 1; }
fi
temp_dir=''
owned_files=()
cleanup_callbacks() {
    local result=$? file
    trap - EXIT
    for file in ${owned_files[@]+"${owned_files[@]}"}; do
        rm -f -- "$file" || { echo 'ERROR: callback staging cleanup failed.' >&2; [[ "$result" -ne 0 ]] || result=1; }
    done
    if [[ -n "$temp_dir" ]]; then
        rmdir -- "$temp_dir" || { echo 'ERROR: callback staging directory cleanup failed.' >&2; [[ "$result" -ne 0 ]] || result=1; }
    fi
    exit "$result"
}
trap cleanup_callbacks EXIT
acquired=$(mktemp -d "$script_dir/.callback.XXXXXXXX") ||
    { echo 'ERROR: could not create callback staging directory.' >&2; exit 1; }
temp_dir=$acquired
while IFS= read -r trigger; do
    function_name=$(connector_jq -er '.functionName' <<< "$trigger")
    name="planner-$(printf '%s' "$function_name" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    if [[ "$(connector_jq -r '.enabled' <<< "$trigger")" == false ]]; then
        if connector_jq -e --arg name "$name" 'index($name) != null' <<< "$existing" > /dev/null; then
            az connector-namespace trigger update -g "$rg" --namespace "$namespace" -n "$name" --state Disabled -o none
        fi
        continue
    fi
    acquired=$(mktemp "$temp_dir/notification.XXXXXXXX") ||
        { echo 'ERROR: could not create notification staging file.' >&2; exit 1; }
    notification_file=$acquired
    owned_files+=("$notification_file")
    acquired=$(mktemp "$temp_dir/parameters.XXXXXXXX") ||
        { echo 'ERROR: could not create parameters staging file.' >&2; exit 1; }
    parameters_file=$acquired
    owned_files+=("$parameters_file")
    connector_jq -n --arg url "${callback%/}/runtime/webhooks/connector?functionName=$function_name" --arg key "$key" \
        '{callbackUrl:$url,authentication:{type:"QueryString",name:"code",value:$key}}' > "$notification_file" ||
        { echo 'ERROR: could not write notification staging file.' >&2; exit 1; }
    connector_jq '.parameters' <<< "$trigger" > "$parameters_file" ||
        { echo 'ERROR: could not write parameters staging file.' >&2; exit 1; }
    verb=create
    if connector_jq -e --arg name "$name" 'index($name) != null' <<< "$existing" > /dev/null; then
        verb=update
    fi
    metadata=$(connector_jq -nc --arg app "$app" --arg rg "$rg" --arg subscription "$subscription" \
        --arg function "$function_name" --argjson local "$local_callback" '
      {recurrenceFrequency:"Minute",recurrenceInterval:"6"} +
      (if $local then {} else {destinationType:"functionApp",functionAppName:$app,functionAppResourceGroup:$rg,
        functionAppSubscriptionId:$subscription,functionName:$function} end)')
    az connector-namespace trigger "$verb" -g "$rg" --namespace "$namespace" -n "$name" \
        --connection-details "{connectionName:$connection,connectorName:planner}" \
        --operation-name "$(connector_jq -er '.operationName' <<< "$trigger")" --parameters "@$parameters_file" \
        --notification-details "@$notification_file" --description "$(connector_jq -er '.description' <<< "$trigger")" --state Enabled \
        --metadata "$metadata" -o none 2>/dev/null ||
        { echo "ERROR: could not configure Planner trigger $name." >&2; exit 1; }
done < <(connector_jq -c '.[]' <<< "$definitions")
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
