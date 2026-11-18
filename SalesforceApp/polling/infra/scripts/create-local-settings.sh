#!/usr/bin/env bash
create_local_settings() (
set -euo pipefail
umask 077
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/local-settings.sh"
target="$script_dir/../../local.settings.json"
if [[ -d "$target" ]]; then
    echo 'local.settings.json must not be a directory.' >&2
    exit 1
fi
if [[ -e "$target" || -L "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]] || { echo 'local.settings.json must be a regular file, not a link.' >&2; exit 1; }
    echo 'Existing local.settings.json preserved.'
    exit 0
fi
endpoint="${1:-}"
if [[ -z "$endpoint" ]]; then
    outputs="$(azd env get-values --output json)"
    endpoint="$(connector_jq -er '.connectorPollingEndpoint | select(type == "string" and length > 0)' <<< "$outputs")"
fi
if [[ ! "$endpoint" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/api/connectorGateways/[A-Za-z0-9._~-]+)?/?$ ]]; then
    echo 'Missing or invalid gateway-level connectorPollingEndpoint. Provision the Poll trigger configurations first.' >&2
    exit 1
fi
settings="$(connector_jq -n --arg endpoint "$endpoint" '{
  IsEncrypted: false,
  Values: {
    AzureWebJobsStorage: "UseDevelopmentStorage=true",
    FUNCTIONS_WORKER_RUNTIME: "dotnet-isolated",
    ConnectorNamespace__pollingEndpoint: $endpoint,
    OnNewRecordTriggerConfigName: "salesforce-onnewrecord",
    OnUpdatedRecordTriggerConfigName: "salesforce-onupdatedrecord"
  }
}')"
set -o noclobber
printf '%s\n' "$settings" > "$target" ||
    { echo 'Could not create local.settings.json without overwriting an existing path.' >&2; exit 1; }
echo 'Created ignored local.settings.json for Azurite and developer authentication.'
)
create_local_settings "$@"
