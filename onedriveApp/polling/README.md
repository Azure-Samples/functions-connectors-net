# OneDrive for Business Polling Triggers (.NET)

Azure Functions sample using [Azure.Connectors.Sdk](https://www.nuget.org/packages/Azure.Connectors.Sdk) and the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector) with `DeliveryMode = Poll`. The host receives events outbound from the Connector Namespace; no public callback or tunnel is required. Each function logs the trigger name and, for typed batches, the item count (for example, `Received OnNewFile trigger (2 items)`).

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnNewFileContent` | [`OnNewFileV2`](https://learn.microsoft.com/connectors/onedriveforbusiness/#when-a-file-is-created) | File created, including content |
| `OnUpdatedFileContent` | [`OnUpdatedFileV2`](https://learn.microsoft.com/connectors/onedriveforbusiness/#when-a-file-is-modified) | File modified, including content |
| `OnNewFile` | [`OnNewFilesV2`](https://learn.microsoft.com/connectors/onedriveforbusiness/#when-a-file-is-created-(properties-only)) | File created (properties only) |
| `OnUpdatedFile` | [`OnUpdatedFilesV2`](https://learn.microsoft.com/connectors/onedriveforbusiness/#when-a-file-is-modified-(properties-only)) | File modified (properties only) |

Properties-only events use typed SDK models. The SDK has no payload models for the binary-content events (`type: string, format: binary` upstream); those bind raw JSON as `string` and log only the trigger name, without parsing for a count. No item metadata, file content, or payload length is logged.

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download), [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75+, and [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) 1.33.0+.
- PowerShell 7 on Windows or `sh` on POSIX; a terminal and writable temporary directory for setup.
- For local development: [Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local) and [Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite).
- A OneDrive for Business account and permission to complete OAuth consent.
- [Connector Namespace CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli) version 1.0.0b33. The deployment scripts use it automatically for sign-in and source pickers:

  ```powershell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

  Bash: `curl -fsSL https://aka.ms/connector-namespace-cli-install | sh`.

## Deploy to Azure

`azd up` provisions the Azure resources, helps you set up triggers, and deploys the Function App.

Run from this folder, using a unique environment name:

```cmd
az login
azd auth login
azd env new onedrive-polling
azd up
```

Complete browser sign-in, choose at least one trigger, and browse to the folder to monitor when prompted. Only selected triggers are enabled. Setup confirms Azure reports Connected even if a sign-in window remains stale.

The catalog is `infra/scripts/polling-config.json`. The folder browser shows connector-returned folders, supports nested browsing and parent navigation, and applies the selected real folder ID to selected triggers. It excludes the literal `root`, which fails trigger evaluation with `Invalid fileId`. No `ONEDRIVE_FOLDER_ID`, temporary bootstrap namespace or manual ID lookup is needed.

## Optional configuration

Set environment values with `azd env set <setting> <value>` before `azd up`.

| Setting / action | Use |
| --- | --- |
| `CONNECTOR_NAMESPACE_LOCATION` | Namespace region; default `westcentralus` |
| `TELEMETRY_LOCATION` | Application Insights/Log Analytics region; default `eastus2` because Application Insights is unavailable in `westcentralus` |

Selections are saved in the active azd environment's `POLLING_TRIGGER_INPUTS` and reused. These settings are not encrypted; keep `.azure` out of source control. To choose triggers or a folder again, run `azd env set POLLING_TRIGGER_INPUTS ""` and `azd up`. Skipped owned configurations and listeners are disabled; never-created skipped configurations stay absent. Setup refuses missing or conflicting destination ownership metadata; use a fresh environment for older deployments without it.

If sign-in or trigger setup fails, correct the issue and rerun `azd up`. Resources already provisioned remain available.

## Local development

Requires real Azure connector resources.

If the Function App is already deployed, stop it before running locally to avoid competing listeners.

1. Prepare `local.settings.json`.

   Use the ignored file generated during `azd up`, containing the endpoint and four config names. Sign in as the authorized developer:

   ```cmd
   az login
   ```

   Only if the file is missing, run `dotnet run --file ./infra/scripts/PollingSetup.cs -- finish` from this folder's selected environment. Existing files are preserved byte-for-byte; manually reconcile their listener switches or deliberately archive them before regenerating. The example has disabled listeners and a placeholder endpoint, so it is not runnable.

2. Start Azurite in a separate terminal:

   ```cmd
   azurite
   ```

3. Build and start the local host:

   ```cmd
   dotnet build
   func start
   ```

Use developer credentials locally, not deployed managed-identity settings. Worker telemetry uses the `ConnectorNamespace` identity settings independently of the connector host. Azure deployments use the Function App's system-assigned identity for storage, polling, and telemetry. An incremental redeployment does not delete a previous user-assigned identity or its role assignments; remove them only after verifying system-assigned access.

## Verify

Check the connection is **Connected** and selected triggers are **Enabled** in [Connector Namespaces](https://connectors.azure.com/). Create a file smaller than 50 MB and then modify it in the monitored folder. Expect receipts only from selected functions. Allow time for connector detection and telemetry ingestion. In the deployed Application Insights resource, open **Logs** and run this query:

```kusto
traces
| where timestamp > ago(1h)
| where message startswith "Received On"
| project timestamp, message, cloud_RoleInstance
| order by timestamp asc
```

See [Application Insights queries](https://learn.microsoft.com/azure/azure-functions/analyze-telemetry-data). After verification, clean up from this sample's selected environment:

```cmd
azd down --purge
```

Delivery is at least once; moving a file within OneDrive does not create a new-file event.

## More

- [Poll configuration and identity/endpoint setup](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md#poll-delivery)
- [Connector trigger payloads for Azure Functions](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md#onedrive-for-business-connector)
- [OneDrive for Business connector reference](https://learn.microsoft.com/connectors/onedriveforbusiness/)
