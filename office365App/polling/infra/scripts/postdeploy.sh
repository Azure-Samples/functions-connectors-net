#!/usr/bin/env bash
set -euo pipefail

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
  jq -e --arg name "$name" '.[$name] | . != null and . != ""' <<<"$outputs" >/dev/null ||
    { echo "Missing azd output $name. Run azd provision first." >&2; exit 1; }
done
resource_group=$(jq -r '.resourceGroupName' <<<"$outputs")
namespace=$(jq -r '.connectorNamespaceName' <<<"$outputs")
connection=$(jq -r '.connectorNamespaceConnectionName' <<<"$outputs")
trigger_settings=$(jq -ce '.triggerConfigSettings | if type == "string" then fromjson else . end' <<<"$outputs")
functions=(OnNewEmail OnFlaggedEmail OnNewMentionMeEmail OnNewCalendarEvent OnUpcomingEvent OnCalendarUpdatedItems OnSharedMailboxNewEmail)
for function_name in "${functions[@]}"; do
  setting="${function_name}TriggerConfigName"
  jq -e --arg name "$setting" '.[$name] | type == "string" and length > 0' <<<"$trigger_settings" >/dev/null ||
    { echo "Missing trigger configuration setting $setting." >&2; exit 1; }
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
local_settings="$script_dir/../../local.settings.json"
if [[ -f "$local_settings" && "$force_local_settings" == false ]]; then
  echo 'Existing local.settings.json preserved. Use --force-local-settings to regenerate it.'
else
  umask 077
  settings_temp=""
  cleanup() {
    if [[ -n "$settings_temp" ]]; then rm -f -- "$settings_temp"; fi
  }
  trap cleanup EXIT
  settings_temp=$(mktemp "$script_dir/../../.local-settings.XXXXXX") ||
    { echo 'Could not create a temporary local settings file.' >&2; exit 1; }
  jq -n --argjson outputs "$outputs" --argjson settings "$trigger_settings" '{
    IsEncrypted: false,
    Values: ({
      AzureWebJobsStorage: "UseDevelopmentStorage=true",
      FUNCTIONS_WORKER_RUNTIME: "dotnet-isolated",
      ConnectorNamespace__pollingEndpoint: $outputs.connectorPollingEndpoint,
      "AzureWebJobs.OnSharedMailboxNewEmail.Disabled":
        ((($outputs.office365SharedMailboxAddress // "") | length) == 0 | tostring)
    } + $settings)
  }' >"$settings_temp" ||
    { echo 'Could not generate local.settings.json; existing settings were preserved.' >&2; exit 1; }
  jq -e '.IsEncrypted == false and (.Values | type == "object") and
    all(.Values[]; type == "string")' "$settings_temp" >/dev/null ||
    { echo 'Generated local settings are invalid; existing settings were preserved.' >&2; exit 1; }
  [[ ! -d "$local_settings" ]] && mv -f -- "$settings_temp" "$local_settings" ||
    { echo 'Could not replace local.settings.json; existing settings were preserved.' >&2; exit 1; }
  settings_temp=""
  echo 'Created ignored local.settings.json using developer credentials and Azurite.'
fi

connection_status() {
  az connector-namespace connection show -g "$resource_group" --namespace "$namespace" \
    -n "$connection" --query properties.overallStatus -o tsv
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
  if [[ -z "$consent_link" || "$consent_link" == null ]]; then
    consent_link=$(az connector-namespace connection list-consent-links \
      -g "$resource_group" --namespace "$namespace" --connection-name "$connection" \
      --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" \
      --query link -o tsv 2>/dev/null) || consent_link=""
  fi
  [[ -n "$consent_link" && "$consent_link" != null ]] && break
  if (( attempt < 5 )); then sleep 5; fi
done
[[ -n "$consent_link" && "$consent_link" != null ]] ||
  { echo 'Could not obtain an Office 365 consent link.' >&2; exit 1; }
echo "Consent URL: $consent_link"
if [[ "$consent_link_only" == true || "$(jq -r '.office365TriggerState // ""' <<<"$outputs")" == Disabled ]]; then
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
