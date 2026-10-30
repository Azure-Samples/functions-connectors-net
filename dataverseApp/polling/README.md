# Dataverse current events with Poll delivery

The Functions connector extension pulls and acknowledges events from Connector Namespace.
`OnDataverseRowChanged` uses the nondeprecated `SubscribeWebhookTrigger` operation for
**added, modified, and deleted** rows. `OnDataverseActionPerformed` uses current
`BusinessEventsTrigger` and is disabled until configured.
See [SDK exceptions, required action identifiers, and service limitations](../README.md).

Both handlers are approved `JsonElement` exceptions because the SDK lacks the current
operation models. They log receipt and JSON kind only. There are no deprecated row
listeners, HTTP List rows action, Blob bindings, or event-payload storage.

## Prerequisites

- .NET 10 SDK, Azure CLI >= 2.75.0, Azure Developer CLI (`azd`), PowerShell 7 (`pwsh`)
- The `connector-namespace` CLI extension:
  `irm https://aka.ms/connector-namespace-cli-install-ps | iex` in PowerShell, or
  `curl -fsSL https://aka.ms/connector-namespace-cli-install | sh` in Bash
- A Dataverse organization URL and an OAuth identity authorized for organization-scoped
  subscriptions on the selected table
- For local execution: Functions Core Tools v4 and Azurite for host storage

## Deploy

```powershell
cd dataverseApp\polling
azd auth login
az login
azd env new dataverse-polling
azd env set DATAVERSE_ENVIRONMENT_URL "https://contoso.crm.dynamics.com"
azd env set DATAVERSE_TABLE_NAME "account"
# If needed, choose an approved telemetry region:
azd env set TELEMETRY_LOCATION "eastus2"
azd up
```

The org URL is required before provisioning. `DATAVERSE_TABLE_NAME` defaults to `account`,
the logical table name, not the Web API entity set `accounts`. Infrastructure provisions
an enabled Poll configuration `dataverse-ondataverserowchanged` with `organization`,
`entityname`, `message=7`, and `scope=4`. The action subscription is created only when
`DATAVERSE_ENABLE_ACTION_TRIGGER=true` and its four required identifiers are supplied.
Do not add the legacy `dataset`/`table` parameters to these current operations.

ARM/Bicep is used because older CLI `trigger create` commands do not expose `deliveryMode`.
The Functions host requires no inbound callback, tunnel, or connector system key.
Infrastructure retains host/deployment storage and grants connection access to the namespace,
Function identity, and provisioning user. The post-deploy hook preserves OAuth consent and
generates ignored local settings without deployed managed-identity overrides.

**Cost:** one 2-GB always-ready instance remains allocated per enabled Poll Function,
even while idle. There is one by default and two if action-performed is enabled.
These user-approved settings are persistent, not temporary test warm-ups.

## Run locally

Use the generated `local.settings.json`, or copy `local.settings.example.json` and fill
in the service-returned polling endpoint. Sign in with `az login`, start Azurite, then:

```powershell
dotnet build
func start
```

`ConnectorNamespace__pollingEndpoint` must be a gateway-level base derived from the service's
`pollingEndpoints.receiveUri`, not the complete receive URL.
`<FunctionName>TriggerConfigName` selects each trigger, and
`AzureWebJobs.OnDataverseActionPerformed.Disabled` defaults to `true`.
To regenerate stale settings after provisioning:

```powershell
.\infra\scripts\postdeploy.ps1 -ForceLocalSettings
```

Local and deployed listeners sharing a trigger compete for its events.

## Verify

OAuth must be `Connected`; current trigger configs must be `Enabled`, with `deliveryMode`
equal to `Poll` and their matching current operation. Use raw ARM: older CLI response models
drop the delivery-mode property.

```powershell
$rg = azd env get-value resourceGroupName
$ns = azd env get-value connectorNamespaceName
$subscription = azd env get-value AZURE_SUBSCRIPTION_ID
$uri = "https://management.azure.com/subscriptions/$subscription/resourceGroups/$rg/providers/Microsoft.Web/connectorGateways/$ns/triggerConfigs?api-version=2026-05-01-preview"
az rest --method get --url $uri `
  --query "value[].{name:name,state:properties.state,deliveryMode:properties.deliveryMode,operation:properties.operationName}" -o json
$statusUri = "https://management.azure.com/subscriptions/$subscription/resourceGroups/$rg/providers/Microsoft.Web/connectorGateways/$ns/triggerConfigs/dataverse-ondataverserowchanged/triggerStatuses/latest?api-version=2026-05-01-preview"
az rest --method get --url $statusUri `
  --query "{status:lastExecutionStatus,code:lastExecutionStatusCode,error:lastExecutionOutputs.body.error}" -o json
```

An enabled configuration can still have a failed source subscription. Resolve backend
errors before source-event testing; using entity set `accounts` instead of logical table
`account`, for example, fails with `0x80040203: Entity not present in cache: accounts`.

Only after registration succeeds, create a clearly named sample-owned row, observe the
`Received OnDataverseRowChanged trigger` log, modify only that row and observe another
event, then delete only that row and observe deletion. Separately invoke the configured
safe business action to verify `OnDataverseActionPerformed`. Do not modify business rows.
Retain exact service errors if current-operation registration fails; do not substitute
legacy operations or claim runtime success from an enabled configuration alone.

## Cleanup

Run `azd down --purge` to delete resources and stop the always-ready baseline charges.
