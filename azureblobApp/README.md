# Azure Blob Storage Trigger (.NET)

Azure Functions sample app demonstrating the **Azure Blob Storage** connector trigger using the
[Azure.Connectors.Sdk](https://www.nuget.org/packages/Azure.Connectors.Sdk) and the
[Microsoft.Azure.Functions.Worker.Extensions.Connector](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector) worker extension.

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnUpdatedFile` | [`OnUpdatedFiles_V2`](https://learn.microsoft.com/en-us/connectors/azureblob/#when-a-blob-is-added-or-modified-(properties-only)-(v2)) | Fires when a blob is added or modified in the configured container |

## Prerequisites

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli) ≥ 2.75.0
- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [`connector-namespace` Azure CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli) — install with:

  ```bash
  # Bash
  curl -fsSL https://aka.ms/connector-namespace-cli-install | sh
  ```

  or

  ```pwsh
  # PowerShell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

## Deploy to Azure

```bash
cd azureblobApp
azd auth login
az login
azd up
```

### Resources provisioned

| Resource | Purpose |
| --- | --- |
| **Resource Group** | Contains all resources |
| **Flex Consumption Function App** (.NET 10 isolated) | Hosts the connector trigger function |
| **App Service Plan** (FC1) | Flex Consumption plan |
| **User-Assigned Managed Identity** | Identity for the function app |
| **Storage Account** (function app) | Deployment artifacts and function runtime state |
| **Storage Account** (monitored) | Blob storage monitored by the trigger, with a `connector-input` container |
| **Log Analytics Workspace** | Backing store for Application Insights |
| **Application Insights** | Telemetry and logging |
| **Connector Namespace** | Hosts the Azure Blob connection and trigger config |
| **Azure Blob Connection** (Managed Identity auth) | Connects to the monitored storage account using the Connector Namespace's system MI |
| **Storage Blob Data Reader** role assignment | Grants the Connector Namespace MI read access to the monitored storage account |

The Azure Blob connection uses **Managed Identity** authentication — no storage keys or OAuth consent required. The connection is immediately `Ready` after provisioning.

After provisioning, a post-deploy hook creates the trigger config pointing at the function app's connector webhook URL. To re-run only the trigger setup:

```bash
azd hooks run postdeploy
```

## Verify

After `azd up`, open the [Connector Namespaces portal](https://connectors.azure.com/) to verify:

- One **Connection** (Azure Blob) with status **Ready**
- One **Trigger** (`OnUpdatedFiles_V2`) in **Enabled** state

Upload a file to the `connector-input` container to fire the trigger. Tail logs with:

```bash
az functionapp log tail -g <resourceGroupName> -n <functionAppName>
```

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [Azure Blob connector reference](https://learn.microsoft.com/en-us/connectors/azureblob/)
