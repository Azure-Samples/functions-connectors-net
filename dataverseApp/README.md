# Microsoft Dataverse connector samples (.NET)

| Sample | Delivery |
| --- | --- |
| [Polling](polling/README.md) | The Functions host pulls and acknowledges Connector Namespace events |
| [Webhook](webhook/README.md) | Connector Namespace pushes events to the Functions connector webhook |

Each folder is a standalone .NET 10 Functions app with its own infrastructure and settings.
Both use **current, nondeprecated** `commondataservice` operations only:

| Function | Operation | Coverage | Enabled |
| --- | --- | --- | --- |
| `OnDataverseRowChanged` | `SubscribeWebhookTrigger` | Added, modified, and deleted rows in one subscription (`message=7`, organization scope `scope=4`) | Default |
| `OnDataverseActionPerformed` | `BusinessEventsTrigger` | Completion of a selected Dataverse business action | Opt-in, requires real event identifiers |

The three individual legacy row operations (`GetOnNewItems_V2`, `GetOnUpdatedItems_V2`,
`GetOnDeletedItems_V2`) are deprecated and deliberately not registered or implemented.
The [current connector reference](https://learn.microsoft.com/connectors/commondataservice/#triggers)
documents the two replacement operations.

## Explicit SDK exceptions

These **two event payloads** are explicitly approved raw-JSON exceptions: both handlers use
`JsonElement` because the latest published SDK (0.14.0-preview.1) and
[unreleased SDK main](https://github.com/Azure/Connectors-NET-SDK/blob/1d9ce974172e97862fee81dd29682ebfc5ac50d5/src/Azure.Connectors.Sdk/Generated/CommondataserviceExtensions.cs#L646-L728)
lack their payload models and operation metadata. This is not a general permission to
replace other samples' strong SDK types. The handlers log event receipt and JSON kind only,
not personal row contents; neither app has a Blob output.

The old HTTP List rows action is removed: its SDK `GetItemsAsync` method targets deprecated
`GetItems_V2`. The current `ListRecords` operation has no generated SDK method in that release.
No replacement HTTP action, invented SDK type, or deprecated fallback is shipped.
An SDK update needs models/metadata for both current event operations and a `ListRecords`
client method before those surfaces can be strongly typed.

## Action-performed setup

In the chosen sample folder and selected `azd` environment:

```powershell
azd env set DATAVERSE_ENABLE_ACTION_TRIGGER true
azd env set DATAVERSE_EVENT_CATALOG "<catalog identifier>"
azd env set DATAVERSE_EVENT_CATEGORY "<category identifier>"
azd env set DATAVERSE_EVENT_TABLE "<table identifier accepted by the event selector>"
azd env set DATAVERSE_EVENT_ACTION "<SDK message/action name>"
azd up
```

Obtain these exact identifiers from the target environment; do not guess them. The
pre-provision hook rejects missing values. The action handler remains disabled by default.
For local testing after enabling it, regenerate Poll local settings or set webhook's
`AzureWebJobs.OnDataverseActionPerformed.Disabled` to `false`.

## Deployment and service limitations

Use the logical table name (`account`) for current subscriptions, not the Web API entity
set (`accounts`). The latter creates an enabled Namespace configuration but source
registration fails with `0x80040203: Entity not present in cache: accounts`.
Check the latest trigger execution status as well as the configuration state.
Successful compilation, OAuth consent, or resource creation alone is not proof of a
working source subscription. These samples never fall back to deprecated operations.
Business-event support must also be verified after its identifiers are supplied.

`NuGet.config` in each folder uses the public Azure Functions `upstream-public` feed.
Set `TELEMETRY_LOCATION` to an approved supported region if Application Insights is unavailable
in the Function region. Worker telemetry uses `DefaultAzureCredential` with local Insights
authentication disabled. OAuth uses the `https://connectors.azure.com` redirect, prints
the returned direct consent URL, opens it, and preserves already connected OAuth connections.

Functions host/deployment storage remains necessary even though no event payload is stored.
Poll infrastructure provisions **one paid always-ready instance per enabled current Poll
Function** (one by default, two with action-performed enabled), not for removed legacy
Functions or webhook delivery. These baseline charges continue while idle; run
`azd down --purge` from each deployed sample folder when finished.
