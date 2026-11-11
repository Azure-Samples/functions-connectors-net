# Microsoft Dataverse Polling Triggers (.NET)

Azure Functions sample using the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector) with `DeliveryMode = Poll`. The host receives events outbound from the Connector Namespace; no public callback or tunnel is needed.

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

Connector Namespace manages the source callback; the sample supplies only `dataset`, `table`, and `scope`, not a callback body. Poll delivery needs no public callback. The modified-row operation's optional column filters are not configured by this sample.

Separate row events overlap the combined subscription. Set an optional trigger's flag to `false` and rerun `azd up` to disable and retain its namespace configuration.

Set the flag back to `true` and rerun `azd up` to re-enable the same configuration. An optional configuration that was never created needs no cleanup.

The postdeploy hook checks action selectors and its cleanup journal before creating or re-enabling the action configuration. Changed selectors or a missing configuration with a pending cleanup marker are rejected before an action write.

Separate row configurations are created by the postdeploy hook, not Bicep, so the hook can inspect existing bindings before writing. It refuses to overwrite, disable, or adopt same-named legacy `GetOn*_V2` configurations or different selectors/destinations. Use a fresh azd environment, or have an authorized administrator inspect and explicitly clean up the exact old source registrations and namespace configurations before switching. There is no automatic in-place migration. Unchanged optional Poll configurations retain their selectors when their state changes.

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
   dotnet build
   func start
   ```

Local access uses developer credentials, not the deployed managed identity. The optional `postdeploy.sh` wrapper also requires PowerShell.

## Verify

In [Connector Namespaces](https://connectors.azure.com/), check the connection is **Connected** and selected configurations are **Enabled** with Poll delivery.

Initialization can be asynchronous: inspect source errors or pending status, then rerun `azd hooks run postdeploy` after initialization. Latest execution status is not delivery proof; do not recreate an action just to clear an earlier failure.

Create a new, clearly named sample-owned row, modify it, then delete it. Look for `Received OnDataverseRowChanged trigger` for each event and the corresponding separate handler logs if enabled. Observe each expected invocation before moving to the next step, especially before deleting the row: Dataverse processes callbacks asynchronously, and deleting the fixture too early can cancel pending update/action callback-expansion jobs.

Verify action-performed only with an authorized action on your own fixture. Wait for `Received OnDataverseActionPerformed trigger` before deleting that fixture; HTTP success from the action alone does not establish event delivery. Do not modify business rows.

## Cleanup

Ordinary opt-out disables and retains optional configurations, including action-performed. It does not require manual source cleanup.

### Action subscription cleanup

Permanent teardown or changing action selectors is different: removing a namespace configuration does not prove its Dataverse source callback is inactive or deleted.

Before replacing an action subscription, have an authorized administrator verify exact-owned source cleanup using supported source evidence. Preserve its cleanup marker until confirmed, including after a failed first creation; a readable callback row alone does not establish whether it is active.

### Azure resources

Remove this environment's Azure resources from this folder:

```powershell
azd down --purge
```

[License](../../LICENSE).

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [Microsoft Dataverse connector reference](https://learn.microsoft.com/connectors/commondataservice/)
