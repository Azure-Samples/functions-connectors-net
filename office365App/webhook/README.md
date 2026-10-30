# Office 365 Outlook Webhook Triggers (.NET)

Azure Functions sample using [Azure.Connectors.Sdk](https://www.nuget.org/packages/Azure.Connectors.Sdk)
and the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector).
The Connector Namespace delivers events to the function's public HTTPS callback.
All handlers use typed payloads and log only the trigger name and item count.

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
cd office365App/webhook
az login
azd auth login
azd env new office365-webhook
azd env set OFFICE365_MAIL_FOLDER Inbox
azd env set OFFICE365_CALENDAR_ID '<actual connector calendar ID>'
azd up
```

Use the actual connector calendar ID, not the placeholder `Calendar`. Complete
the OAuth sign-in opened by `azd up` with the mailbox account to monitor.
Use a different azd environment from polling.

## Optional configuration

Set environment values before `azd up`. Six personal triggers are configured by default.

| Setting / option | Purpose |
| --- | --- |
| `OFFICE365_SHARED_MAILBOX_ADDRESS=<address>` | Shared mailbox email; full mailbox access required |
| `OFFICE365_SHARED_MAILBOX_FOLDER_ID=Inbox` | Folder to monitor in the shared mailbox |
| `CONNECTOR_NAMESPACE_LOCATION` | Namespace region; defaults to `westcentralus` |
| `APPLICATION_INSIGHTS_LOCATION=eastus2` | Telemetry region override if the host region lacks Application Insights |
| `OFFICE365_ENABLE_TRIGGERS=false` | Register disabled sources without waiting for consent; set `true` and run `azd up` to activate |
| Bash hook | In `azure.yaml`, set `shell: sh` and `run: ./infra/scripts/postdeploy.sh` |
| `-ConsentLinkOnly` / `--consent-link-only` | Print consent link without opening a browser or waiting |

Empty address disables its listener and skips registration. When disabling an
existing shared source, also disable/delete its namespace config; skipped resources
are not removed automatically. Match the local shared listener's disabled setting
to your selection.

## Local development

Copy `local.settings.example.json` to `local.settings.json`, start Azurite separately,
then `dotnet build` and `func start --enableAuth`. Functions host/deployment storage
is required. Expose port 7071 over public HTTPS and get the local
`connector_extension` system key from Azurite's `azure-webjobs-secrets`:

```bash
bash ./infra/scripts/postdeploy.sh \
  --callback-base-url 'https://<tunnel-host>' \
  --connector-extension-key '<local-key>'
```

PowerShell supports equivalent `-CallbackBaseUrl` / `-ConnectorExtensionKey` options.
These replace deployed callbacks; run `azd hooks run postdeploy` without overrides
to restore Azure delivery. Enable the local shared listener only when configured.
Never commit keys, callback URLs, or local settings.

## Verify

Check the connection is **Connected** and selected triggers are **Enabled** in
[Connector Namespaces](https://connectors.azure.com/). Generate mail/calendar events
and check worker logs for `Received <FunctionName> trigger (<Count> items)`;
build/deployment success alone is not real-event verification. Delivery is at least
once and source detection may be delayed.

Run `azd down --purge` when finished. Licensing is provided by the repository's
[root LICENSE](../../LICENSE).

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [Office 365 Outlook connector reference](https://learn.microsoft.com/connectors/office365/)
