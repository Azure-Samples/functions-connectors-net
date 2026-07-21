# Microsoft Teams Triggers (.NET)

Azure Functions sample app demonstrating **Microsoft Teams** connector triggers using the
[Azure.Connectors.Sdk](https://www.nuget.org/packages/Azure.Connectors.Sdk) and the
[Microsoft.Azure.Functions.Worker.Extensions.Connector](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector) worker extension.

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnNewChannelMessage` | [`OnNewChannelMessage`](https://learn.microsoft.com/connectors/teams/#when-a-new-channel-message-is-added) | Fires when a new message is posted in a Teams channel |
| `OnNewChannelMessageMentioningMe` | [`OnNewChannelMessageMentioningMe`](https://learn.microsoft.com/connectors/teams/#when-i-am-mentioned-in-a-channel-message) | Fires when a new message mentions the authenticated user |
| `OnGroupMembershipAdd` | [`OnGroupMembershipAdd`](https://learn.microsoft.com/connectors/teams/#when-a-team-member-is-added) | Fires when a member is added to a Teams group |
| `OnGroupMembershipRemoval` | [`OnGroupMembershipRemoval`](https://learn.microsoft.com/connectors/teams/#when-a-team-member-is-removed) | Fires when a member is removed from a Teams group |

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
cd teamsApp
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
| **Storage Account** | Deployment artifacts, function runtime state, and trigger payload output (`connector-messages` container) |
| **Log Analytics Workspace** | Backing store for Application Insights |
| **Application Insights** | Telemetry and logging |
| **Connector Namespace** | Hosts the Teams connection and trigger configs |
| **Teams Connection** (OAuth) | Authenticates to Microsoft Teams — requires interactive consent during post-deploy |

After provisioning, a post-deploy hook authorizes the Teams connection and creates trigger configs. To re-run:

```bash
azd hooks run postdeploy
```

## Verify

After `azd up`, open the [Connector Namespaces portal](https://connectors.azure.com/) to verify:

- One **Connection** (Teams) with status **Connected**
- Trigger configs in **Enabled** state

Post a message in the configured Teams channel to fire the trigger. Tail logs with:

```bash
az functionapp log tail -g <resourceGroupName> -n <functionAppName>
```

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [Teams connector reference](https://learn.microsoft.com/connectors/teams/)
