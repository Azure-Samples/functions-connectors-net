# Office 365 Outlook Webhook Triggers (.NET)

Azure Functions sample app demonstrating **Office 365 Outlook** connector triggers using the
[Azure.Connectors.Sdk](https://www.nuget.org/packages/Azure.Connectors.Sdk) and the
[Microsoft.Azure.Functions.Worker.Extensions.Connector](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector) worker extension.

The Connector Namespace delivers events to the function's public HTTPS callback.
This folder is a standalone sample: copy its entire contents to a new repository
without requiring any files from the parent repository.

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnNewEmail` | [`OnNewEmailV3`](https://learn.microsoft.com/connectors/office365/#when-a-new-email-arrives-(v3)) | Fires when a new email arrives |
| `OnFlaggedEmail` | [`OnFlaggedEmailV4`](https://learn.microsoft.com/connectors/office365/#when-an-email-is-flagged-(v4)) | Fires when an email is flagged |
| `OnNewMentionMeEmail` | [`OnNewMentionMeEmailV3`](https://learn.microsoft.com/connectors/office365/#when-a-new-email-mentioning-me-arrives-(v3)) | Fires when a new email mentions the authenticated user |
| `OnNewCalendarEvent` | [`CalendarGetOnNewItemsV3`](https://learn.microsoft.com/connectors/office365/#when-a-new-event-is-created-(v3)) | Fires when a new calendar event is created |
| `OnUpcomingEvent` | [`OnUpcomingEventsV3`](https://learn.microsoft.com/connectors/office365/#when-an-upcoming-event-is-starting-soon-(v3)) | Fires when an upcoming calendar event is starting soon |

> [!CAUTION]
> **Personal data.** This sample writes email/calendar content to Blob Storage for demonstration only. Restrict access to the resources to appropriate users only, and run `azd down --purge` when done.

## Prerequisites

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli) ≥ 2.75.0
- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local) and [Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite) for local development
- PowerShell 7 on Windows; Bash and `jq` on macOS/Linux. PowerShell 7 is also used by the optional local callback configuration script.
- An Office 365 mailbox with permission to authorize the connector connection
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
# Run from this folder (office365App/webhook in the sample collection).
azd auth login
az login
azd env new office365-webhook
azd up
```

### Resources provisioned

| Resource | Purpose |
| --- | --- |
| **Resource Group** | Contains all resources |
| **Flex Consumption Function App** (.NET 10 isolated) | Hosts the 5 connector trigger functions |
| **App Service Plan** (FC1) | Flex Consumption plan |
| **User-Assigned Managed Identity** | Identity for the function app |
| **Storage Account** | Deployment artifacts, function runtime state, and trigger payload output |
| **Log Analytics Workspace** | Backing store for Application Insights |
| **Application Insights** | Telemetry and logging |
| **Connector Namespace** | Hosts the Office 365 connection and trigger configs |
| **Office 365 Outlook Connection** (OAuth) | Authenticates to Office 365 — requires interactive consent during post-deploy |

After provisioning, a post-deploy hook authorizes the Office 365 connection and creates trigger configs. To re-run:

```bash
azd hooks run postdeploy
```

### Trigger configuration

The post-deploy script configures all five triggers. `OnNewEmail` uses these defaults:

| Setting | Value |
| ------- | ----- |
| `operationName` | `OnNewEmailV3` |
| `folderPath` | `Inbox` |
| `importance` | `High` |

Edit `infra/scripts/postdeploy.ps1` (Windows) or `.sh` (macOS/Linux) to change folder,
importance, or calendar parameters. Use different azd environment names for webhook
and polling deployments so their resources and trigger configurations do not overlap.

## Run locally

First deploy and authorize the connection as above. From this folder:

```bash
cp local.settings.example.json local.settings.json
dotnet build
func start --enableAuth
```

In PowerShell, use `Copy-Item local.settings.example.json local.settings.json`.
Start Azurite separately before starting the function host. Output is written to
the emulator's `connector-messages` container.

Receiving real webhook events locally requires a public HTTPS tunnel to port 7071.
Retrieve the local host's `connector_extension` system key from the
`azure-webjobs-secrets` container in Azurite (for example, using Azure Storage
Explorer), then configure the callbacks in a second terminal from this folder:

```powershell
./infra/scripts/postdeploy.ps1 `
  -CallbackBaseUrl 'https://<your-tunnel-host>' `
  -ConnectorExtensionKey '<local-connector_extension-key>'
```

This redirects all five deployed trigger configurations to the local host. Do not
commit the key or callback URL. Run `azd hooks run postdeploy` to restore delivery
to the Azure deployment when finished. Local and Azure delivery are not simultaneous.

## Verify

After `azd up`, open the [Connector Namespaces portal](https://connectors.azure.com/) to verify:

- One **Connection** (Office 365 Outlook) with status **Connected**
- Trigger configs in **Enabled** state

Send yourself a high-importance email to fire the trigger. Tail logs with:

```bash
az functionapp log tail -g <resourceGroupName> -n <functionAppName>
```

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [Office 365 Outlook connector reference](https://learn.microsoft.com/connectors/office365/)
- [Built-in auth sample](https://github.com/Azure-Samples/functions-connectors-net-builtinauth) — secretless authentication using managed identity + Easy Auth.

## Clean up

Run `azd down --purge` from this folder to remove this sample's Azure resources.
