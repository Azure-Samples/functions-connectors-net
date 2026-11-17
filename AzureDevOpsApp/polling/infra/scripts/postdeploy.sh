#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
app_dir=$(cd -- "$script_dir/../.." && pwd)
source "$script_dir/local-settings.sh"
outputs=$(azd env get-values --output json)
for name in resourceGroupName connectorNamespaceName connectorPollingEndpoint AZURE_SUBSCRIPTION_ID triggerConfigSettings triggerDefinitions; do
    connector_jq -e --arg n "$name" '.[$n] != null and .[$n] != ""' <<<"$outputs" >/dev/null || { echo "Missing azd output $name." >&2; exit 1; }
done
settings=$(connector_jq '.triggerConfigSettings | if type == "string" then fromjson else . end' <<<"$outputs")
triggers=$(connector_jq '.triggerDefinitions | if type == "string" then fromjson else . end' <<<"$outputs")
connector_jq -e 'length == 9' <<<"$triggers" >/dev/null
values=$(connector_jq -n --arg endpoint "$(connector_jq -r .connectorPollingEndpoint <<<"$outputs")" --argjson settings "$settings" --argjson triggers "$triggers" '
    reduce $triggers[] as $t ({FUNCTIONS_WORKER_RUNTIME:"dotnet-isolated", AzureWebJobsStorage:"UseDevelopmentStorage=true", ConnectorNamespace__pollingEndpoint:$endpoint};
      ($t.functionName + "TriggerConfigName") as $name |
      ("AzureWebJobs." + $t.functionName + ".Disabled") as $disabled |
      if (($settings[$name] | type) != "string" or $settings[$name] == "" or (["true","false"] | index($settings[$disabled])) == null)
      then error("Invalid trigger settings") else . + {($name):$settings[$name], ($disabled):$settings[$disabled]} end) |
    {IsEncrypted:false, Values:.}')
write_local_settings "$values"
group=$(connector_jq -r .resourceGroupName <<<"$outputs")
namespace=$(connector_jq -r .connectorNamespaceName <<<"$outputs")
subscription=$(connector_jq -r .AZURE_SUBSCRIPTION_ID <<<"$outputs")
existing=$(az connector-namespace trigger list --subscription "$subscription" -g "$group" --namespace "$namespace" --query '[].{name:name,id:id}' -o json 2>/dev/null) ||
    { echo 'Could not list existing Poll trigger configurations.' >&2; exit 1; }
while IFS= read -r name; do
    if connector_jq -e --arg n "$name" 'any(.[]; .name == $n)' <<<"$existing" >/dev/null; then
        (
            id=$(connector_jq -er --arg n "$name" --arg subscription "$subscription" --arg group "$group" --arg namespace "$namespace" '
              map(select(.name == $n)) |
              if length == 1 and (.[0].id | type) == "string" and
                (.[0].id | ascii_downcase) ==
                ("/subscriptions/"+$subscription+"/resourceGroups/"+$group+"/providers/Microsoft.Web/connectorGateways/"+$namespace+"/triggerConfigs/"+$n | ascii_downcase)
              then .[0].id else error("Invalid Poll trigger resource ID") end' <<<"$existing") ||
                { echo "Invalid resource ID for Poll trigger $name." >&2; exit 1; }
            uri="https://management.azure.com$id?api-version=2026-05-01-preview"
            temp_dir=''
            cleanup_poll_update() {
                result=$?
                trap - EXIT
                if [ -n "$temp_dir" ]; then
                    rm -f -- "$temp_dir/current.json" "$temp_dir/body.json" && rmdir -- "$temp_dir" ||
                        { echo 'Could not clean owned Poll update staging files.' >&2; [ "$result" -ne 0 ] || result=1; }
                fi
                exit "$result"
            }
            trap cleanup_poll_update EXIT
            umask 077
            acquired=$(mktemp -d "${TMPDIR:-/tmp}/azuredevops-poll-update.XXXXXXXX") ||
                { echo 'Could not create Poll update staging directory.' >&2; exit 1; }
            temp_dir=$acquired
            (set -o noclobber; : >"$temp_dir/current.json")
            current_path="$temp_dir/current.json"
            body_path="$temp_dir/body.json"
            case "${OSTYPE:-}" in
                msys*|cygwin*)
                    current_path=$(cygpath -w "$current_path")
                    body_path=$(cygpath -w "$body_path")
                    ;;
            esac
            az rest --method get --url "$uri" --output-file "$current_path" -o none 2>/dev/null ||
                { echo "Could not read Poll trigger $name." >&2; exit 1; }
            connector_jq -e '.properties.deliveryMode == "Poll"' "$temp_dir/current.json" >/dev/null ||
                { echo "Expected Poll delivery mode for trigger $name." >&2; exit 1; }
            connector_jq '{properties:(.properties | del(.provisioningState, .pollingEndpoints) | .state = "Disabled")}' \
                "$temp_dir/current.json" >"$temp_dir/body.json"
            az rest --method put --url "$uri" --body "@$body_path" --headers Content-Type=application/json -o none 2>/dev/null ||
                { echo "Could not stop trigger $name." >&2; exit 1; }
        )
    fi
done < <(connector_jq -r '.[] | select(.enabled == false) | "azuredevops-" + (.functionName | ascii_downcase)' <<<"$triggers")
echo 'Authorize the Azure DevOps connection separately using a supported authentication type. No consent is performed by this hook.'
