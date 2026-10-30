# Office 365 Outlook Polling Triggers (.NET)

Standalone Azure Functions sample: copy this entire folder into a new repository.
The host polls the Connector Namespace using `DeliveryMode = Poll`, receives typed
SDK payloads, and logs receipt without email/calendar contents. No public callback
or tunnel is required. There is no Blob output binding; storage remains necessary
for Functions host state and deployment.

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

The deprecated source event **When a new email arrives (webhook)**,
`CreateOnNewEmailSubscription`, is intentionally excluded because the current
`OnNewEmailV3` operation is supported. It is not a missing feature awaiting
implementation. Namespace Webhook delivery also uses the current V3 source.
The live gateway-scoped operation list exposes only the eight current triggers.
The eight current source operations above support namespace Poll delivery; source
trigger names do not determine namespace delivery mode.

## Prerequisites

- .NET 10 SDK, Azure Functions Core Tools v4, Azure CLI 2.75.0+, Azure Developer CLI.
- PowerShell 7 on every platform for the post-deploy hook.
- Azurite for local Functions host storage.
- An Office 365 mailbox with permission to authorize the connection; full access
  to the shared mailbox is required to enable that optional event.
- The [connector-namespace CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli).

Packages restore from NuGet.org without a parent configuration or extension checkout.

## Deploy

Run all commands from this folder. Use an isolated environment, different from any
webhook deployment.

```powershell
az login
azd auth login
azd env new office365-polling
azd env set OFFICE365_MAIL_FOLDER Inbox
azd env set OFFICE365_CALENDAR_ID '<actual connector calendar ID>'
# Optional shared mailbox; folderId is not the personal-mail folderPath parameter.
azd env set OFFICE365_SHARED_MAILBOX_ADDRESS '<shared-mailbox SMTP address>'
azd env set OFFICE365_SHARED_MAILBOX_FOLDER_ID Inbox
azd up
```

Confirm these identifiers for the OAuth mailbox. `Calendar` is only a sample
default, not a discovered calendar ID. No importance filter is imposed on new mail.
If shared mailbox address is empty, its source trigger is not provisioned and its
Functions listener is disabled. To enable it later, set the address/folder and run
`azd up` again. To disable a previously enabled shared mailbox, disable/delete its
existing namespace trigger as well; conditional ARM resources are not removed by
incremental deployment.

The namespace defaults to `westcentralus` (`CONNECTOR_NAMESPACE_LOCATION` override).
If your Function region lacks Application Insights, set
`APPLICATION_INSIGHTS_LOCATION` to a supported telemetry region before provisioning
(for example `eastus2`); host/namespace locations remain unchanged.

Bicep creates the Function App, host/deployment storage, identity, telemetry,
namespace, connection, and seven Poll trigger configurations (eight with a shared
mailbox). It grants access to the namespace, Function App, and developer identities.
The post-deploy hook opens OAuth consent and creates ignored `local.settings.json`,
preserving an existing file unless `-ForceLocalSettings` is supplied.

For staged deployment before source selection/consent:

```powershell
azd env set OFFICE365_ENABLE_TRIGGERS false
azd provision
azd deploy
pwsh -File .\infra\scripts\postdeploy.ps1 -ConsentLinkOnly
```

`-ConsentLinkOnly` prints the OAuth URL without opening a browser or waiting.
Staged (`OFFICE365_ENABLE_TRIGGERS=false`) deployments also print without waiting.
After selecting the correct mailbox/calendar and completing consent, set
`OFFICE365_ENABLE_TRIGGERS true` and run `azd up`. OAuth returns to
[Connector Namespaces](https://connectors.azure.com/).

### Always-ready capacity and cost

Each configured polling function has one 2048 MB always-ready instance by default
(seven, or eight with shared mailbox). These instances incur idle charges. This
avoids relying on scale-from-zero for the preview custom polling listener. Remove
or adjust `alwaysReady` in `infra/main.bicep` only after verifying activation and
acceptable latency in your environment. Do not enable runtime-driven scale
monitoring: Flex Consumption rejects that setting.

Worker OpenTelemetry explicitly uses `DefaultAzureCredential` because telemetry
local/key authentication is disabled. Host request records alone do not prove
worker receipt logs were exported.

## Run locally

Provision a separate environment without deploying code to avoid competing local
and cloud consumers, then run the post-deploy script:

```powershell
azd provision
pwsh -File .\infra\scripts\postdeploy.ps1
# Start Azurite separately.
dotnet build
func start
```

Alternatively copy `local.settings.example.json` to `local.settings.json`, supply
the Poll endpoint and all eight config names, and enable the shared-mailbox listener
only after its configuration exists. Locally the binding uses signed-in developer
credentials. Do not copy cloud managed-identity settings to local settings.

`Connection = "ConnectorNamespace"` is a configuration prefix, not the Office 365
connection resource name. Derive `ConnectorNamespace__pollingEndpoint` from the
service's `pollingEndpoints.receiveUri`, removing `/triggerconfigs/...` and any
query; remove a trailing `/api` from that base. Preserve gateway prefixes such as
`/api/connectorGateways/<id>`. Never commit endpoints, keys, or local settings.

## Verify and clean up

Build success, Azure deployment success, and real source-event success are separate
checks. After consent and enabling triggers, confirm `Connected`, enabled trigger
states, and logs containing `Received <FunctionName> trigger` for every operation.
Send new and mentioning-you mail, flag a message, send to the shared mailbox, and
create/update/delete a test calendar event. Schedule a future event inside the
upcoming-event look-ahead window. Source detection can be delayed; polling is the
namespace delivery mode, not a guarantee of immediate source detection.

**Preview service issue (2026-10-29):** `CalendarGetOnChangedItemsV3` registration
deploys but source subscription fails with `inputs.subscribe` / missing `TABLE`
path variable, despite both source/notification schemas declaring `table` and the
confirmed calendar ID being supplied. This was reproduced in Poll and Webhook.
Its typed handler remains included, but do not claim real changed-event success
until the service mapping is fixed. Inspect raw ARM
`<trigger-resource-id>/triggerStatuses/latest?api-version=2026-05-01-preview` for
`lastExecutionError`; the current CLI status schema may omit these diagnostics.

Delivery is at least once. This sample logs receipt only; it does not expose
delivery `MessageId`, batch Functions invocations, or implement deduplication.
An event can contain multiple source items inside the typed payload.

Run `azd down --purge` from this folder when finished, including always-ready resources.

## References

- [Office 365 source operations](https://learn.microsoft.com/connectors/office365/)
- [SDK typed trigger registry](https://github.com/Azure/Connectors-NET-SDK/blob/1d9ce974172e97862fee81dd29682ebfc5ac50d5/src/Azure.Connectors.Sdk/Generated/Office365Extensions.cs#L4332-L4489)
- [Connector polling configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md)
