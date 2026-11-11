# Microsoft Dataverse Webhook Triggers (.NET)

Azure Functions sample using the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector). The Connector Namespace delivers events to the function's public HTTPS callback.

Handlers log only the trigger name.

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnDataverseRowChanged` | [`SubscribeWebhookTrigger`](https://learn.microsoft.com/connectors/commondataservice/#when-a-row-is-added,-modified-or-deleted) | Row added, modified or deleted (default) |
| `OnDataverseActionPerformed` | [`BusinessEventsTrigger`](https://learn.microsoft.com/connectors/commondataservice/#when-an-action-is-performed) | Selected action performed (opt-in) |
| `OnDataverseRowAdded` | `SubscribeOnNewItems` | When a row is added (opt-in) |
| `OnDataverseRowModified` | `SubscribeOnUpdatedItems` | When a row is modified (opt-in) |
| `OnDataverseRowDeleted` | `SubscribeOnDeletedItems` | When a row is deleted (opt-in) |

These are the five operations displayed in the Connector Namespace portal. All five handlers use raw `JsonElement`; parse fields for your selected table or action without logging sensitive row values. Row schemas are resolved dynamically for the selected table.

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
cd dataverseApp\webhook
az login
azd auth login
azd env new dataverse-webhook
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
| `DATAVERSE_ENTITY_SET_NAME=<table-selector>` | Separate `table` selector (`Name` from `GetTables`); default `accounts`, verify for your environment |
| `DATAVERSE_ROW_SCOPE=<scope-selector>` | Required when separate row triggers are enabled; exact string from `GetScopeFilters(dataset, table)`, no default |
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

For separate row subscriptions, select the environment (`dataset`), then the table returned by `GetTables`, then a scope returned by `GetScopeFilters` for that same environment/table in the portal's trigger form. Copy the exact selector values into the settings above; do not assume the combined operation's numeric scope `4` is valid for `SubscribeOn*`. The combined operation continues to use `organization`, logical `entityname`, message `7`, and scope `4`.

Connector Namespace manages the source callback; the sample supplies only `dataset`, `table`, and `scope`, not a callback body. `notificationDetails` separately configures authenticated delivery to the Function App. The modified-row operation's optional column filters are not configured by this sample.

Separate row events overlap the combined subscription. Set their flag to `false` and rerun `azd up` to disable them and remove their configurations.

The hook validates all existing separate-row bindings before changing optional configurations. Same-named legacy `GetOn*_V2` configurations, different selectors, and different destinations are rejected rather than overwritten or deleted. Use a fresh azd environment, or have an authorized administrator inspect and explicitly clean up the exact old source registrations and namespace configurations before switching. There is no automatic in-place migration.

An unchanged enabled separate-row configuration is preserved on reruns, avoiding duplicate source subscriptions. A retained but disabled configuration must be inspected and enabled explicitly in Connector Namespace; it is not recreated. Removing a namespace configuration does not prove its Dataverse source callback is gone: verify exact-owned source cleanup before creating a replacement or changing selectors.

Use a dedicated namespace for this sample, not one containing unrelated registrations.

## Local development

1. Prepare `local.settings.json` from `azd up` in `dataverseApp\webhook`.

   Existing files are preserved; if missing, run `azd hooks run postdeploy`. After changing selected triggers, update their `AzureWebJobs.<function-name>.Disabled` flags using `local.settings.example.json` as a reference (`true` unless that optional trigger is selected).

2. Start Azurite in a separate terminal:

   ```powershell
   azurite
   ```

3. Start the local host:

   ```powershell
   dotnet build
   func start --enableAuth
   ```

   Core Tools v4 bypasses local key authentication by default. Enable it before exposing the host through a public tunnel.

4. Create a public HTTPS tunnel and separate local trigger configurations targeting it.

   Authenticate callbacks with the **local** host's `connector_extension` system key, not the deployed Function App's key. See [trigger configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md).

The postdeploy hook configures Azure callbacks only, not the tunnel or local configurations. Its optional `postdeploy.sh` wrapper also requires PowerShell.

## Verify

In [Connector Namespaces](https://connectors.azure.com/), check the connection is **Connected** and selected configurations are **Enabled**.

Inspect source errors or pending initialization, then rerun `azd hooks run postdeploy` after initialization. Latest execution status is not proof of event delivery.

An unchanged action is preserved on reruns and must already be Enabled. The hook does not recreate a disabled subscription.

Create a new, clearly named sample-owned row, modify it, then delete it. Look for `Received OnDataverseRowChanged trigger` for each event and the corresponding separate handler logs if enabled. Observe each expected invocation before moving to the next step, especially before deleting the row: Dataverse processes callbacks asynchronously, and deleting the fixture too early can cancel pending update/action callback-expansion jobs.

Verify action-performed only with an authorized action on your own fixture. Wait for `Received OnDataverseActionPerformed trigger` before deleting that fixture; HTTP success from the action alone does not establish event delivery. Do not modify business rows.

## Cleanup

### Action subscription cleanup

To disable action-performed, set `DATAVERSE_ENABLE_ACTION_TRIGGER` to `false` and rerun `azd up`. Removing its Connector Namespace configuration does not prove its Dataverse callback was deleted.

1. Have an authorized administrator identify the exact-owned callback using subscription/audit evidence and delete only that callback.
2. Verify an authenticated `GET /api/data/v9.2/callbackregistrations(<exact-id>)` returns **404** and the namespace configuration is absent.
3. Remove only the pending marker printed by the hook, then rerun the hook.

If cleanup is unverified, keep the marker and do not replace the action subscription or change its selectors.

### Azure resources

Remove this environment's Azure resources from this folder:

```powershell
azd down --purge
```

[License](../../LICENSE).

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [Microsoft Dataverse connector reference](https://learn.microsoft.com/connectors/commondataservice/)
