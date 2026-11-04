#!/bin/bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/local-settings.sh"

forceLocalSettings=false
if [[ $# -gt 0 ]]; then
  if [[ $# -ne 1 || "$1" != "--force-local-settings" ]]; then
    echo "Usage: bash postdeploy.sh [--force-local-settings]" >&2
    exit 1
  fi
  forceLocalSettings=true
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for this script. Please install jq." >&2
  exit 1
fi
if ! az extension show --name connector-namespace --query name -o tsv >/dev/null 2>&1; then
  echo "ERROR: Install the connector-namespace Azure CLI extension before running this script." >&2
  exit 1
fi

outputs=$(azd env get-values --output json)
for name in resourceGroupName connectorNamespaceName connectorNamespaceConnectionName connectorPollingEndpoint; do
  if ! echo "$outputs" | connector_jq -e --arg name "$name" '.[$name] | type == "string" and test("\\S")' >/dev/null; then
    echo "ERROR: Missing azd output ${name}. Run azd provision first." >&2
    exit 1
  fi
done

resourceGroupName=$(echo "$outputs" | connector_jq -r '.resourceGroupName')
connectorNamespaceName=$(echo "$outputs" | connector_jq -r '.connectorNamespaceName')
connectorNamespaceConnectionName=$(echo "$outputs" | connector_jq -r '.connectorNamespaceConnectionName')
pollingEndpoint=$(echo "$outputs" | connector_jq -r '.connectorPollingEndpoint')
triggerSettings=$(echo "$outputs" | connector_jq -ce '.triggerConfigSettings | if type == "string" then fromjson else . end | select(type == "object")')
triggerDefinitions=$(echo "$outputs" | connector_jq -ce '.triggerDefinitions | if type == "string" then fromjson else . end | select(type == "array" and length == 10)')

localSettings=$(connector_jq -n --arg endpoint "$pollingEndpoint" --argjson settings "$triggerSettings" \
  --slurpfile manifest "${SCRIPT_DIR}/../triggers.json" '
  {
    IsEncrypted: false,
    Values: (reduce $manifest[0][] as $trigger (
      {
        AzureWebJobsStorage: "UseDevelopmentStorage=true",
        FUNCTIONS_WORKER_RUNTIME: "dotnet-isolated",
        ConnectorNamespace__pollingEndpoint: $endpoint
      };
      ($trigger.functionName + "TriggerConfigName") as $config |
      ("AzureWebJobs." + $trigger.functionName + ".Disabled") as $disabled |
      if ($settings[$config] | type) != "string" or ($settings[$config] | test("\\S") | not) then
        error("Missing trigger configuration setting " + $config)
      elif ($settings[$disabled] | type) != "string" then
        error("Missing or invalid function setting " + $disabled)
      elif (($settings[$disabled] | ascii_downcase) != "true" and ($settings[$disabled] | ascii_downcase) != "false") then
        error("Missing or invalid function setting " + $disabled)
      else
        . + {($config): $settings[$config], ($disabled): $settings[$disabled]}
      end
    ))
  }')

write_local_settings "$localSettings" "$forceLocalSettings"
existingConfigs=$(az connector-namespace trigger list \
  -g "$resourceGroupName" --namespace "$connectorNamespaceName" --query '[].{name:name,id:id}' -o json)
while IFS= read -r functionName; do
  triggerName="sharepoint-$(echo "$functionName" | tr '[:upper:]' '[:lower:]')"
  triggerId=$(connector_jq -r --arg name "$triggerName" '.[] | select(.name == $name) | .id' <<<"$existingConfigs")
  if [[ -n "$triggerId" ]]; then
    [[ "$(printf '%s' "$triggerId" | tr '[:upper:]' '[:lower:]')" == /subscriptions/*/triggerconfigs/"$triggerName" ]] ||
      { echo "Invalid resource ID for trigger $triggerName." >&2; exit 1; }
    (
      bodyFile=''
      readFile=''
      cleanup_update() {
        result=$?
        trap - EXIT
        if [[ -n "$readFile" ]]; then
          rm -f -- "$readFile" ||
            { echo 'Could not clean owned trigger-read staging file.' >&2; [[ "$result" -ne 0 ]] || result=1; }
        fi
        if [[ -n "$bodyFile" ]]; then
          rm -f -- "$bodyFile" ||
            { echo 'Could not clean owned trigger-update staging file.' >&2; [[ "$result" -ne 0 ]] || result=1; }
        fi
        exit "$result"
      }
      trap cleanup_update EXIT
      url="https://management.azure.com${triggerId}?api-version=2026-05-01-preview"
      acquired=$(mktemp "$SCRIPT_DIR/.trigger-read.XXXXXXXX") ||
        { echo 'Could not create trigger-read staging file.' >&2; exit 1; }
      readFile="$acquired"
      readPath="$readFile"
      if command -v cygpath >/dev/null 2>&1; then readPath=$(cygpath -w "$readFile"); fi
      az rest --method get --url "$url" --output-file "$readPath" -o none ||
        { echo "Could not read trigger $triggerName." >&2; exit 1; }
      body=$(connector_jq -ce '
        if .properties.deliveryMode != "Poll" then error("Expected Poll delivery mode")
        else {properties: (.properties | del(.provisioningState, .pollingEndpoints) | .state = "Disabled")}
        end' "$readFile")
      acquired=$(mktemp "$SCRIPT_DIR/.trigger-update.XXXXXXXX") ||
        { echo 'Could not create trigger-update staging file.' >&2; exit 1; }
      bodyFile="$acquired"
      printf '%s\n' "$body" >"$bodyFile" ||
        { echo 'Could not write trigger-update staging file.' >&2; exit 1; }
      az rest --method put --url "$url" --body "@$bodyFile" -o none ||
        { echo "Could not disable trigger $triggerName." >&2; exit 1; }
    )
  fi
done < <(echo "$triggerDefinitions" | connector_jq -r '.[] | select(.enabled == false) | .functionName')

get_connection_status() {
  local cli_status
  cli_status=$(az connector-namespace connection show \
    -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
    -n "$connectorNamespaceConnectionName" --query properties.overallStatus -o tsv) || return
  printf '%s\n' "${cli_status%$'\r'}"
}

currentStatus=$(get_connection_status)
if [[ "$currentStatus" == "Connected" ]]; then
  echo "SharePoint connection is already authorized."
  exit 0
fi

echo "Authorize the SharePoint connection with an account that can access the monitored site and library."
consentLink=""
for attempt in 1 2 3 4 5; do
  consentLink=$(az connector-namespace connection list-consent-links \
    -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
    --connection-name "$connectorNamespaceConnectionName" \
    --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" \
    --query 'value[0].link' -o tsv 2>/dev/null || true)
  consentLink="${consentLink%$'\r'}"
  if [[ -z "$consentLink" || "$consentLink" == "null" ]]; then
    consentLink=$(az connector-namespace connection list-consent-links \
      -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
      --connection-name "$connectorNamespaceConnectionName" \
      --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" \
      --query link -o tsv 2>/dev/null || true)
    consentLink="${consentLink%$'\r'}"
  fi
  if [[ -n "$consentLink" && "$consentLink" != "null" ]]; then
    break
  fi
  if [[ "$attempt" != "5" ]]; then
    echo "Consent-link attempt ${attempt} failed. Retrying in 5 seconds..."
    sleep 5
  fi
done
if [[ -z "$consentLink" || "$consentLink" == "null" ]]; then
  echo "ERROR: Could not obtain a SharePoint consent link." >&2
  exit 1
fi

echo "Consent URL: ${consentLink}"
if command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$consentLink" >/dev/null 2>&1 || echo "Open the consent URL in your browser."
elif command -v open >/dev/null 2>&1; then
  open "$consentLink" >/dev/null 2>&1 || echo "Open the consent URL in your browser."
else
  echo "Open the consent URL in your browser."
fi

deadline=$((SECONDS + 300))
while (( SECONDS < deadline )); do
  sleep 3
  currentStatus=$(get_connection_status)
  if [[ "$currentStatus" == "Connected" ]]; then
    echo "SharePoint connection authorized. Selected Poll trigger configurations are provisioned."
    exit 0
  fi
done
echo "ERROR: Timed out waiting for the SharePoint connection to become Connected." >&2
exit 1
