#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$script_dir/../.." && pwd)"
source "$script_dir/local-settings.sh"

callback_base_url=""
local_callback=false
connector_extension_key=""
consent_link_only=false
while (( $# )); do
  case "$1" in
    --callback-base-url|--connector-extension-key)
      (( $# >= 2 )) || { echo "Missing value for $1" >&2; exit 1; }
      if [[ "$1" == --callback-base-url ]]; then callback_base_url=$2; else connector_extension_key=$2; fi
      shift 2 ;;
    --consent-link-only) consent_link_only=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
if [[ -n "$callback_base_url" && ( "$(printf '%s' "$callback_base_url" | tr '[:upper:]' '[:lower:]')" != https://* || -z "$connector_extension_key" ) ]]; then
  echo 'Local callbacks require public HTTPS --callback-base-url and --connector-extension-key.' >&2
  exit 1
fi
if [[ -n "$connector_extension_key" && -z "$callback_base_url" ]]; then
  echo '--callback-base-url is required with --connector-extension-key.' >&2
  exit 1
fi
if [[ -n "$callback_base_url" ]]; then local_callback=true; fi
command -v jq >/dev/null || { echo 'jq is required for Bash setup.' >&2; exit 1; }
az extension show --name connector-namespace --query name -o tsv >/dev/null ||
  { echo 'Install the connector-namespace Azure CLI extension.' >&2; exit 1; }
outputs=$(azd env get-values --output json)
required=(resourceGroupName connectorNamespaceName connectorNamespaceConnectionName functionAppName
  functionAppDefaultHostname AZURE_SUBSCRIPTION_ID office365MailFolder office365CalendarId office365TriggerState)
for name in "${required[@]}"; do
  connector_jq -e --arg name "$name" '.[$name] | . != null and . != ""' <<<"$outputs" >/dev/null ||
    { echo "Missing azd output $name. Run azd provision first." >&2; exit 1; }
done
resource_group=$(connector_jq -r '.resourceGroupName' <<<"$outputs")
namespace=$(connector_jq -r '.connectorNamespaceName' <<<"$outputs")
connection=$(connector_jq -r '.connectorNamespaceConnectionName' <<<"$outputs")
function_app=$(connector_jq -r '.functionAppName' <<<"$outputs")
subscription=$(connector_jq -r '.AZURE_SUBSCRIPTION_ID' <<<"$outputs")
trigger_state=$(connector_jq -r '.office365TriggerState' <<<"$outputs")
mail_folder=$(connector_jq -r '.office365MailFolder' <<<"$outputs")
calendar_id=$(connector_jq -r '.office365CalendarId' <<<"$outputs")
shared_mailbox=$(connector_jq -r '.office365SharedMailboxAddress // ""' <<<"$outputs")
settings_json=$(connector_jq -n --arg address "$shared_mailbox" '{
    IsEncrypted: false,
    Values: {
      AzureWebJobsStorage: "UseDevelopmentStorage=true",
      FUNCTIONS_WORKER_RUNTIME: "dotnet-isolated",
      "AzureWebJobs.OnSharedMailboxNewEmail.Disabled": ($address == "" | tostring)
    }
  }')
write_local_settings "$settings_json"
mail_parameters=$(connector_jq -nc --arg folder "$mail_folder" '[{name:"folderPath",value:$folder}]')
calendar_parameters=$(connector_jq -nc --arg id "$calendar_id" '[{name:"table",value:$id}]')
existing_names=$(az connector-namespace trigger list -g "$resource_group" --namespace "$namespace" --query '[].name' -o json)
if [[ -z "$callback_base_url" ]]; then
  connector_extension_key=$(az functionapp keys list -g "$resource_group" -n "$function_app" \
    --query systemKeys.connector_extension -o tsv)
  connector_extension_key="${connector_extension_key%$'\r'}"
  [[ -n "$connector_extension_key" && "$connector_extension_key" != null ]] ||
    { echo 'Could not retrieve connector_extension system key. Deploy the function first.' >&2; exit 1; }
  callback_base_url="https://$(connector_jq -r '.functionAppDefaultHostname' <<<"$outputs")"
fi
callback_base_url="${callback_base_url%/}"

umask 077
temp_dir=''
cleanup_callback() {
  result=$?
  trap - EXIT
  if [[ -n "$temp_dir" ]]; then
    cleanup_failed=false
    rm -f -- "$temp_dir/notification.json" || cleanup_failed=true
    rm -f -- "$temp_dir/parameters.json" || cleanup_failed=true
    rmdir -- "$temp_dir" || cleanup_failed=true
    if [[ "$cleanup_failed" == true ]]; then
      echo 'Could not clean owned callback staging files.' >&2
      [[ "$result" -ne 0 ]] || result=1
    fi
  fi
  exit "$result"
}
trap cleanup_callback EXIT
candidate_dir=$(mktemp -d "${TMPDIR:-/tmp}/office365-callback.XXXXXXXX") ||
  { echo 'Could not create callback staging directory.' >&2; exit 1; }
temp_dir="$candidate_dir"
create_trigger() {
  local function_name=$1 operation=$2 description=$3 parameters=$4
  local notification_file="$temp_dir/notification.json" parameters_file="$temp_dir/parameters.json" verb=create metadata
  connector_jq -n --arg url "$callback_base_url/runtime/webhooks/connector?functionName=$function_name" \
    --arg key "$connector_extension_key" \
    '{callbackUrl:$url,authentication:{type:"QueryString",name:"code",value:$key}}' >"$notification_file"
  printf '%s' "$parameters" >"$parameters_file"
  echo "Creating trigger: $function_name -> $operation"
  if connector_jq -e --arg name "$connection-$(printf '%s' "$function_name" | tr '[:upper:]' '[:lower:]')" 'index($name) != null' <<<"$existing_names" >/dev/null; then verb=update; fi
  metadata="recurrenceFrequency:Minute,recurrenceInterval:'5'"
  if [[ "$local_callback" == false ]]; then metadata="$metadata,destinationType:functionApp,functionAppName:$function_app,functionAppResourceGroup:$resource_group,functionAppSubscriptionId:$subscription,functionName:$function_name"; fi
  az connector-namespace trigger "$verb" -g "$resource_group" --namespace "$namespace" \
    -n "$connection-$(printf '%s' "$function_name" | tr '[:upper:]' '[:lower:]')" \
    --connection-details "{connectionName:$connection,connectorName:office365}" \
    --operation-name "$operation" --state "$trigger_state" \
    --parameters "@$parameters_file" --notification-details "@$notification_file" \
    --description "$description" \
    --metadata "{$metadata}" \
    -o none 2>/dev/null || { echo "Could not configure trigger $function_name." >&2; return 1; }
}
create_trigger OnNewEmail OnNewEmailV3 'When a new email arrives' "$mail_parameters"
create_trigger OnFlaggedEmail OnFlaggedEmailV4 'When an email is flagged' "$mail_parameters"
create_trigger OnNewMentionMeEmail OnNewMentionMeEmailV3 'When a new email mentioning me arrives' "$mail_parameters"
create_trigger OnNewCalendarEvent CalendarGetOnNewItemsV3 'When a new calendar event is created' "$calendar_parameters"
create_trigger OnUpcomingEvent OnUpcomingEventsV3 'When an upcoming event is starting soon' "$calendar_parameters"
create_trigger OnCalendarUpdatedItems CalendarGetOnUpdatedItemsV3 'When an event is modified (V3)' "$calendar_parameters"
if [[ -n "$shared_mailbox" ]]; then
  shared_parameters=$(connector_jq -nc --arg address "$shared_mailbox" \
    --arg folder "$(connector_jq -r '.office365SharedMailboxFolderId // ""' <<<"$outputs")" \
    '[{name:"mailboxAddress",value:$address},{name:"folderId",value:$folder}]')
  create_trigger OnSharedMailboxNewEmail SharedMailboxOnNewEmailV2 'When a new email arrives in a shared mailbox (V2)' "$shared_parameters"
else
  echo 'Shared mailbox trigger is disabled. Set OFFICE365_SHARED_MAILBOX_ADDRESS and re-run azd up to enable it.'
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
if [[ "$consent_link_only" == true || "$trigger_state" == Disabled ]]; then exit 0; fi
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
    echo 'Office 365 connection authorized. Triggers are configured (shared mailbox is opt-in).'
    exit 0
  fi
done
echo 'Timed out waiting for the Office 365 connection to become Connected.' >&2
exit 1
