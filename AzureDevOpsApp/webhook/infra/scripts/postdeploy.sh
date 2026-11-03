#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
app_dir=$(cd -- "$script_dir/../.." && pwd)
source "$script_dir/local-settings.sh"
callback=${1:-}
key=${2:-}
local_callback=false
if [ -n "$callback" ]; then local_callback=true; fi
if [[ (-n "$callback" && ("$callback" != https://* || -z "$key")) || (-n "$key" && -z "$callback") ]]; then
    echo 'Local callbacks require both a public HTTPS callback base and local connector extension key.' >&2
    exit 1
fi
outputs=$(azd env get-values --output json)
for name in resourceGroupName connectorNamespaceName connectorNamespaceConnectionName functionAppName AZURE_SUBSCRIPTION_ID triggerConfigSettings triggerDefinitions; do
    connector_jq -e --arg n "$name" '.[$n] != null and .[$n] != ""' <<<"$outputs" >/dev/null || { echo "Missing azd output $name." >&2; exit 1; }
done
settings=$(connector_jq '.triggerConfigSettings | if type == "string" then fromjson else . end' <<<"$outputs")
triggers=$(connector_jq '.triggerDefinitions | if type == "string" then fromjson else . end' <<<"$outputs")
connector_jq -e 'length == 9' <<<"$triggers" >/dev/null
values=$(connector_jq -n --argjson settings "$settings" --argjson triggers "$triggers" '
    reduce $triggers[] as $t ({FUNCTIONS_WORKER_RUNTIME:"dotnet-isolated", AzureWebJobsStorage:"UseDevelopmentStorage=true"};
      ("AzureWebJobs." + $t.functionName + ".Disabled") as $disabled |
      if (["true","false"] | index($settings[$disabled])) == null then error("Invalid disabled setting")
      else . + {($disabled):$settings[$disabled]} end) | {IsEncrypted:false, Values:.}')
write_local_settings "$values"
group=$(connector_jq -r .resourceGroupName <<<"$outputs")
namespace=$(connector_jq -r .connectorNamespaceName <<<"$outputs")
connection=$(connector_jq -r .connectorNamespaceConnectionName <<<"$outputs")
app=$(connector_jq -r .functionAppName <<<"$outputs")
subscription=$(connector_jq -r .AZURE_SUBSCRIPTION_ID <<<"$outputs")
existing=$(az connector-namespace trigger list -g "$group" --namespace "$namespace" --query '[].name' -o json 2>/dev/null) ||
    { echo 'Could not list existing Webhook trigger configurations.' >&2; exit 1; }
if [ -z "$callback" ]; then
    hostname=$(connector_jq -er '.functionAppDefaultHostname | select(type == "string" and length > 0)' <<<"$outputs")
    key=$(az functionapp keys list -g "$group" -n "$app" --query systemKeys.connector_extension -o tsv 2>/dev/null) ||
        { echo 'Could not read connector_extension system key.' >&2; exit 1; }
    key=${key%$'\r'}
    [[ -n "$key" && "$key" != null ]] || { echo 'Missing connector_extension system key. Deploy the app first.' >&2; exit 1; }
    callback="https://$hostname"
fi
temp_dir=''
cleanup_callback() {
    result=$?
    trap - EXIT
    if [ -n "$temp_dir" ]; then
        rm -f -- "$temp_dir/notification.json" "$temp_dir/parameters.json" &&
            rmdir -- "$temp_dir" ||
            { echo 'Could not clean owned callback staging files.' >&2; [ "$result" -ne 0 ] || result=1; }
    fi
    exit "$result"
}
trap cleanup_callback EXIT
acquired_dir=$(mktemp -d "${TMPDIR:-/tmp}/azuredevops-callback.XXXXXXXX") ||
    { echo 'Could not create callback staging directory.' >&2; exit 1; }
temp_dir=$acquired_dir
while IFS= read -r trigger; do
    function=$(connector_jq -r .functionName <<<"$trigger")
    name=$(connector_jq -r '"azuredevops-" + (.functionName | ascii_downcase)' <<<"$trigger")
    if [ "$(connector_jq -r .enabled <<<"$trigger")" != true ]; then
        if connector_jq -e --arg n "$name" 'index($n) != null' <<<"$existing" >/dev/null; then
            az connector-namespace trigger update -g "$group" --namespace "$namespace" -n "$name" --state Disabled -o none 2>/dev/null ||
                { echo "Could not stop trigger $name." >&2; exit 1; }
        fi
        continue
    fi
    connector_jq -n --arg url "${callback%/}/runtime/webhooks/connector?functionName=$function" --arg key "$key" '
      {callbackUrl:$url, authentication:{type:"QueryString", name:"code", value:$key}}' > "$temp_dir/notification.json"
    connector_jq '.parameters' <<<"$trigger" > "$temp_dir/parameters.json"
    verb=create
    if connector_jq -e --arg n "$name" 'index($n) != null' <<<"$existing" >/dev/null; then verb=update; fi
    metadata=$(connector_jq -n --arg app "$app" --arg group "$group" --arg subscription "$subscription" \
        --arg function "$function" --argjson local "$local_callback" '
      {recurrenceFrequency:"Minute",recurrenceInterval:"5"} +
      (if $local then {} else {destinationType:"functionApp",functionAppName:$app,
       functionAppResourceGroup:$group,functionAppSubscriptionId:$subscription,functionName:$function} end)')
    az connector-namespace trigger "$verb" -g "$group" --namespace "$namespace" -n "$name" \
        --connection-details "{connectionName:$connection,connectorName:visualstudioteamservices}" \
        --operation-name "$(connector_jq -r .operationName <<<"$trigger")" --parameters "@$temp_dir/parameters.json" \
        --notification-details "@$temp_dir/notification.json" --state Enabled \
        --metadata "$metadata" -o none 2>/dev/null ||
        { echo "Could not configure Webhook trigger $name." >&2; exit 1; }
done < <(connector_jq -c '.[]' <<<"$triggers")
echo 'Webhook callbacks configured. Authorize the Azure DevOps connection separately; this hook does not perform consent.'
