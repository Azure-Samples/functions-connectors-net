#!/usr/bin/env bash
set -euo pipefail

callback_base_url=""
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
command -v jq >/dev/null || { echo 'jq is required for Bash setup.' >&2; exit 1; }
az extension show --name connector-namespace --query name -o tsv >/dev/null ||
  { echo 'Install the connector-namespace Azure CLI extension.' >&2; exit 1; }
outputs=$(azd env get-values --output json)
required=(resourceGroupName connectorNamespaceName connectorNamespaceConnectionName functionAppName
  functionAppDefaultHostname AZURE_SUBSCRIPTION_ID office365MailFolder office365CalendarId office365TriggerState)
for name in "${required[@]}"; do
  jq -e --arg name "$name" '.[$name] | . != null and . != ""' <<<"$outputs" >/dev/null ||
    { echo "Missing azd output $name. Run azd provision first." >&2; exit 1; }
done
resource_group=$(jq -r '.resourceGroupName' <<<"$outputs")
namespace=$(jq -r '.connectorNamespaceName' <<<"$outputs")
connection=$(jq -r '.connectorNamespaceConnectionName' <<<"$outputs")
function_app=$(jq -r '.functionAppName' <<<"$outputs")
subscription=$(jq -r '.AZURE_SUBSCRIPTION_ID' <<<"$outputs")
trigger_state=$(jq -r '.office365TriggerState' <<<"$outputs")
mail_folder=$(jq -r '.office365MailFolder' <<<"$outputs")
calendar_id=$(jq -r '.office365CalendarId' <<<"$outputs")
shared_mailbox=$(jq -r '.office365SharedMailboxAddress // ""' <<<"$outputs")
umask 077
settings_temp=""
notification_file=""
parameters_file=""
cleanup() {
  if [[ -n "$settings_temp" ]]; then rm -f -- "$settings_temp"; fi
  if [[ -n "$notification_file" ]]; then rm -f -- "$notification_file"; fi
  if [[ -n "$parameters_file" ]]; then rm -f -- "$parameters_file"; fi
}
trap cleanup EXIT
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
local_settings="$script_dir/../../local.settings.json"
if [[ -e "$local_settings" || -L "$local_settings" ]]; then
  [[ -f "$local_settings" ]] ||
    { echo 'local.settings.json must be a regular file, not a directory.' >&2; exit 1; }
  echo 'Existing local.settings.json preserved.'
else
  settings_temp=$(mktemp "$script_dir/../../.local-settings.XXXXXX") ||
    { echo 'Could not create a temporary local settings file.' >&2; exit 1; }
  jq -n --arg address "$shared_mailbox" '{
    IsEncrypted: false,
    Values: {
      AzureWebJobsStorage: "UseDevelopmentStorage=true",
      FUNCTIONS_WORKER_RUNTIME: "dotnet-isolated",
      "AzureWebJobs.OnSharedMailboxNewEmail.Disabled": ($address == "" | tostring)
    }
  }' >"$settings_temp" ||
    { echo 'Could not generate local.settings.json.' >&2; exit 1; }
  jq -e '.IsEncrypted == false and (.Values | type == "object") and
    all(.Values[]; type == "string")' "$settings_temp" >/dev/null ||
    { echo 'Generated local settings are invalid.' >&2; exit 1; }
  [[ ! -e "$local_settings" && ! -L "$local_settings" ]] &&
    mv -n -- "$settings_temp" "$local_settings" && [[ ! -e "$settings_temp" ]] ||
    { echo 'Could not create local.settings.json.' >&2; exit 1; }
  settings_temp=""
  echo 'Created ignored local.settings.json for Azurite.'
fi
if [[ -z "$callback_base_url" ]]; then
  connector_extension_key=$(az functionapp keys list -g "$resource_group" -n "$function_app" \
    --query systemKeys.connector_extension -o tsv)
  [[ -n "$connector_extension_key" && "$connector_extension_key" != null ]] ||
    { echo 'Could not retrieve connector_extension system key. Deploy the function first.' >&2; exit 1; }
  callback_base_url="https://$(jq -r '.functionAppDefaultHostname' <<<"$outputs")"
fi
callback_base_url="${callback_base_url%/}"

create_trigger() {
  local function_name=$1 operation=$2 description=$3 parameters=$4
  notification_file=$(mktemp)
  parameters_file=$(mktemp)
  jq -n --arg url "$callback_base_url/runtime/webhooks/connector?functionName=$function_name" \
    --arg key "$connector_extension_key" \
    '{callbackUrl:$url,authentication:{type:"QueryString",name:"code",value:$key}}' >"$notification_file"
  printf '%s' "$parameters" >"$parameters_file"
  echo "Creating trigger: $function_name -> $operation"
  az connector-namespace trigger create -g "$resource_group" --namespace "$namespace" \
    -n "$connection-$(printf '%s' "$function_name" | tr '[:upper:]' '[:lower:]')" \
    --connection-details "{connectionName:$connection,connectorName:office365}" \
    --operation-name "$operation" --state "$trigger_state" \
    --parameters "@$parameters_file" --notification-details "@$notification_file" \
    --description "$description" \
    --metadata "{destinationType:functionApp,functionAppName:$function_app,functionAppResourceGroup:$resource_group,functionAppSubscriptionId:$subscription,functionName:$function_name,recurrenceFrequency:Minute,recurrenceInterval:'5'}" \
    -o none
  cleanup
  notification_file=""
  parameters_file=""
}
mail_parameters=$(jq -nc --arg folder "$mail_folder" '[{name:"folderPath",value:$folder}]')
calendar_parameters=$(jq -nc --arg id "$calendar_id" '[{name:"table",value:$id}]')
create_trigger OnNewEmail OnNewEmailV3 'When a new email arrives' "$mail_parameters"
create_trigger OnFlaggedEmail OnFlaggedEmailV4 'When an email is flagged' "$mail_parameters"
create_trigger OnNewMentionMeEmail OnNewMentionMeEmailV3 'When a new email mentioning me arrives' "$mail_parameters"
create_trigger OnNewCalendarEvent CalendarGetOnNewItemsV3 'When a new calendar event is created' "$calendar_parameters"
create_trigger OnUpcomingEvent OnUpcomingEventsV3 'When an upcoming event is starting soon' "$calendar_parameters"
create_trigger OnCalendarUpdatedItems CalendarGetOnUpdatedItemsV3 'When an event is modified (V3)' "$calendar_parameters"
if [[ -n "$shared_mailbox" ]]; then
  shared_parameters=$(jq -nc --arg address "$shared_mailbox" \
    --arg folder "$(jq -r '.office365SharedMailboxFolderId // ""' <<<"$outputs")" \
    '[{name:"mailboxAddress",value:$address},{name:"folderId",value:$folder}]')
  create_trigger OnSharedMailboxNewEmail SharedMailboxOnNewEmailV2 'When a new email arrives in a shared mailbox (V2)' "$shared_parameters"
else
  echo 'Shared mailbox trigger is disabled. Set OFFICE365_SHARED_MAILBOX_ADDRESS and re-run azd up to enable it.'
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
