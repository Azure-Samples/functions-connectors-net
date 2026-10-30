# Office 365 Outlook Webhook Triggers (.NET)

Standalone Azure Functions sample: copy this entire folder into a new repository.
The Connector Namespace delivers events to Functions over HTTPS. Every handler
binds a strongly typed SDK payload and logs receipt without email/calendar content.
No Blob output binding is used; Functions host/deployment storage is still required.

## Events and strongly typed payloads

All payloads are from `Azure.Connectors.Sdk.Office365.Models`.

| Function | Source operation | SDK payload |
| --- | --- | --- |
| `OnNewEmail` | `OnNewEmailV3` | `Office365OnNewEmailTriggerPayload` |
| `OnFlaggedEmail` | `OnFlaggedEmailV4` | `Office365OnFlaggedEmailTriggerPayload` |
| `OnNewMentionMeEmail` | `OnNewMentionMeEmailV3` | `Office365OnNewEmailMentioningMeTriggerPayload` |
| `OnNewCalendarEvent` | `CalendarGetOnNewItemsV3` | `Office365OnCalendarNewItemsTriggerPayload` |
| `OnCalendarChangedItems` | `CalendarGetOnChangedItemsV3` | `Office365OnCalendarChangedItemsTriggerPayload` |
| `OnCalendarUpdatedItems` | `CalendarGetOnUpdatedItemsV3` | `Office365OnCalendarUpdatedItemsTriggerPayload` |
| `OnUpcomingEvent` | `OnUpcomingEventsV3` | `Office365OnUpcomingEventsTriggerPayload` |
| `OnSharedMailboxNewEmail` (opt-in) | `SharedMailboxOnNewEmailV2` | `Office365OnSharedMailboxNewEmailTriggerPayload` |

Namespace Webhook delivery is distinct from the source connector's implementation:
the eight operations above are registered with HTTPS callbacks even if their source
trigger uses polling internally.

The ninth UI event, **When a new email arrives (webhook)**, is the deprecated source
operation `CreateOnNewEmailSubscription`, not `OnNewEmailV3`. Its Swagger path-level
`x-ms-notification-content` schema is `TriggerBatchResponse[ReceiveMessageMetadata]`,
a `value` array with legacy `Id`, `DateTimeReceived`, `HasAttachment`, and integer
`Importance`. SDK `0.14.0-preview.1` and main
`1d9ce974172e97862fee81dd29682ebfc5ac50d5` lack this metadata model and typed wrapper.
The V3 Graph payload differs in wire names and importance type; the subscription's
201 `SubscriptionResponse` is not its notification payload. This sample does not
register that operation or silently substitute raw JSON or a custom DTO.
The live gateway-scoped Office 365 operation list excludes this deprecated
operation as well; only the full source catalog lists it.

## Prerequisites

- .NET 10 SDK, Azure Functions Core Tools v4, Azure CLI 2.75.0+, Azure Developer CLI.
- PowerShell 7 on every platform; the optional Bash entry point delegates to it.
- Azurite for local Functions storage, plus a public HTTPS tunnel for local callbacks.
- An Office 365 mailbox for OAuth; full access to the shared mailbox if enabling it.
- The [connector-namespace CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli).

Packages restore from NuGet.org; no parent configuration or local extension build
is required.

## Deploy

Run commands from this folder, using a different environment from polling:

```powershell
az login
azd auth login
azd env new office365-webhook
azd env set OFFICE365_MAIL_FOLDER Inbox
azd env set OFFICE365_CALENDAR_ID '<actual connector calendar ID>'
# Optional shared mailbox; folderId differs from personal mail folderPath.
azd env set OFFICE365_SHARED_MAILBOX_ADDRESS '<shared-mailbox SMTP address>'
azd env set OFFICE365_SHARED_MAILBOX_FOLDER_ID Inbox
azd up
```

Confirm identifiers against the OAuth mailbox. `Calendar` is a sample default,
not a discovered ID. New mail has no importance filter. Empty shared mailbox address
disables its listener and skips its trigger registration. Re-run `azd up` after
changing source settings. If disabling a previously configured shared mailbox,
also disable/delete its existing namespace trigger; skipped resources are not deleted.

The namespace defaults to `westcentralus` (`CONNECTOR_NAMESPACE_LOCATION` override).
For Function regions without Application Insights, set `APPLICATION_INSIGHTS_LOCATION`
to a supported telemetry region (for example `eastus2`). This does not move the
Function App or namespace.

Infrastructure includes a .NET 10 Flex Consumption app, managed identity,
host/deployment storage, telemetry, namespace and connection. The post-deploy hook
gets the connector system key, creates/updates seven callback trigger configs
(eight with shared mailbox), and requests OAuth consent returning to
[Connector Namespaces](https://connectors.azure.com/). Configuration uses JSON files
for source parameters and callback authentication rather than interpolated CLI shorthand.

For deployment before source selection/consent:

```powershell
azd env set OFFICE365_ENABLE_TRIGGERS false
azd provision
azd deploy
pwsh -File .\infra\scripts\postdeploy.ps1 -ConsentLinkOnly
```

This registers disabled configurations and prints the consent URL without opening
a browser or waiting (also the default for staged deployments). After mailbox/calendar selection and consent, set
`OFFICE365_ENABLE_TRIGGERS true` and run `azd up`.

Worker telemetry uses `DefaultAzureCredential` because local/key authentication is
disabled on Application Insights. Verify worker receipt logs, not just host requests.

## Run locally

Deploy/authorize first, then:

```powershell
Copy-Item local.settings.example.json local.settings.json
# Start Azurite separately.
dotnet build
func start --enableAuth
```

Expose port 7071 over a public HTTPS tunnel. Retrieve the local host's
`connector_extension` system key from Azurite's `azure-webjobs-secrets` container
(for example using Storage Explorer), then run in another terminal:

```powershell
pwsh -File .\infra\scripts\postdeploy.ps1 `
  -CallbackBaseUrl 'https://<your-tunnel-host>' `
  -ConnectorExtensionKey '<local-connector_extension-key>'
```

This redirects configured callbacks to the local host, not both local and Azure.
If shared mailbox delivery is configured, set its local
`AzureWebJobs.OnSharedMailboxNewEmail.Disabled` setting to `false` before starting
the host; the example disables it by default.
Run `azd hooks run postdeploy` to restore Azure callbacks. Never commit keys, callback
URLs, or local settings. Azurite stores host state, not event payload output.

## Verify and clean up

Build success, deployment success, and real source-event success are distinct.
Check the connection is `Connected` and configurations are enabled. Generate one
test event for each source: new/mentioning-you mail, flag an email, shared-mailbox
mail, create/update/delete a calendar event, and an event inside the upcoming-event
window. Allow for source detection delays. Confirm worker logs contain
`Received <FunctionName> trigger` for each corresponding handler.

Delivery is at least once; duplicate receipt logs are possible. This sample does
not implement deduplication or log payload contents.

Run `azd down --purge` from this folder when finished.

## References

- [Office 365 connector source operations](https://learn.microsoft.com/connectors/office365/)
- [SDK typed registry and missing native webhook model](https://github.com/Azure/Connectors-NET-SDK/blob/1d9ce974172e97862fee81dd29682ebfc5ac50d5/src/Azure.Connectors.Sdk/Generated/Office365Extensions.cs#L4332-L4489)
- [Connector extension operation mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
