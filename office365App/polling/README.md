# Office 365 Outlook Polling Triggers (.NET)

Azure Functions sample using the same connector trigger as webhook delivery, with
`DeliveryMode = Poll`. The function host connects outbound to a Connector Namespace
to receive and acknowledge events. No public callback, function system key, or
development tunnel is needed.

This folder is a standalone sample. Copy its entire contents into a new repository
to build, run, and deploy it without any files from the parent repository.

| Function | Connector operation | Default source parameters |
| --- | --- | --- |
| `OnNewEmail` | `OnNewEmailV3` | Inbox; high importance |
| `OnFlaggedEmail` | `OnFlaggedEmailV4` | Inbox |
| `OnNewMentionMeEmail` | `OnNewMentionMeEmailV3` | Inbox |
| `OnNewCalendarEvent` | `CalendarGetOnNewItemsV3` | Calendar |
| `OnUpcomingEvent` | `OnUpcomingEventsV3` | Calendar |

Each function receives a typed Office 365 payload and uses a Blob output binding
to write its JSON to a separate, randomly named blob in `connector-messages`,
matching the webhook sample's output. This sample does not enable batched invocation.

> [!CAUTION]
> **Personal data.** Email/calendar payloads are written to Blob Storage for demonstration.
> Restrict access to the sample resources and run `azd down --purge` when finished.
> Delivery is at least once: a retry can create another blob for the same event.
> Production applications should use idempotent processing. This sample binds
> directly to the payload and does not expose the Poll delivery `MessageId`.

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local)
- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later
- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) on all platforms for the post-deploy hook
- [Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite) for local runtime storage and Blob output
- An Office 365 mailbox and permission to authorize its connector connection
- The [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli):

  ```bash
  curl -fsSL https://aka.ms/connector-namespace-cli-install | sh
  ```

  Or in PowerShell:

  ```powershell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

The folder's `NuGet.config` supplies the public Azure Functions package feed for
the preview connector packages; no parent-level NuGet configuration or local
extension checkout is needed.

## Deploy to Azure

Run from this folder (`office365App/polling` in the sample collection):

```bash
az login
azd auth login
azd env new office365-polling
azd up
```

Use a different environment name from any webhook deployment. To change the source
folder or calendar before provisioning:

```bash
azd env set OFFICE365_MAIL_FOLDER Inbox
azd env set OFFICE365_CALENDAR_ID Calendar
```

Use the folder/calendar identifiers accepted by the Office 365 connector for your
mailbox. Trigger definitions and additional filters are in `infra/poll-triggers.bicep`.
The Connector Namespace defaults to `westcentralus`; override its region with
`azd env set CONNECTOR_NAMESPACE_LOCATION <supported-region>`.

Bicep provisions a resource group, Flex Consumption .NET 10 Function App, managed
identity, storage account, Application Insights/Log Analytics, Connector Namespace,
Office 365 connection, and five enabled `deliveryMode: 'Poll'` trigger configurations.
It grants connection access separately to the namespace identity, Function App
identity, and developer identity.

The post-deploy hook opens the OAuth consent flow for the mailbox and creates an
ignored `local.settings.json` if one does not already exist. It preserves existing
local settings. To re-run consent/setup:

```bash
azd hooks run postdeploy
```

## Run locally

There is no local emulator for the Connector Namespace or Office 365 connection.
Local development uses real Azure resources plus Azurite for Functions storage.

You can use resources from `azd up`, or provision them without deploying function code:

```bash
az login
azd auth login
azd env new office365-polling-local
azd provision
pwsh -File ./infra/scripts/postdeploy.ps1
```

The script creates `local.settings.json` with the deployed endpoint and all five
trigger-config names. To intentionally replace existing local settings:

```bash
pwsh -File ./infra/scripts/postdeploy.ps1 -ForceLocalSettings
```

Start Azurite separately, then run from this folder:

```bash
dotnet build
func start
```

The signed-in developer identity is used locally. Do not copy Azure's
`ConnectorNamespace__credential=managedidentity` or `__clientId` settings into local
settings. Bicep grants the provisioning developer access to the Office 365 connection;
a different developer needs their own connection-level access policy.

Do not run local and deployed listeners against the same trigger configuration
when expecting every event locally: they are competing consumers. Use a separate
environment provisioned without function code for isolated local testing.

### Existing namespace

Alternatively, copy `local.settings.example.json` to ignored `local.settings.json`
and supply your existing authorized connection's Poll settings. Each binding uses:

```csharp
[ConnectorTrigger(
    DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
    Connection = "ConnectorNamespace",
    TriggerConfigName = "%OnNewEmailTriggerConfigName%")]
```

`Connection` is a configuration prefix, not the Office 365 connection resource name.
Derive `ConnectorNamespace__pollingEndpoint` from the service-generated
`pollingEndpoints.receiveUri`:

| Receive URI | Setting |
| --- | --- |
| `https://<host>/api/triggerconfigs/<name>/receive` | `https://<host>` |
| `https://<host>/api/connectorGateways/<id>/triggerconfigs/<name>/receive` | `https://<host>/api/connectorGateways/<id>` |

Do not include an operation path or query string. Set each `*TriggerConfigName`
separately and grant both the namespace and developer identities access to the
connection. Never commit real endpoints, credentials, or local settings.

## Verify and clean up

After connection consent, send a high-importance email to the monitored Inbox,
flag an email, send an email mentioning the mailbox user, or create a calendar
event. An upcoming event fires when it enters the connector's look-ahead window.
Allow time for the connector to detect the source change.

Check function logs for the corresponding trigger, then inspect
the `connector-messages` Blob container: in Azurite for local runs, or the deployed
storage account for Azure runs. No email content is written to application logs.

Run `azd down --purge` from this folder to delete this environment's Azure resources.

## References

- [Connector extension Poll samples](https://github.com/Azure/azure-functions-connector-extension/tree/main/test/poll)
- [SharePoint-to-Cosmos Poll sample](https://github.com/manvkaur/functions-connectors-net-sharepoint-cosmos)
- [Connector trigger configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md)
- [Office 365 connector reference](https://learn.microsoft.com/connectors/office365/)
