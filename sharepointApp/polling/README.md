<!--
---
name: "Azure Functions Connector Samples (.NET): SharePoint Online polling"
description: Receive SharePoint Online connector events with polling in a .NET Azure Functions app deployed using Azure Developer CLI (azd).
page_type: sample
languages:
- csharp
- bicep
- azdeveloper
products:
- azure
- azure-functions
urlFragment: functions-connectors-sharepoint-polling-dotnet
---
-->

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
- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) 1.33.0+
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later, signed in with permission to read and write trigger configurations in the Connector Namespace; polling state updates use `az rest`
- PowerShell 7 on Windows or `sh` on POSIX; a terminal and writable temporary directory for setup
- For local runs: [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local) and [Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite)
- A SharePoint site and library, and permission to authorize the connection
- [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli) version 1.0.0b33. The deployment scripts use it automatically for sign-in and source pickers:

  ```bash
  curl -fsSL https://aka.ms/connector-namespace-cli-install | sh
  ```

  Or in PowerShell:

  ```powershell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

## Deploy to Azure

`azd up` provisions the Azure resources, helps you set up triggers, and deploys the Function App.

1. Open `sharepointApp/polling`, sign in, and select a separate environment.

   ```cmd
   az login
   azd auth login
   azd env new sharepoint-polling
   ```

2. Deploy and choose source inputs interactively.

   ```cmd
   azd up
   ```

3. Complete SharePoint OAuth in the browser, then choose Configure/Skip for each function. Choose at least one. Setup checks Azure's Connected status even if a sign-in window remains stale. Connector metadata drives the site, list/library and folder pickers and any required form/digest inputs. An empty list picker offers manual entry of an exact connector identifier or skipping that trigger.

Only selected triggers are enabled. The available triggers are listed in `infra/scripts/polling-config.json`.

## Optional configuration

Set deployment options with `azd env set <setting> <value>` before `azd up`. Only explicitly selected triggers are enabled.

| Setting | Default / purpose |
| --- | --- |
| `AZURE_LOCATION` | Selected by `azd`; use a region supporting Flex Consumption |
| `CONNECTOR_NAMESPACE_LOCATION` | `westcentralus`; Connector Namespace region, independent of the app region |

Deletion triggers require the connection user to be a site collection administrator. Classification requires a licensed Syntex model applied to the library. Form submissions require an existing supported form. Digest scheduling and form subscriptions are preview operations; provide the exact values accepted by connector metadata. Item/form subscriptions monitor the selected list, not a file-folder filter. Do not select operations whose source prerequisites you cannot satisfy.

Selections are saved in the active azd environment's `POLLING_TRIGGER_INPUTS` and reused. These settings are not encrypted; keep `.azure` out of source control. To choose again, run `azd env set POLLING_TRIGGER_INPUTS ""` and `azd up`. Skipped owned configurations and listeners are disabled; absent skipped configurations stay absent. Reselecting enables the same deterministic configuration. Disabling does not tear down upstream subscriptions or remove queued events.

Setup refuses configurations with missing or conflicting destination ownership metadata. Use a fresh sample environment for older configurations without that metadata. If sign-in or trigger setup fails, correct the issue and rerun `azd up`. Resources already provisioned remain available.

Deployment creates ignored `local.settings.json` only if missing. Existing files are preserved byte-for-byte; reconcile their listener switches manually or deliberately archive the file before regenerating.

## Run locally

If the Function App is already deployed, stop it before running locally to avoid competing listeners.

1. Prepare `local.settings.json`.

   Use the settings generated after successful `azd up`. Only if the file is missing, run from this folder:

   ```cmd
   dotnet run --file ./infra/scripts/PollingSetup.cs -- finish
   ```

   The generated file uses Azurite, developer credentials, the actual polling endpoint, trigger names, and disabled-function flags. Do not add deployed managed-identity settings locally. The example has disabled listeners and a placeholder endpoint, so it is not runnable.

2. Sign in with an identity granted access to the connection and start Azurite in a separate terminal.

   ```cmd
   az login
   azurite
   ```

3. Start the local function host from this folder.

   ```cmd
   func start
   ```

Worker telemetry uses the `ConnectorNamespace` identity settings: the Function App's system-assigned managed identity in Azure, or standard developer credentials when identity settings are absent locally. Worker export requires `APPLICATIONINSIGHTS_CONNECTION_STRING`.

## Verify

Check the connection is **Connected** and selected triggers are **Enabled** in [Connector Namespaces](https://connectors.azure.com/). Create then modify a file or item and look for `Received <FunctionName> trigger` in function logs. Allow time for source polling. Optional triggers require their corresponding source action and prerequisites.

Delivery is at least once, so production handlers should be idempotent; this sample only logs event counts and does not process file contents.

To remove the Azure resources from this folder:

```cmd
azd down --purge
```

## More

- [Connector trigger payloads for Azure Functions](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [SharePoint Online connector reference](https://learn.microsoft.com/connectors/sharepointonline/)
