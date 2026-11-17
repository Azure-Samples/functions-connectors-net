# Microsoft Dataverse Webhook Triggers (.NET)

Azure Functions sample using the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector). The Connector Namespace delivers events to the function's public HTTPS callback.

Handlers log only the trigger name.

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnDataverseRowChanged` | [`SubscribeWebhookTrigger`](https://learn.microsoft.com/connectors/commondataservice/#when-a-row-is-added,-modified-or-deleted) | Combined row added, modified or deleted |
| `OnDataverseActionPerformed` | [`BusinessEventsTrigger`](https://learn.microsoft.com/connectors/commondataservice/#when-an-action-is-performed) | Selected action performed |
| `OnDataverseRowAdded` | `SubscribeOnNewItems` | When a row is added |
| `OnDataverseRowModified` | `SubscribeOnUpdatedItems` | When a row is modified |
| `OnDataverseRowDeleted` | `SubscribeOnDeletedItems` | When a row is deleted |

These are the five operations displayed in the Connector Namespace portal. All five handlers use raw `JsonElement`; parse fields for your selected table or action without logging sensitive row values. Row schemas are resolved dynamically for the selected table.

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later
- For deployment hooks: PowerShell 7.3 or later on Windows; Bash and [jq](https://jqlang.org/download/) on macOS/Linux (PowerShell is not required)
- An Azure subscription with permission to create resources and role assignments
- A Dataverse organization and an account permitted to register organization-scoped subscriptions
- For local execution: [Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local#install-the-azure-functions-core-tools) supporting .NET 10 and [Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite#install-azurite)
- The [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli):

```powershell
irm https://aka.ms/connector-namespace-cli-install-ps | iex
```

```bash
curl -fsSL https://aka.ms/connector-namespace-cli-install | sh
```

## Deploy to Azure

```powershell
cd dataverseApp\webhook
az login
azd auth login
azd env new dataverse-webhook
azd up
```

```bash
cd dataverseApp/webhook
az login
azd auth login
azd env new dataverse-webhook
azd up
```

Authorize the Dataverse connection in the browser when prompted. Use a different azd environment name for each polling and webhook deployment.

The postdeploy hook runs the PowerShell implementation on Windows and the native Bash implementation on macOS/Linux.

## Choose and configure triggers

Triggers need source inputs such as an environment, table, scope, or action. After browser authorization, the postdeploy hook asks which of the five triggers to configure, then collects their required inputs. You do not need to look up selectors in the portal or manually set `DATAVERSE_*` source variables.

**Choose the combined row-change trigger OR the separate added/modified/deleted triggers you need.** Configuring both against the same source produces overlapping events: the same change can invoke both handlers. The hook warns before prompting but allows intentional overlap. Action-performed is a separate choice.

For example (available choices depend on your account and connector metadata):

```text
OnDataverseActionPerformed (BusinessEventsTrigger)
Configure this trigger?
  [1] Configure
  [2] Skip
Enter number ...: 1

Environment
  [1] Contoso development
Enter number ...: 1

Catalog
  [1] Common Data Service
