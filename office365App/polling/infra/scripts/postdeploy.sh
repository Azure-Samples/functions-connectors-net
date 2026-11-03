#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$script_dir/../.." && pwd)"
source "$script_dir/local-settings.sh"

force_local_settings=false
consent_link_only=false
for option in "$@"; do
  case "$option" in
    --force-local-settings) force_local_settings=true ;;
    --consent-link-only) consent_link_only=true ;;
    *) echo "Unknown option: $option" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null || { echo 'jq is required for Bash setup.' >&2; exit 1; }
az extension show --name connector-namespace --query name -o tsv >/dev/null ||
  { echo 'Install the connector-namespace Azure CLI extension.' >&2; exit 1; }
outputs=$(azd env get-values --output json)
required=(resourceGroupName connectorNamespaceName connectorNamespaceConnectionName connectorPollingEndpoint triggerConfigSettings)
for name in "${required[@]}"; do
  connector_jq -e --arg name "$name" '.[$name] | . != null and . != ""' <<<"$outputs" >/dev/null ||
    { echo "Missing azd output $name. Run azd provision first." >&2; exit 1; }
done
resource_group=$(connector_jq -r '.resourceGroupName' <<<"$outputs")
namespace=$(connector_jq -r '.connectorNamespaceName' <<<"$outputs")
connection=$(connector_jq -r '.connectorNamespaceConnectionName' <<<"$outputs")
trigger_settings=$(connector_jq -ce '.triggerConfigSettings | if type == "string" then fromjson else . end' <<<"$outputs")
functions=(OnNewEmail OnFlaggedEmail OnNewMentionMeEmail OnNewCalendarEvent OnUpcomingEvent OnCalendarUpdatedItems OnSharedMailboxNewEmail)
for function_name in "${functions[@]}"; do
  setting="${function_name}TriggerConfigName"
  connector_jq -e --arg name "$setting" '.[$name] | type == "string" and length > 0' <<<"$trigger_settings" >/dev/null ||
    { echo "Missing trigger configuration setting $setting." >&2; exit 1; }
done

local_settings_json=$(connector_jq -n --argjson outputs "$outputs" --argjson settings "$trigger_settings" '{
    IsEncrypted: false,
    Values: ({
      AzureWebJobsStorage: "UseDevelopmentStorage=true",
      FUNCTIONS_WORKER_RUNTIME: "dotnet-isolated",
      ConnectorNamespace__pollingEndpoint: $outputs.connectorPollingEndpoint,
      "AzureWebJobs.OnSharedMailboxNewEmail.Disabled":
        ((($outputs.office365SharedMailboxAddress // "") | length) == 0 | tostring)
    } + $settings)
  }')
write_local_settings "$local_settings_json" "$force_local_settings"

connection_status() {
  local cli_status
  cli_status=$(az connector-namespace connection show -g "$resource_group" --namespace "$namespace" \
    -n "$connection" --query properties.overallStatus -o tsv) || return
  printf '%s\n' "${cli_status%$'\r'}"
}
status=$(connection_status)
if [[ "$status" == Connected ]]; then
  echo 'Office 365 connection is already authorized.'
  exit 0
fi
consent_link=""
for attempt in 1 2 3 4 5; do
  consent_link=$(az connector-namespace connection list-consent-links \
    -g "$resource_group" --namespace "$namespace" --connection-name "$connection" \
    --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" \
    --query 'value[0].link' -o tsv 2>/dev/null) || consent_link=""
  consent_link="${consent_link%$'\r'}"
  if [[ -z "$consent_link" || "$consent_link" == null ]]; then
    consent_link=$(az connector-namespace connection list-consent-links \
      -g "$resource_group" --namespace "$namespace" --connection-name "$connection" \
      --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" \
      --query link -o tsv 2>/dev/null) || consent_link=""
    consent_link="${consent_link%$'\r'}"
  fi
  [[ -n "$consent_link" && "$consent_link" != null ]] && break
  if (( attempt < 5 )); then sleep 5; fi
done
[[ -n "$consent_link" && "$consent_link" != null ]] ||
  { echo 'Could not obtain an Office 365 consent link.' >&2; exit 1; }
echo "Consent URL: $consent_link"
if [[ "$consent_link_only" == true || "$(connector_jq -r '.office365TriggerState // ""' <<<"$outputs")" == Disabled ]]; then
  exit 0
fi
if command -v xdg-open >/dev/null; then
  xdg-open "$consent_link" >/dev/null 2>&1 || echo 'Open the consent URL in your browser.'
elif command -v open >/dev/null; then
  open "$consent_link" >/dev/null 2>&1 || echo 'Open the consent URL in your browser.'
else
  echo 'Open the consent URL in your browser.'
fi
deadline=$((SECONDS + 300))
while (( SECONDS < deadline )); do
  sleep 3
  status=$(connection_status)
  if [[ "$status" == Connected ]]; then
    echo 'Office 365 connection authorized. Poll configurations are provisioned (shared mailbox is opt-in).'
    exit 0
  fi
done
echo 'Timed out waiting for the Office 365 connection to become Connected.' >&2
exit 1
