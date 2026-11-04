# SharePoint Online Webhook Triggers (.NET)

Azure Functions sample using [Azure.Connectors.Sdk](https://www.nuget.org/packages/Azure.Connectors.Sdk) and the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector). The Connector Namespace delivers events to the function's public HTTPS callback. All handlers use typed payloads and log only the trigger name and item count.

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnNewFile` | [`GetOnNewFileItems`](https://learn.microsoft.com/connectors/sharepointonline/#when-a-file-is-created-(properties-only)) | File created (properties only) |
| `OnUpdatedFile` | [`GetOnUpdatedFileItems`](https://learn.microsoft.com/connectors/sharepointonline/#when-a-file-is-created-or-modified-(properties-only)) | File created or modified (properties only) |
| `OnNewItem` | [`GetOnNewItems`](https://learn.microsoft.com/connectors/sharepointonline/#when-an-item-is-created) | Item created |
| `OnUpdatedItem` | [`GetOnUpdatedItems`](https://learn.microsoft.com/connectors/sharepointonline/#when-an-item-is-created-or-modified) | Item created or modified |
| `OnChangedItem` | [`GetOnChangedItems`](https://learn.microsoft.com/connectors/sharepointonline/#when-an-item-or-a-file-is-modified) | Item or file modified, not created |
| `OnDeletedItem` | [`GetOnDeletedItems`](https://learn.microsoft.com/connectors/sharepointonline/#when-an-item-is-deleted) | Item deleted (opt-in) |
| `OnDeletedFile` | [`GetOnDeletedFileItems`](https://learn.microsoft.com/connectors/sharepointonline/#when-a-file-is-deleted) | File deleted (opt-in) |
| `OnFormSubmitted` | [`GetOnNewItemsFromForm`](https://learn.microsoft.com/connectors/sharepointonline/#when-a-form-is-submitted-(preview)) | Form submitted (preview, opt-in) |
| `OnFileClassified` | [`GetOnUpdatedFileClassifiedTimes`](https://learn.microsoft.com/connectors/sharepointonline/#when-a-file-is-classified-by-a-microsoft-syntex-model) | Microsoft Syntex classification (opt-in) |
| `OnRecurringDigest` | [`GetOnRecurrenceDigest`](https://learn.microsoft.com/connectors/sharepointonline/#recurring-digest-of-updates-(preview)) | Recurring digest (preview, opt-in) |

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later
- PowerShell 7.3 or later (.NET 7+) for the default hook, or Bash and `jq` for the alternative script
- For local runs: [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local), [Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite), and a public HTTPS tunnel such as [dev tunnels](https://learn.microsoft.com/azure/developer/dev-tunnels/get-started)
- A SharePoint site and library, and permission to authorize the connection
- [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli):

  ```bash
  curl -fsSL https://aka.ms/connector-namespace-cli-install | sh
  ```

  Or in PowerShell:

  ```powershell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

## Deploy to Azure

1. Open `sharepointApp/webhook`, sign in, and select a separate environment.

   ```bash
   az login
   azd auth login
   azd env new sharepoint-webhook
   ```

2. Set the source and any optional configuration below, then deploy.

   ```bash
   azd env set SHAREPOINT_SITE_URL https://contoso.sharepoint.com/sites/mysite
   azd up
   ```

3. Complete SharePoint OAuth consent when the hook opens the browser; it returns to https://connectors.azure.com. The hook creates selected webhook configurations and waits up to five minutes for **Connected**.

Deployment provisions a Flex Consumption app, managed identity, runtime/deployment storage, monitoring, Connector Namespace, and connection.

## Optional configuration

Set deployment options with `azd env set <setting> <value>` before `azd up`. Five create/update triggers are enabled by default.

| Setting | Default / purpose |
| --- | --- |
| `AZURE_LOCATION` | Selected by `azd`; use a region supporting Flex Consumption |
| `CONNECTOR_NAMESPACE_LOCATION` | `westcentralus`; Connector Namespace region, independent of the app region |
| `SHAREPOINT_LIBRARY_NAME` | `Documents`; library name or GUID |
| `SHAREPOINT_FOLDER_PATH` | Empty; optional file/digest filter |
| `SHAREPOINT_LIST_NAME` | Library if empty; item/form triggers monitor the whole list without the folder filter |
| `SHAREPOINT_ENABLE_DELETION_TRIGGERS` | `false`; item/file deletion requires the connection user to be a site collection administrator |
| `SHAREPOINT_ENABLE_SYNTEX_TRIGGER` | `false`; classification requires a licensed Syntex model applied to the library |
| `SHAREPOINT_FORM_ID` | Empty; enables submissions from an existing supported form on the list/library |
| `SHAREPOINT_DIGEST_SCHEDULE` | Empty; enables a digest of new/updated files, `*` for daily or `0` through `6` for a day of the week |

| Hook option | Direct invocation from this folder |
| --- | --- |
| Configure deployed callbacks | `pwsh -File ./infra/scripts/postdeploy.ps1` or `bash ./infra/scripts/postdeploy.sh` |
| Configure local callbacks (PowerShell only) | `pwsh -File ./infra/scripts/postdeploy.ps1 -CallbackBaseUrl https://<tunnel-host> -ConnectorExtensionKey '<local-system-key>'` |

The default `azd` hook uses PowerShell; to use Bash, set `shell: sh` and `run: ./infra/scripts/postdeploy.sh` in `azure.yaml`. Neither script has a skip-consent option. An already **Connected** connection skips the consent browser and wait, but normal setup, including callback replacement, still runs. The Bash script configures deployed callbacks only.

Hooks update existing registrations without deleting them as an update fallback.

To disable optional triggers, reset flags to `false` or clear the form ID/schedule and rerun `azd up`. Both functions and existing trigger configurations follow that selection. For local use, match the `AzureWebJobs.<FunctionName>.Disabled` flags in local settings to your selection.

## Run locally

Local callback configuration replaces the selected environment's deployed callbacks. Use a separate environment to avoid disrupting Azure delivery.

1. Prepare `local.settings.json`.

   This sample's existing hook does not generate local settings. Copy the example once, then match the `AzureWebJobs.<FunctionName>.Disabled` flags to the selected triggers; do not overwrite an existing settings file.

   ```powershell
   if (-not (Test-Path local.settings.json)) {
       Copy-Item local.settings.example.json local.settings.json
   }
   ```

   Keep the Azurite setting and omit deployed managed-identity settings locally.

2. Sign in and start Azurite in a separate terminal.

   ```bash
   az login
   azurite
   ```

3. Start the local host with authentication enabled.

   ```bash
   func start --enableAuth
   ```

   Core Tools v4 bypasses local key authentication by default. Use `--enableAuth` before exposing the host through a public tunnel so callback requests must present the system key.

4. Expose port 7071 through a public HTTPS tunnel in another terminal, for example:

   ```bash
   devtunnel host -p 7071 --allow-anonymous
   ```

   Obtain the **local** `connector_extension` system key generated by Core Tools from its local host secrets (not the Azure Function App key or a function key). Keep it private. The tunnel must allow Connector Namespace requests; the callback is authenticated with this key.

5. Replace callbacks using the tunnel URL and local system key from this folder.

   ```powershell
   pwsh -File ./infra/scripts/postdeploy.ps1 `
       -CallbackBaseUrl https://<tunnel-host> `
       -ConnectorExtensionKey '<local-system-key>'
   ```

6. Restore deployed callbacks before shutting down the local host and tunnel.

   ```bash
   azd hooks run postdeploy
   ```

   Run without callback overrides; the hook obtains the Azure `connector_extension` key and replaces callbacks with the deployed hostname.

Worker telemetry uses the `ConnectorNamespace` identity settings: the Function App's system-assigned managed identity in Azure, or standard developer credentials when identity settings are absent locally. Worker export requires `APPLICATIONINSIGHTS_CONNECTION_STRING`.

## Verify

Check the connection is **Connected** and selected triggers are **Enabled** in [Connector Namespaces](https://connectors.azure.com/). Create then modify a file or item and look for `Received <FunctionName> trigger` in function logs. Allow time for source polling. Optional triggers require their corresponding source action and prerequisites.

Delivery is at least once, so production handlers should be idempotent; this sample only logs event counts and does not process file contents.

To remove the Azure resources from this folder:

```bash
azd down --purge
```

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [SharePoint Online connector reference](https://learn.microsoft.com/connectors/sharepointonline/)
