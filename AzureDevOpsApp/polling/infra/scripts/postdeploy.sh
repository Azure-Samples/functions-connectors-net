#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
app_dir=$(cd -- "$script_dir/../.." && pwd)
source "$script_dir/local-settings.sh"
outputs=$(azd env get-values --output json)
for name in resourceGroupName connectorNamespaceName connectorPollingEndpoint triggerConfigSettings triggerDefinitions; do
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
existing=$(az connector-namespace trigger list -g "$group" --namespace "$namespace" --query '[].name' -o json 2>/dev/null) ||
    { echo 'Could not list existing Poll trigger configurations.' >&2; exit 1; }
while IFS= read -r name; do
    if connector_jq -e --arg n "$name" 'index($n) != null' <<<"$existing" >/dev/null; then
        az connector-namespace trigger update -g "$group" --namespace "$namespace" -n "$name" --state Disabled -o none 2>/dev/null ||
            { echo "Could not stop trigger $name." >&2; exit 1; }
    fi
done < <(connector_jq -r '.[] | select(.enabled == false) | "azuredevops-" + (.functionName | ascii_downcase)' <<<"$triggers")
echo 'Authorize the Azure DevOps connection separately using a supported authentication type. No consent is performed by this hook.'
