# Azure Blob Storage Polling Triggers (.NET)

Azure Functions sample using [Azure.Connectors.Sdk](https://www.nuget.org/packages/Azure.Connectors.Sdk) and the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector) with `DeliveryMode = Poll`. The host receives events outbound from the Connector Namespace; no public callback or tunnel is required. The handler uses `AzureBlobOnUpdatedFilesTriggerPayload` and logs only the trigger name and item count.

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnUpdatedFile` | [`OnUpdatedFiles_V2`](https://learn.microsoft.com/connectors/azureblob/#when-a-blob-is-added-or-modified-(properties-only)-(v2)) | Blob added or modified (properties only) |

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) 1.33.0+
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later
- PowerShell 7 on Windows, or `sh` on POSIX; a terminal and writable temporary directory for setup
- Azure permissions to deploy resources and role assignments
- For local execution: Functions Core Tools v4 supporting .NET 10 and Azurite.
- [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli):

  ```bash
  curl -fsSL https://aka.ms/connector-namespace-cli-install | sh
  ```

  Or in PowerShell:

  ```powershell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

## Deploy to Azure

`azd up` provisions the Azure resources, helps you set up triggers, and deploys the Function App.

Run from this folder, using a unique environment name:

```cmd
az login
azd auth login
azd env new azureblob-polling
azd up
```

The source connection uses the **Connector Namespace's system-assigned managed identity**; no OAuth consent is required. Deployment grants it **Storage Blob Data Reader** on the monitored account and a connection access policy. The Function App uses its own identity for polling; `AZURE_PRINCIPAL_ID` gets **Storage Blob Data Contributor** for test uploads and connection access for local polling.

Deployment creates the monitored storage account and container and prompts you to configure `OnUpdatedFile`. Select this trigger to enable it. The monitored account and container are selected automatically. The available trigger is listed in `infra/scripts/polling-config.json`.

Setup checks `managedIdentityAuth` and waits up to five minutes for **Ready** or **Connected**, without starting browser authentication. Readiness does not prove source access: verify the namespace identity's source role and connection access policy, and allow time for RBAC propagation if source polling reports authorization errors. The source connection retains its `-mi` resource name.

## Optional configuration

Set environment options with `azd env set <name> <value>` before provisioning.

| Option | Use |
| --- | --- |
| `BLOB_CONTAINER_NAME` | Source container; defaults to `connector-input` |
| `CONNECTOR_NAMESPACE_LOCATION` | Namespace region; defaults to `westcentralus` |
| `APPLICATIONINSIGHTS_LOCATION` | Telemetry region override, for example `eastus2`, when the Functions region lacks Application Insights |

Choices are saved in the active azd environment's `POLLING_TRIGGER_INPUTS` and reused. These settings are not encrypted; keep `.azure` out of source control. To choose again, run `azd env set POLLING_TRIGGER_INPUTS ""` and `azd up`. Skipped owned configurations and listeners are disabled; never-created skipped resources stay absent. Setup refuses configurations with missing or conflicting destination ownership metadata. For older deployments without that metadata, use a fresh sample environment rather than deleting or adopting resources automatically.

If trigger setup fails, correct the issue and rerun `azd up`. Resources already provisioned remain available.

Deployment creates ignored `local.settings.json` only if missing. Existing files are preserved byte-for-byte; reconcile their listener switches manually or deliberately archive the file before regenerating. Worker telemetry uses the `ConnectorNamespace` identity settings independently of the connector host: developer credentials locally, the Function App's system-assigned identity in Azure.

## Local development

If the Function App is already deployed, stop it before running locally to avoid competing listeners.

1. Prepare `local.settings.json`.

   Use the file generated during successful `azd up`; existing files are preserved. If missing, run `dotnet run --file ./infra/scripts/PollingSetup.cs -- finish` in the selected environment. The example has a placeholder endpoint and disabled listener, so it is not runnable. Sign in for local developer credentials:

   ```cmd
   az login
   ```

2. Start Azurite in a separate terminal:

   ```cmd
   azurite
   ```

3. Build and start the local function host:

   ```cmd
   dotnet build
   func start
   ```

Local settings use developer credentials to access the namespace. Do not copy cloud managed-identity settings locally. The source connection continues to use the namespace's managed identity, including when the function runs locally.

## Verify

Check the `-mi` connection uses **Managed Identity** and is **Ready** or **Connected**, and `azureblob-onupdatedfile` is **Enabled** in [Connector Namespaces](https://connectors.azure.com/). After provisioning and RBAC propagation, upload or modify a blob using the `monitoredStorageAccountName` and `monitoredContainerName` deployment outputs:

```cmd
az storage blob upload --auth-mode login --account-name <monitoredStorageAccountName> --container-name <monitoredContainerName> --name sample.txt --file <local-file> --overwrite
```

Look for `Received OnUpdatedFile trigger (N items)` in function logs or Application Insights. Allow time for source polling; delivery is at least once. Run `azd down --purge` from this folder to clean up.

## More

- [Connector trigger payloads for Azure Functions](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [Azure Blob Storage connector reference](https://learn.microsoft.com/connectors/azureblob/)
- [Trigger configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md)
