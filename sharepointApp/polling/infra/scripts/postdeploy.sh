#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
  if ! echo "$outputs" | jq -e --arg name "$name" '.[$name] | type == "string" and test("\\S")' >/dev/null; then
    echo "ERROR: Missing azd output ${name}. Run azd provision first." >&2
    exit 1
  fi
done

resourceGroupName=$(echo "$outputs" | jq -r '.resourceGroupName')
connectorNamespaceName=$(echo "$outputs" | jq -r '.connectorNamespaceName')
connectorNamespaceConnectionName=$(echo "$outputs" | jq -r '.connectorNamespaceConnectionName')
pollingEndpoint=$(echo "$outputs" | jq -r '.connectorPollingEndpoint')
triggerSettings=$(echo "$outputs" | jq -ce '.triggerConfigSettings | if type == "string" then fromjson else . end | select(type == "object")')
triggerDefinitions=$(echo "$outputs" | jq -ce '.triggerDefinitions | if type == "string" then fromjson else . end | select(type == "array" and length == 10)')

localSettings=$(jq -n --arg endpoint "$pollingEndpoint" --argjson settings "$triggerSettings" \
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

existingNames=$(az connector-namespace trigger list \
  -g "$resourceGroupName" --namespace "$connectorNamespaceName" --query '[].name' -o json)
while IFS= read -r functionName; do
  triggerName="sharepoint-$(echo "$functionName" | tr '[:upper:]' '[:lower:]')"
  if echo "$existingNames" | jq -e --arg name "$triggerName" 'index($name) != null' >/dev/null; then
    az connector-namespace trigger update \
      -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
      -n "$triggerName" --state Disabled -o none
  fi
done < <(echo "$triggerDefinitions" | jq -r '.[] | select(.enabled == false) | .functionName')

localSettingsPath="${SCRIPT_DIR}/../../local.settings.json"
if [[ -e "$localSettingsPath" && "$forceLocalSettings" != "true" ]]; then
  echo "Existing local.settings.json preserved. Use --force-local-settings to regenerate it."
else
  printf '%s\n' "$localSettings" > "$localSettingsPath"
  echo "Created ignored local.settings.json using developer credentials and Azurite."
fi

get_connection_status() {
  az connector-namespace connection show \
    -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
    -n "$connectorNamespaceConnectionName" --query properties.overallStatus -o tsv
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
  if [[ -z "$consentLink" || "$consentLink" == "null" ]]; then
    consentLink=$(az connector-namespace connection list-consent-links \
      -g "$resourceGroupName" --namespace "$connectorNamespaceName" \
      --connection-name "$connectorNamespaceConnectionName" \
      --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" \
      --query link -o tsv 2>/dev/null || true)
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
