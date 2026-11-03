# SharePoint Online Polling Triggers (.NET)

Azure Functions sample using [Azure.Connectors.Sdk](https://www.nuget.org/packages/Azure.Connectors.Sdk) and the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector) with `DeliveryMode = Poll`. The host receives events outbound from the Connector Namespace; no public callback or tunnel is required. All handlers use typed payloads and log only the trigger name and item count.

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
- For local runs: [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local) and [Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite)
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

1. Open `sharepointApp/polling`, sign in, and select a separate environment.

   ```bash
   az login
   azd auth login
   azd env new sharepoint-polling
   ```

2. Set the source and any optional configuration below, then deploy.

   ```bash
   azd env set SHAREPOINT_SITE_URL https://contoso.sharepoint.com/sites/mysite
   azd up
   ```

3. Complete SharePoint OAuth consent when the hook opens the browser; it returns to https://connectors.azure.com. The hook creates ignored `local.settings.json`, preserves an existing file, and waits up to five minutes for **Connected**.

Deployment provisions a Flex Consumption app, managed identity, runtime/deployment storage, monitoring, Connector Namespace, connection, and selected Poll triggers.

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
| Rerun setup | `pwsh -File ./infra/scripts/postdeploy.ps1` or `bash ./infra/scripts/postdeploy.sh` |
| Replace existing local settings | `pwsh -File ./infra/scripts/postdeploy.ps1 -ForceLocalSettings` or `bash ./infra/scripts/postdeploy.sh --force-local-settings` |

The default `azd` hook uses PowerShell; to use Bash, set `shell: sh` and `run: ./infra/scripts/postdeploy.sh` in `azure.yaml`. Neither script has a skip-consent option. An already **Connected** connection skips the consent browser and wait, but normal trigger setup and local-settings preparation still run.

To disable optional triggers, reset flags to `false` or clear the form ID/schedule and rerun `azd up`. Functions and existing trigger configurations follow that selection. Regenerate local settings to apply it locally.

Hooks preserve existing local settings unless the force option is selected, and reject directories and links at the settings path.

## Run locally

If the Function App is already deployed, stop it before running locally to avoid competing listeners.

1. Prepare `local.settings.json`.

   Use the settings generated after successful `azd up`. Only if the file is missing, rerun the existing hook from this folder:

   ```bash
   azd hooks run postdeploy
   ```

   The generated file uses Azurite, developer credentials, the actual polling endpoint, trigger names, and disabled-function flags. Do not add deployed managed-identity settings locally.

2. Sign in with an identity granted access to the connection and start Azurite in a separate terminal.

   ```bash
   az login
   azurite
   ```

3. Start the local function host from this folder.

   ```bash
   func start
   ```

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
