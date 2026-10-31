# Office 365 Outlook Polling Triggers (.NET)

Azure Functions sample using [Azure.Connectors.Sdk](https://www.nuget.org/packages/Azure.Connectors.Sdk)
and the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector)
with `DeliveryMode = Poll`. The host receives events outbound from the Connector
Namespace; no public callback or tunnel is required. All handlers use typed
payloads and log only the trigger name and item count.

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnNewEmail` | [`OnNewEmailV3`](https://learn.microsoft.com/connectors/office365/#when-a-new-email-arrives-(v3)) | New email |
| `OnFlaggedEmail` | [`OnFlaggedEmailV4`](https://learn.microsoft.com/connectors/office365/#when-an-email-is-flagged-(v4)-(preview)) | Flagged email (preview) |
| `OnNewMentionMeEmail` | [`OnNewMentionMeEmailV3`](https://learn.microsoft.com/connectors/office365/#when-a-new-email-mentioning-me-arrives-(v3)) | Email mentioning me |
| `OnNewCalendarEvent` | [`CalendarGetOnNewItemsV3`](https://learn.microsoft.com/connectors/office365/#when-a-new-event-is-created-(v3)) | New event |
| `OnCalendarUpdatedItems` | [`CalendarGetOnUpdatedItemsV3`](https://learn.microsoft.com/connectors/office365/#when-an-event-is-modified-(v3)) | Modified event |
| `OnUpcomingEvent` | [`OnUpcomingEventsV3`](https://learn.microsoft.com/connectors/office365/#when-an-upcoming-event-is-starting-soon-(v3)) | Upcoming event |
| `OnSharedMailboxNewEmail` | [`SharedMailboxOnNewEmailV2`](https://learn.microsoft.com/connectors/office365/#when-a-new-email-arrives-in-a-shared-mailbox-(v2)) | Shared mailbox email (opt-in) |
| Not included | [`CalendarGetOnChangedItemsV3`](https://learn.microsoft.com/connectors/office365/#when-an-event-is-added,-updated-or-deleted-(v3)) | Event added, updated or deleted; preview subscription fails with missing `TABLE` |

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later
- PowerShell 7 for the default hook, or Bash and `jq` for the alternative script
- An Office 365 mailbox and permission to authorize the connection
- [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local) and Azurite for local development
- [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli):

  ```bash
  curl -fsSL https://aka.ms/connector-namespace-cli-install | sh
  ```

  Or in PowerShell:

  ```powershell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

## Deploy to Azure

```bash
cd office365App/polling
az login
azd auth login
azd env new office365-polling
azd env set OFFICE365_MAIL_FOLDER Inbox
azd env set OFFICE365_CALENDAR_ID '<actual connector calendar ID>'
azd up
```

Use the actual connector calendar ID, not the placeholder `Calendar`. Complete
the OAuth sign-in opened by `azd up` with the mailbox account to monitor.
Use a different azd environment from webhook.

**Cost:** polling provisions one 2048 MB always-ready instance per configured
function (six, or seven with shared mailbox). These incur idle charges.

## Optional configuration

Set environment values before `azd up`. Six personal triggers are configured by default.

| Setting / option | Purpose |
| --- | --- |
| `OFFICE365_SHARED_MAILBOX_ADDRESS=<address>` | Shared mailbox email; full mailbox access required |
| `OFFICE365_SHARED_MAILBOX_FOLDER_ID=Inbox` | Folder to monitor in the shared mailbox |
| `CONNECTOR_NAMESPACE_LOCATION` | Namespace region; defaults to `westcentralus` |
| `APPLICATION_INSIGHTS_LOCATION=eastus2` | Telemetry region override if the host region lacks Application Insights |
| `OFFICE365_ENABLE_TRIGGERS=false` | Prepare disabled sources without waiting for consent; set `true` and reprovision to activate |
| Bash hook | In `azure.yaml`, set `shell: sh` and `run: ./infra/scripts/postdeploy.sh` |
| `pwsh ./infra/scripts/postdeploy.ps1 -ForceLocalSettings` / `bash ./infra/scripts/postdeploy.sh --force-local-settings` | Regenerate local settings; existing files are otherwise preserved |
| `pwsh ./infra/scripts/postdeploy.ps1 -ConsentLinkOnly` / `bash ./infra/scripts/postdeploy.sh --consent-link-only` | Skip browser opening and authorization wait; normal setup still runs |

Empty address disables its listener and skips registration. When disabling an
existing shared source, also disable/delete its namespace config; incremental
deployment does not remove skipped resources. Regenerate local settings to apply
the selection locally.

## Local development

If the Function App is already deployed, stop it before running locally to avoid competing listeners.

1. Prepare `local.settings.json`.

   Use the file generated during successful `azd up`. Only if it is missing, rerun:

   ```bash
   azd hooks run postdeploy
   ```

2. Sign in with your developer account for local credentials.

   ```bash
   az login
   ```

3. Start Azurite in a separate terminal.

   ```bash
   azurite
   ```

4. Build and start the local Functions host.

   ```bash
   dotnet build
   func start
   ```

Do not copy cloud managed-identity settings locally. Functions host/deployment
storage is required. Never commit local settings.

## Verify

Check the connection is **Connected** and selected triggers are **Enabled** in
[Connector Namespaces](https://connectors.azure.com/). Generate mail/calendar events
and check worker logs for `Received <FunctionName> trigger (<Count> items)`;
build/deployment success alone is not real-event verification. Delivery is at least
once and source detection may be delayed.

Run `azd down --purge` when finished, including always-ready resources. Licensing
is provided by the repository's [root LICENSE](../../LICENSE).

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [Office 365 Outlook connector reference](https://learn.microsoft.com/connectors/office365/)
