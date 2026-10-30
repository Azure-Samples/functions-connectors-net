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

### Deprecated source trigger intentionally excluded

**When a new email arrives (webhook)** is the deprecated source operation
`CreateOnNewEmailSubscription`, not `OnNewEmailV3`. Its source Swagger path
`/{connectionId}/MailSubscription/$subscriptions` declares
`x-ms-notification-content.schema` as
`TriggerBatchResponse[ReceiveMessageMetadata]`: a `value` array of legacy metadata
with `Id`, `DateTimeReceived`, `HasAttachment`, integer `Importance`, and string
`From`/`To`/`Cc`/`Bcc`/`ReplyTo`. The `SubscriptionResponse` returned when creating
the subscription is not an event payload.

Deprecated triggers are intentionally out of scope when a current supported
alternative exists. Both apps use `OnNewEmailV3` instead, including for namespace
Webhook delivery. `CreateOnNewEmailSubscription` is not a missing feature awaiting
implementation. The live gateway-scoped operation list exposes only the eight
current triggers above; the deprecated operation appears in the full source
catalog only.

For reference, SDK `0.14.0-preview.1` and main commit
`1d9ce974172e97862fee81dd29682ebfc5ac50d5` also lack its legacy metadata model
and trigger wrapper. The current V3 Graph wrapper has different wire names and
string importance, so it must not be used for legacy native notifications.

Evidence: [Office 365 connector reference](https://learn.microsoft.com/connectors/office365/),
[SDK typed trigger registry](https://github.com/Azure/Connectors-NET-SDK/blob/1d9ce974172e97862fee81dd29682ebfc5ac50d5/src/Azure.Connectors.Sdk/Generated/Office365Extensions.cs#L4332-L4489).
Inspect the live source definition with:

```powershell
az connector-namespace connector show -n office365 --catalog westcentralus --export-swagger
```

## Preview service limitation

Live validation on 2026-10-29 found that `CalendarGetOnChangedItemsV3` is exposed
by the namespace but its source subscription fails in both delivery modes with
`inputs.subscribe` / missing path template variable `TABLE`. Both the source
operation and its `CreateGraphOnChangedEventPokeSubscription` notification operation
declare lowercase `table`; the samples supply the confirmed opaque calendar ID.
This service-side notification mapping issue prevents real changed-event delivery
even though deployment succeeds. The typed handler and correct registration remain
included; no parameter aliases or incompatible payload substitutions are used.
