#!/usr/bin/env bash
set -euo pipefail
umask 077

forceLocalSettings=false
for argument in "$@"; do
    case "$argument" in
        --force-local-settings|-ForceLocalSettings) forceLocalSettings=true ;;
        *) echo "ERROR: Unknown argument: $argument" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/local-settings.sh"
command -v jq >/dev/null 2>&1 || { echo 'ERROR: jq 1.6 or later is required for the Bash hook.' >&2; exit 1; }
if ! az extension show --name connector-namespace --query name -o tsv >/dev/null 2>&1; then
    echo "ERROR: Install the connector-namespace Azure CLI extension before running this script." >&2
    exit 1
fi

read_output() {
    local value
    if ! value=$(azd env get-value "$1"); then
        echo "ERROR: Could not read azd output $1." >&2
        return 1
    fi
    value="${value%$'\r'}"
    if [[ -z "${value//[[:space:]]/}" || "$value" == "null" ]]; then
        echo "ERROR: Missing azd output $1. Run azd provision first." >&2
        return 1
    fi
    printf '%s' "$value"
}

resourceGroupName=$(read_output resourceGroupName)
connectorNamespaceName=$(read_output connectorNamespaceName)
connectionName=$(read_output connectorNamespaceConnectionName)
pollingEndpoint=$(read_output connectorPollingEndpoint)
triggerConfigName=$(read_output onUpdatedFileTriggerConfigName)
subscriptionId=$(read_output AZURE_SUBSCRIPTION_ID)

localSettings=$(connector_jq -n --arg endpoint "$pollingEndpoint" --arg trigger "$triggerConfigName" \
    '{IsEncrypted:false,Values:{AzureWebJobsStorage:"UseDevelopmentStorage=true",
      FUNCTIONS_WORKER_RUNTIME:"dotnet-isolated",ConnectorNamespace__pollingEndpoint:$endpoint,
      OnUpdatedFileTriggerConfigName:$trigger}}')
write_local_settings "$localSettings" "$forceLocalSettings"

connectionUrl="https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/connectorGateways/$connectorNamespaceName/connections/$connectionName?api-version=2026-05-01-preview"
authSet=$(az rest --method get --url "$connectionUrl" --query properties.parameterValueSet.name -o tsv) ||
    { echo 'Could not read the Azure Blob connection authentication type.' >&2; exit 1; }
if [[ "${authSet%$'\r'}" != managedIdentityAuth ]]; then
    echo 'Azure Blob connection is not configured for managedIdentityAuth. Reprovision to create the MI-specific connection; an existing OAuth connection cannot be validated as managed identity.' >&2
    exit 1
fi

get_connection_status() {
    local status
    if ! status=$(az connector-namespace connection show \
        -g "$resourceGroupName" --namespace "$connectorNamespaceName" -n "$connectionName" \
        --query properties.overallStatus -o tsv); then
        echo "ERROR: Could not read the Azure Blob connection status." >&2
        return 1
    fi
    printf '%s' "${status%$'\r'}"
}

echo "Checking Azure Blob managed-identity connection readiness (no user consent required)."
deadline=$((SECONDS + 300))
while true; do
    status=$(get_connection_status)
    if [[ "$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]')" =~ ^(ready|connected)$ ]]; then
        echo "Azure Blob managed-identity connection is $status. The Poll trigger configuration is provisioned."
        exit 0
    fi
    [[ "$SECONDS" -lt "$deadline" ]] || break
    sleep 5
done
echo "ERROR: Timed out waiting for the Azure Blob managed-identity connection to become Ready or Connected. Verify the namespace connection access policy and namespace Storage Blob Data Reader access on the monitored storage account. Allow RBAC propagation, then rerun the hook." >&2
exit 1