Enter number ...: 1
```

The hook lists numbered options whenever the connector provides them, including dependent category, table, action, and separate-row scope choices. If no usable choices are available, it asks for the exact connector identifier:

```text
No usable options returned for sdkmessagename. Enter its connector identifier manually, or leave blank to skip.
sdkmessagename (Enter to skip this trigger): GrantAccess
```

**Pressing Enter at any prompt skips that entire trigger**, not just that field. Choosing `Skip` does the same. If the trigger has never been configured, skipping it creates nothing. If you configured it on an earlier run and skip it now, the hook disables its Connector Namespace configuration and corresponding function, but does not delete either or disable the entire Function App. The hook only modifies configurations belonging to this sample's deployed app, not another app's configurations. Choose at least one trigger; skipping all stops before any trigger or function settings are changed. Lookup failures stop setup rather than guessing values.

The combined trigger uses all three row events (`message=7`) and organization scope (`scope=4`), like the TypeScript sample. Separate triggers use their own connector-provided scope choices. Optional modified-row column filters are not configured. Connector Namespace manages the Dataverse source callback. The hook separately configures delivery to the Function App and retrieves its `connector_extension` system key automatically.

### Rerun or correct a selection

Selections are saved in the selected azd environment as `DATAVERSE_WEBHOOK_TRIGGER_INPUTS`. Ordinary `azd up` or `azd hooks run postdeploy` reuses them. Healthy, unchanged enabled configurations are not resubmitted; changed callback URLs or keys update those same configurations.

If you chose the wrong environment, table, or action, or your local settings are missing or outdated, run either command from this folder to choose your triggers again and regenerate `local.settings.json`. This also updates the real Azure trigger configurations and function settings. The local file is replaced, so preserve any custom values first.

```powershell
pwsh -File ./infra/scripts/postdeploy.ps1 -Reconfigure -ForceLocalSettings
```

```bash
bash ./infra/scripts/postdeploy.sh --reconfigure --force-local-settings
```

Answer for all five triggers again. Selected configurations are updated in place under the same names, including the combined, separate-row, and action triggers. Retained disabled configurations can be re-enabled by selecting them again; skipped ones are disabled, not deleted. Clearing `DATAVERSE_WEBHOOK_TRIGGER_INPUTS` also makes the next hook run prompt again. No full infrastructure redeployment is needed.

The hook checks all same-named resources before writing and refuses to modify another app's configuration, another delivery mode, or legacy `GetOn*_V2` operations. Use a dedicated namespace. Old manual source variables and enable flags are no longer used. A legacy action cleanup marker still blocks creating a missing action configuration until its exact-owned source cleanup is verified.

During `azd up`, azd prompts for unset resource regions: `AZURE_LOCATION` for the Function App, storage, and resource group; `CONNECTOR_NAMESPACE_LOCATION` for the namespace; and `TELEMETRY_LOCATION` for Application Insights and Log Analytics. None has a template default, including the monitoring region. Saved or explicitly set values are reused on subsequent runs. Choose regions that support the respective services; changing an existing resource's region is not an in-place migration.

## Local development

1. A successful `azd up` creates `local.settings.json` in `dataverseApp\webhook` if it does not already exist. If the file is missing, outdated, or you chose the wrong triggers, use the commands in [Rerun or correct a selection](#rerun-or-correct-a-selection) to choose your triggers again and regenerate it.

2. Start Azurite in a separate terminal:

   ```powershell
   azurite
   ```

   ```bash
   azurite
   ```

3. Start the local host:

   ```powershell
   dotnet build
   func start --enableAuth
   ```

   ```bash
   dotnet build
   func start --enableAuth
   ```

   Core Tools v4 bypasses local key authentication by default. Enable it before exposing the host through a public tunnel.

4. Create a public HTTPS tunnel forwarding to local port 7071, then switch the existing configurations to it:

   ```powershell
   pwsh -File ./infra/scripts/postdeploy.ps1 -CallbackBaseUrl https://your-tunnel.example
   ```

   ```bash
   bash ./infra/scripts/postdeploy.sh --callback-base-url https://your-tunnel.example
   ```

   The hook automatically reads this local host's `connector_extension` key from Azurite's `azure-webjobs-secrets` container. You do not copy or enter a key. The key is not printed or saved with trigger selections; its private temporary file is deleted. Keep the local host running.

   If Azurite contains multiple hosts, identify this host with `AzureFunctionsWebHost__hostid` in local settings or pass `-LocalHostId <host-id>` in PowerShell / `--local-host-id <host-id>` in Bash. The hook refuses to guess between multiple hosts. Automatic retrieval requires local Azurite storage, not a cloud storage account.

This switches the same configurations' delivery destination; it does not create an additional local set of Dataverse registrations. Local callbacks authenticate using the local key, not the Azure key. If you also need to change source selections and refresh local settings, add `-Reconfigure -ForceLocalSettings` in PowerShell or `--reconfigure --force-local-settings` in Bash. Without a callback URL option, the hook restores Azure delivery.

When finished, restore Azure delivery **before closing the tunnel**:

```powershell
azd hooks run postdeploy
```

```bash
azd hooks run postdeploy
```

The ordinary hook uses the Azure callback and current Azure system key.

## Verify

In [Connector Namespaces](https://connectors.azure.com/), check the connection is **Connected** and selected configurations are **Enabled**.

Inspect source errors or pending initialization, then rerun `azd hooks run postdeploy` after initialization. Latest execution status is not proof of event delivery.

Create a new, clearly named sample-owned row, modify it, then delete it. Look for `Received OnDataverseRowChanged trigger` for each event and the corresponding separate handler logs if enabled. Observe each expected invocation before moving to the next step, especially before deleting the row: Dataverse processes callbacks asynchronously, and deleting the fixture too early can cancel pending update/action callback-expansion jobs.

Verify action-performed only with an authorized action on your own fixture. Wait for `Received OnDataverseActionPerformed trigger` before deleting that fixture; HTTP success from the action alone does not establish event delivery. Do not modify business rows.

## Cleanup

### Action subscription cleanup

Ordinary skipping disables and retains configurations, including action-performed; it does not delete Dataverse registrations. Changing selectors uses an in-place update, not delete/recreate. For permanent teardown, removing a namespace configuration does not prove its Dataverse callback was deleted.

1. Have an authorized administrator identify the exact-owned callback using subscription/audit evidence and delete only that callback.
2. Verify an authenticated `GET /api/data/v9.2/callbackregistrations(<exact-id>)` returns **404** and the namespace configuration is absent.
3. If an older hook left a pending cleanup marker, remove only that exact marker after cleanup is verified.

If cleanup is unverified, keep any legacy marker and do not manually delete and replace the action configuration.

### Azure resources

Remove this environment's Azure resources from this folder:

```powershell
azd down --purge
```

[License](../../LICENSE).

## More

- [Connector trigger payloads for Azure Functions](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [Microsoft Dataverse connector reference](https://learn.microsoft.com/connectors/commondataservice/)
