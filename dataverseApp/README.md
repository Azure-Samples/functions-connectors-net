# Microsoft Dataverse connector samples (.NET)

Choose a standalone app; each folder has its own project, `azure.yaml`, infrastructure,
settings template, and deployment instructions.

| Sample | Delivery | Functions |
| --- | --- | --- |
| [Polling](polling/README.md) | The Functions host pulls and acknowledges events from Connector Namespace. No inbound callback or connector system key is needed. | Three typed row-event triggers and List rows HTTP action |
| [Webhook](webhook/README.md) | Connector Namespace pushes events to the Functions connector webhook. | Three typed row-event triggers and List rows HTTP action |

Both use `commondataservice` operations for events and the typed
`CommondataserviceClient.GetItemsAsync` action for on-demand reads. Poll describes event
**delivery to Functions**, not a different Dataverse operation or a timer-triggered SDK call.
Triggers log row counts only; neither app writes payloads to Blob Storage. Storage remains
necessary for Functions host state and Flex Consumption deployment packages.

Each standalone app includes `NuGet.config` pointing at the public Azure Functions
`upstream-public` feed for the connector extension and its dependencies. No private feed
or machine-specific NuGet configuration is required.

If Application Insights is unavailable in the Function region, set `TELEMETRY_LOCATION`
to an approved supported region before `azd up`. This places Application Insights and its
Log Analytics workspace together without moving the Function app or Connector Namespace.
Worker telemetry uses `DefaultAzureCredential` because infrastructure disables local
Application Insights authentication.

## Event coverage and SDK blockers

| Event | Function | Operation | SDK payload |
| --- | --- | --- | --- |
| Row added | `OnDataverseRowChanged` (retained name) | `GetOnNewItems_V2` | `CommondataserviceOnNewItemsTriggerPayload` |
| Row modified | `OnDataverseRowModified` | `GetOnUpdatedItems_V2` | `CommondataserviceOnUpdatedItemsTriggerPayload` |
| Row deleted | `OnDataverseRowDeleted` | `GetOnDeletedItems_V2` | `CommondataserviceOnDeletedItemsTriggerPayload` |
| Row added, modified, or deleted (combined subscription) | **Blocked** | `SubscribeWebhookTrigger` | Not published in SDK 0.14.0-preview.1 |
| Action performed | **Blocked** | `BusinessEventsTrigger` | Not published in SDK 0.14.0-preview.1 |

All implemented trigger parameters are strongly typed SDK models. The SDK's
`CommondataserviceTriggerOperations` defines the three supported V2 operation identifiers.
The [connector reference](https://learn.microsoft.com/connectors/commondataservice/#triggers)
also documents the combined-change and action-performed operations, but the latest SDK
on the Azure Functions public feed (0.14.0-preview.1) contains no payload model or trigger
operation metadata for either. These two handlers cannot be added while preserving
strong SDK typing. There are deliberately no raw JSON/string bindings, custom DTOs,
invented SDK types, or nonfunctional trigger registrations.

An SDK update adding the two operation-specific payload models is required to unblock
all five event types. The combined subscription also previously failed Connector Namespace
trigger creation with an HTTP 500 / `Regex.Match` service error. Action-performed setup
will additionally need real catalog, category, table, and SDK-message identifiers from the
target environment once its SDK contract becomes available.

The three individual handlers still provide create/update/delete event coverage. New event
types and Poll delivery require live verification against your namespace/region; compiling
a sample does not establish service-side availability.
