# Microsoft Dataverse Polling Triggers (.NET)

Azure Functions sample using the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector) with `DeliveryMode = Poll`. The host receives events outbound from the Connector Namespace; no public callback or tunnel is needed.

Handlers log only the trigger name.

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnDataverseRowChanged` | [`SubscribeWebhookTrigger`](https://learn.microsoft.com/connectors/commondataservice/#when-a-row-is-added,-modified-or-deleted) | Row added, modified or deleted (default) |
| `OnDataverseActionPerformed` | [`BusinessEventsTrigger`](https://learn.microsoft.com/connectors/commondataservice/#when-an-action-is-performed) | Selected action performed (opt-in) |
| `OnDataverseRowAdded` | `GetOnNewItems_V2` | Row added (opt-in) |
| `OnDataverseRowModified` | `GetOnUpdatedItems_V2` | Row modified (opt-in) |
| `OnDataverseRowDeleted` | `GetOnDeletedItems_V2` | Row deleted (opt-in) |

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later
- PowerShell 7.3 or later for deployment hooks, including the optional Bash wrapper
- An Azure subscription with permission to create resources and role assignments
- A Dataverse organization and an account permitted to register organization-scoped subscriptions
- For local execution: Functions Core Tools v4 supporting .NET 10 and Azurite
- The [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli):

```powershell
irm https://aka.ms/connector-namespace-cli-install-ps | iex
```

## Deploy to Azure

```powershell
cd dataverseApp\polling
az login
azd auth login
azd env new dataverse-polling
azd env set DATAVERSE_ENVIRONMENT_URL https://contoso.crm.dynamics.com
azd up
```

Authorize the Dataverse connection in the browser when prompted. Use a different azd environment name for each polling and webhook deployment.

## Optional configuration

Set values with `azd env set <name> <value>` before `azd up`.

| Setting | Purpose |
| --- | --- |
| `DATAVERSE_TABLE_NAME` | Combined-row logical table name; default `account` |
| `DATAVERSE_ENABLE_SEPARATE_ROW_TRIGGERS=true` | Enable all three separate row operations; default `false` |
| `DATAVERSE_ENTITY_SET_NAME=<entity-set>` | Separate entity-set selector; default `accounts`, not logical `account` |
| `AZURE_LOCATION` | Function region; prompted if unset |
| `CONNECTOR_NAMESPACE_LOCATION` | Namespace region; default `westcentralus` |
| `TELEMETRY_LOCATION` | Optional monitoring region override |
| `DATAVERSE_ENABLE_ACTION_TRIGGER=true` | Action-performed; requires all four identifiers below |

For action-performed, supply all four actual event-selector identifiers:

| Setting | Identifier |
| --- | --- |
| `DATAVERSE_EVENT_CATALOG=<catalog>` | Catalog identifier |
| `DATAVERSE_EVENT_CATEGORY=<category>` | Category identifier |
| `DATAVERSE_EVENT_TABLE=<logical-table>` | Table identifier accepted by the event selector |
| `DATAVERSE_EVENT_ACTION=<SDK-message>` | Action's `sdkmessagename` |

Separate row events overlap the combined subscription. Set their flag to `false` and rerun `azd up` to disable them and remove their configurations.

Use a dedicated namespace for this sample, not one containing unrelated registrations.

## Local development

Stop the deployed Function App before running locally to avoid competing listeners.

1. Prepare `local.settings.json` from `azd up` in `dataverseApp\polling`.

   Existing files are preserved. If missing, run `azd hooks run postdeploy`; after changing trigger selection, regenerate with `pwsh .\infra\scripts\postdeploy.ps1 -ForceLocalSettings`.

2. Sign in as the provisioned developer principal:

   ```powershell
   az login
   ```

3. Start Azurite in a separate terminal:

   ```powershell
   azurite
   ```

4. Start the local host:

   ```powershell
   func start
   ```

Local access uses developer credentials, not the deployed managed identity. The optional `postdeploy.sh` wrapper also requires PowerShell.

## Verify

In [Connector Namespaces](https://connectors.azure.com/), check the connection is **Connected** and selected configurations are **Enabled** with Poll delivery.

Initialization can be asynchronous: inspect source errors or pending status, then rerun `azd hooks run postdeploy` after initialization. Latest execution status is not delivery proof; do not recreate an action just to clear an earlier failure.

Create a new, clearly named sample-owned row, modify it, then delete it. Look for `Received OnDataverseRowChanged trigger` for each event and the corresponding separate handler logs if enabled.

Verify action-performed only with an authorized action on your own fixture. Allow time for delivery; do not modify business rows.

## Cleanup

To disable action-performed, set `DATAVERSE_ENABLE_ACTION_TRIGGER` to `false` and rerun `azd up`. Removing its Connector Namespace configuration does not prove its Dataverse callback was deleted.

1. Have an authorized administrator identify the exact-owned callback using subscription/audit evidence and delete only that callback.
2. Verify an authenticated `GET /api/data/v9.2/callbackregistrations(<exact-id>)` returns **404** and the namespace configuration is absent.
3. Remove only the pending marker printed by the hook, then rerun the hook.

If cleanup is unverified, keep the marker and do not replace the action subscription. Poll registrations are provisioned before hook checks, so complete cleanup before provisioning a replacement.

Remove this environment's Azure resources from this folder:

```powershell
azd down --purge
```

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [Microsoft Dataverse connector reference](https://learn.microsoft.com/connectors/commondataservice/)
