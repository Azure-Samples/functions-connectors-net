# Microsoft Dataverse Webhook Triggers (.NET)

Azure Functions sample using the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector). The Connector Namespace delivers events to the function's public HTTPS callback. Combined-row and action handlers use `JsonElement` because Azure.Connectors.Sdk 0.15.0-preview.1 lacks their models. The three separate handlers use its released typed payloads (`Body.Value` contains rows). Each invocation logs only the trigger name, without payload fields or inferred counts.

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnDataverseRowChanged` | [`SubscribeWebhookTrigger`](https://learn.microsoft.com/connectors/commondataservice/#when-a-row-is-added,-modified-or-deleted) | Row added, modified, or deleted (`message=7`, organization scope `scope=4`) |
| `OnDataverseActionPerformed` | [`BusinessEventsTrigger`](https://learn.microsoft.com/connectors/commondataservice/#when-an-action-is-performed) | Selected action performed (opt-in) |
| `OnDataverseRowAdded` | `GetOnNewItems_V2` | Row added; opt-in; requires permission to register organization-scoped subscriptions |
| `OnDataverseRowModified` | `GetOnUpdatedItems_V2` | Row modified; opt-in; requires permission to register organization-scoped subscriptions |
| `OnDataverseRowDeleted` | `GetOnDeletedItems_V2` | Row deleted; opt-in; requires permission to register organization-scoped subscriptions |

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later
- PowerShell 7.3 or later (.NET 7+) for the default hook and the Bash wrapper alternative
- Functions Core Tools v4 and Azurite for local development
- A Dataverse organization and permission to register organization-scoped subscriptions
- [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli):

  ```bash
  curl -fsSL https://aka.ms/connector-namespace-cli-install | sh
  ```

  Or in PowerShell:

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

Authorize the Dataverse connection in the browser when prompted; already Connected consent is preserved.

Use different azd environment names for polling and webhook deployments.

## Optional configuration

| Setting / command | Purpose |
| --- | --- |
| `azd env set DATAVERSE_TABLE_NAME <logical-name>` | Monitor another table; default `account` |
| `DATAVERSE_ENABLE_SEPARATE_ROW_TRIGGERS=true` | Enable all three separate row operations; default `false` |
| `DATAVERSE_ENTITY_SET_NAME=<entity-set>` | Separate entity-set selector; default `accounts`, not logical `account` |
| `azd env set AZURE_LOCATION <region>` | Function region; selected during deployment if unset |
| `azd env set CONNECTOR_NAMESPACE_LOCATION <region>` | Independent Connector Namespace region; default `westcentralus` |
| `azd env set TELEMETRY_LOCATION <region>` | Use a supported monitoring region if unavailable in the Function region |
| `DATAVERSE_ENABLE_ACTION_TRIGGER=true` | Action-performed; requires all four identifiers below |
| `DATAVERSE_EVENT_CATALOG=<catalog>` | Catalog identifier |
| `DATAVERSE_EVENT_CATEGORY=<category>` | Category identifier |
| `DATAVERSE_EVENT_TABLE=<logical-table>` | Table identifier accepted by the event selector |
| `DATAVERSE_EVENT_ACTION=<SDK-message>` | Action's `sdkmessagename` |
| `azd hooks run postdeploy` | Rerun authorization and deployed callback registration; create missing local settings |
| `bash ./infra/scripts/postdeploy.sh` | Bash wrapper; still requires PowerShell 7.3 or later |
| Postdeploy `shell: sh`, `run: ./infra/scripts/postdeploy.sh` in `azure.yaml` | Use the Bash wrapper as the hook; PowerShell remains the default |

Set environment values with `azd env set <name> <value>` before `azd up`.

The hook preserves existing local settings and writes missing settings as UTF-8 JSON through a private staging file. Directories and links are rejected. Run one settings writer at a time; a conflicting first creation fails rather than overwriting the destination.

The deployed Function App uses its system-assigned identity for storage and telemetry. Worker telemetry uses the `ConnectorNamespace` identity settings; local development uses standard developer credentials.

- Action-performed is disabled by default. To enable it, supply all four actual event-selector identifiers.
- To disable it, set `DATAVERSE_ENABLE_ACTION_TRIGGER` to `false` and rerun `azd up`. This disables the function and removes its matching Connector Namespace configuration.
- Separate row operations are disabled by default and overlap combined-row events when enabled. They use the organization URL as `dataset` and the entity-set name as `table`; verify selectors with CN metadata. To disable them, set `DATAVERSE_ENABLE_SEPARATE_ROW_TRIGGERS=false` and rerun `azd up`; the hook removes the matching separate configurations by their deterministic names.

Registrations use deterministic names and PUT create-or-update behavior, without deleting before an update. The hook does not check existing trigger ownership before updating or removing disabled configurations; use a separate namespace for unrelated registrations. The action source-cleanup safeguards below still apply.

### Action subscription cleanup

Removing the action's Connector Namespace configuration does not prove that its Dataverse `callbackregistrations` row was removed. The provider does not expose that row's ID through the configuration; the hook never searches for or deletes source callbacks by table, action name or creator alone.

The hook records the exact namespace, connection, application, source organization and action selectors in an ignored, publish-excluded `.azure/dataverse-action-cleanup-<binding-hash>.json` marker. An unchanged action configuration is preserved on hook reruns instead of requesting another source registration. Changing its selectors requires completing cleanup first. On action opt-out, only the matching namespace configuration is removed and the hook reports incomplete source cleanup. Repeated opt-out keeps reporting this error while the marker remains; selected row configurations are still processed.

To complete cleanup, an authorized Dataverse administrator must identify the exact callback ID using authoritative subscription/audit evidence linking it to that same binding. Verify its organization, table, action and creator against that evidence; preserve all baseline and foreign callbacks. Remove only the proven owned callback, then confirm an authenticated `GET /api/data/v9.2/callbackregistrations(<exact-id>)` returns **404**. After confirming the namespace configuration is also absent, remove only the marker path printed by the hook and rerun it. This is manual confirmation, not automated source-cleanup proof. If identity or cleanup cannot be verified, keep the marker and do not create a replacement subscription.

## Local development

1. Prepare `local.settings.json`.

   From `dataverseApp\webhook`, use the settings generated by successful `azd up`. Only if the file is missing, run `pwsh ./infra/scripts/postdeploy.ps1` to generate it. Existing files are preserved; after changing trigger selection, match `AzureWebJobs.OnDataverseActionPerformed.Disabled` to that selection (`true` for row-only, `false` for action-performed). Also add or update the three separate Disabled flags shown in `local.settings.example.json` (`true` unless separate subscriptions are selected).

2. Start Azurite for host storage in a separate terminal:

   ```powershell
   azurite
   ```

3. Start the local Functions host:

   ```powershell
   func start
   ```

Real events require a public HTTPS callback and the local connector system key. The hook targets Azure only; it does not create a tunnel or accept local overrides.

## Verify

Check the connection is **Connected**, selected triggers are **Enabled**, and their latest source registration did not fail in [Connector Namespaces](https://connectors.azure.com/). An enabled configuration alone is insufficient: for the combined operation, `accounts` instead of logical `account` fails with `0x80040203: Entity not present in cache`. Separate operations instead require entity-set `accounts`.

Create, modify, then delete only a clearly named sample-owned row and look for `Received OnDataverseRowChanged trigger` in function logs for each event.

Never alter business rows. Allow time for delivery. Optional action verification requires its identifiers and a safe, authorized source action. For opted-in separate operations, verify the corresponding added, modified and deleted handler logs separately; catalog visibility and registration alone do not prove delivery.

Run `azd down --purge` from this folder to clean up.

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [Microsoft Dataverse connector reference](https://learn.microsoft.com/connectors/commondataservice/)
