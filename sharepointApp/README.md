# SharePoint Online Triggers (.NET)

Azure Functions sample app demonstrating **SharePoint Online** connector triggers using the
[Azure.Connectors.Sdk](https://www.nuget.org/packages/Azure.Connectors.Sdk) and the
[Microsoft.Azure.Functions.Worker.Extensions.Connector](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector) worker extension.

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnNewFile` | [`GetOnNewFileItems`](https://learn.microsoft.com/connectors/sharepointonline/#when-a-file-is-created-(properties-only)) | Fires when a new file is created in a SharePoint library |
| `OnUpdatedFile` | [`GetOnUpdatedFileItems`](https://learn.microsoft.com/connectors/sharepointonline/#when-a-file-is-created-or-modified-(properties-only)) | Fires when a file is modified in a SharePoint library |

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
cd sharepointApp
azd auth login
az login
azd up
```

### Resources provisioned

| Resource | Purpose |
| --- | --- |
| **Resource Group** | Contains all resources |
| **Flex Consumption Function App** (.NET 10 isolated) | Hosts the connector trigger functions |
| **App Service Plan** (FC1) | Flex Consumption plan |
| **User-Assigned Managed Identity** | Identity for the function app |
| **Storage Account** | Deployment artifacts and function runtime state |
| **Log Analytics Workspace** | Backing store for Application Insights |
| **Application Insights** | Telemetry and logging |
| **Connector Namespace** | Hosts the SharePoint connection and trigger configs |
| **SharePoint Online Connection** (OAuth) | Authenticates to SharePoint — requires interactive consent during post-deploy |

After provisioning, a post-deploy hook authorizes the SharePoint connection and creates trigger configs. To re-run:

```bash
azd hooks run postdeploy
```

## Verify

After `azd up`, open the [Connector Namespaces portal](https://connectors.azure.com/) to verify:

- One **Connection** (SharePoint Online) with status **Connected**
- Trigger configs in **Enabled** state

Create or modify a file in the configured SharePoint library to fire the trigger. Tail logs with:

```bash
az functionapp log tail -g <resourceGroupName> -n <functionAppName>
```

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [SharePoint Online connector reference](https://learn.microsoft.com/connectors/sharepointonline/)
