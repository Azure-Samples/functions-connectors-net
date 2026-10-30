# Office 365 Outlook Connector Samples (.NET)

Choose how the Connector Namespace delivers events to Azure Functions:

| Sample | Delivery | Local development |
| --- | --- | --- |
| [Polling](polling/) | Function host receives events by polling the namespace | Outbound connection only; no tunnel required |
| [Webhook](webhook/) | Namespace calls the function's HTTPS callback | Public HTTPS tunnel required for real events |

Both samples demonstrate all eight current email/calendar source operations using
strongly typed `Azure.Connectors.Sdk` payloads. Each function logs trigger receipt
without logging payload contents or writing them to Blob Storage. Storage remains
necessary for the Functions runtime and deployment.

Each folder contains its own project, infrastructure, scripts, configuration
templates, license, and setup instructions. Build, run, and deploy from the selected
folder, not this directory. Either folder's contents can be copied into an
independent repository without any dependencies on this collection.

Use different azd environment names for the two samples to keep deployments
independent. See each sample's README for prerequisites and local setup.

OAuth consent returns to [Connector Namespaces](https://connectors.azure.com/).

## Source event coverage

The source connector's polling/webhook implementation is independent of how the
Connector Namespace delivers events to Functions. The eight current operations
below can use namespace Poll or Webhook delivery; a source name is not a delivery
mode restriction.

| Source event | Operation ID | SDK payload (`Azure.Connectors.Sdk.Office365.Models`) |
| --- | --- | --- |
| New email (V3) | `OnNewEmailV3` | `Office365OnNewEmailTriggerPayload` |
| Email mentioning me (V3) | `OnNewMentionMeEmailV3` | `Office365OnNewEmailMentioningMeTriggerPayload` |
| New event (V3) | `CalendarGetOnNewItemsV3` | `Office365OnCalendarNewItemsTriggerPayload` |
| Event added, updated or deleted (V3) | `CalendarGetOnChangedItemsV3` | `Office365OnCalendarChangedItemsTriggerPayload` |
| Upcoming event (V3) | `OnUpcomingEventsV3` | `Office365OnUpcomingEventsTriggerPayload` |
| Flagged email (V4) | `OnFlaggedEmailV4` | `Office365OnFlaggedEmailTriggerPayload` |
| Shared mailbox email (V2), opt-in | `SharedMailboxOnNewEmailV2` | `Office365OnSharedMailboxNewEmailTriggerPayload` |
| Modified event (V3) | `CalendarGetOnUpdatedItemsV3` | `Office365OnCalendarUpdatedItemsTriggerPayload` |

### Ninth event: SDK gap, not a raw-payload sample

**When a new email arrives (webhook)** is the deprecated source operation
`CreateOnNewEmailSubscription`, not `OnNewEmailV3`. Its source Swagger path
`/{connectionId}/MailSubscription/$subscriptions` declares
`x-ms-notification-content.schema` as
`TriggerBatchResponse[ReceiveMessageMetadata]`: a `value` array of legacy metadata
with `Id`, `DateTimeReceived`, `HasAttachment`, integer `Importance`, and string
`From`/`To`/`Cc`/`Bcc`/`ReplyTo`. The `SubscriptionResponse` returned when creating
the subscription is not an event payload.

SDK `0.14.0-preview.1` and SDK main commit
`1d9ce974172e97862fee81dd29682ebfc5ac50d5` do not provide this metadata model,
batch wrapper, or trigger payload. The V3 Graph wrapper is incompatible (different
wire names and string importance). Neither app registers this ninth operation or
substitutes a string, `JsonElement`, or custom DTO. A matching SDK model and
service-level delivery verification are required before adding it.
The live gateway-scoped Office 365 operation list also excludes this deprecated
operation; it appears only in the full source catalog. Namespace support must
therefore be added/confirmed separately from publishing an SDK model.

Evidence: [Office 365 connector reference](https://learn.microsoft.com/connectors/office365/),
[SDK typed trigger registry](https://github.com/Azure/Connectors-NET-SDK/blob/1d9ce974172e97862fee81dd29682ebfc5ac50d5/src/Azure.Connectors.Sdk/Generated/Office365Extensions.cs#L4332-L4489).
Inspect the live source definition with:

```powershell
az connector-namespace connector show -n office365 --catalog westcentralus --export-swagger
```
