#!/usr/bin/env bash
set -euo pipefail
umask 077
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
        (($outputs.office365SharedMailboxAddress // "" | test("\\S") | not) | tostring)
    } + $settings)
  }')
write_local_settings "$local_settings_json" "$force_local_settings"

if ! connector_jq -e '.office365SharedMailboxAddress // "" | test("\\S")' <<<"$outputs" >/dev/null; then
  trigger_name=$(connector_jq -r '.OnSharedMailboxNewEmailTriggerConfigName' <<<"$trigger_settings")
  existing_configs=$(az connector-namespace trigger list \
    -g "$resource_group" --namespace "$namespace" --query '[].{name:name,id:id}' -o json)
  trigger_id=$(connector_jq -r --arg name "$trigger_name" '.[] | select(.name == $name) | .id' <<<"$existing_configs")
  if [[ -n "$trigger_id" ]]; then
    [[ "$(printf '%s' "$trigger_id" | tr '[:upper:]' '[:lower:]')" == /subscriptions/*/triggerconfigs/"$trigger_name" ]] ||
      { echo "Invalid resource ID for trigger $trigger_name." >&2; exit 1; }
    (
      body_file=''
      read_file=''
      cleanup_update() {
        result=$?
        trap - EXIT
        if [[ -n "$read_file" ]]; then
          rm -f -- "$read_file" ||
            { echo 'Could not clean owned trigger-read staging file.' >&2; [[ "$result" -ne 0 ]] || result=1; }
        fi
        if [[ -n "$body_file" ]]; then
          rm -f -- "$body_file" ||
            { echo 'Could not clean owned trigger-update staging file.' >&2; [[ "$result" -ne 0 ]] || result=1; }
        fi
        exit "$result"
      }
      trap cleanup_update EXIT
      url="https://management.azure.com${trigger_id}?api-version=2026-05-01-preview"
      acquired=$(mktemp "$script_dir/.trigger-read.XXXXXXXX") ||
        { echo 'Could not create trigger-read staging file.' >&2; exit 1; }
      read_file="$acquired"
      read_path="$read_file"
      if command -v cygpath >/dev/null 2>&1; then read_path=$(cygpath -w "$read_file"); fi
      az rest --method get --url "$url" --output-file "$read_path" -o none ||
        { echo "Could not read trigger $trigger_name." >&2; exit 1; }
      body=$(connector_jq -ce '
        if .properties.deliveryMode != "Poll" then error("Expected Poll delivery mode")
        else {properties: (.properties | del(.provisioningState, .pollingEndpoints) | .state = "Disabled")}
        end' "$read_file")
      acquired=$(mktemp "$script_dir/.trigger-update.XXXXXXXX") ||
        { echo 'Could not create trigger-update staging file.' >&2; exit 1; }
      body_file="$acquired"
      printf '%s\n' "$body" >"$body_file" ||
        { echo 'Could not write trigger-update staging file.' >&2; exit 1; }
      az rest --method put --url "$url" --body "@$body_file" -o none ||
        { echo "Could not disable trigger $trigger_name." >&2; exit 1; }
    )
  fi
fi

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
