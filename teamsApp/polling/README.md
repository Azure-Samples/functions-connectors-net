# Microsoft Teams Polling Triggers (.NET)

This standalone sample uses `ConnectorTriggerDeliveryMode.Poll` for all 11
Teams triggers. The Function host connects outbound to an Azure Connector
Namespace to receive and acknowledge events. No public callback, function system
key, or development tunnel is required. Functions log only the event name
and, for the four typed payloads, message/member count, not message
content or member identities. There is no Blob output.

| Function / Teams operation | Required parameters |
| --- | --- |
| `OnNewChannelMessage` | `groupId`, `channelId` |
| `OnNewChannelMessageMentioningMe` | `groupId`, `channelId` |
| `OnGroupMembershipAdd` | `groupId` |
| `OnGroupMembershipRemoval` | `groupId` |
| `WebhookChatMessageTrigger` | None; all chats the authorized account belongs to |
| `WebhookNewMessageTrigger` | `threadType`, dynamic `requestBody` scope |
| `WebhookAtMentionTrigger` | `threadType`, dynamic `requestBody` scope |
| `WebhookKeywordTrigger` | `threadType`, `$search`, dynamic `requestBody` scope |
| `WebhookMessageReactionTrigger` | `reactionKey`, `frequency`, `runningPolicy`, `threadType`, dynamic `requestBody` scope |
| `RecordingTrigger` | `scopeType`, dynamic `body` scope |
| `TranscriptTrigger` | `scopeType`, dynamic `body` scope |

**SDK coverage limitation:** The Teams catalog contains seven additional events
(`WebhookChatMessageTrigger`, `WebhookNewMessageTrigger`, `WebhookAtMentionTrigger`,
`WebhookKeywordTrigger`, `WebhookMessageReactionTrigger`, `RecordingTrigger`,
`TranscriptTrigger`), but `Azure.Connectors.Sdk` 0.14.0-preview.1 has no strongly
typed trigger payload wrappers for them. As an approved exception, these seven
handlers use raw JSON `string` payloads and log only the event name. All-11
strongly typed support needs SDK additions; action-response models are not substitutes.
See the extension's
[Teams operation mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md#microsoft-teams-connector).

`Webhook*` names are the actual source operation IDs; their prefix does not
select Functions delivery mode. Poll describes delivery from the namespace to Functions,
independently of how the connector detects changes in Teams. A payload may contain
multiple messages/members; Functions invocation batching is not enabled.
Delivery is at least once, so duplicate log entries are possible; production
processing should be idempotent.

## Prerequisites

- .NET 10 SDK and Azure Functions Core Tools v4.
- Azure Developer CLI (`azd`), Azure CLI (`az`) 2.75.0 or later, and PowerShell 7.
- Azurite for local Functions host storage (not application output).
- A Teams account with access to the team/channel and permission to authorize
  the connector connection. Membership verification requires permission to
  add/remove a test member.
- The [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli):

  ```powershell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

`NuGet.config` supplies the public Azure Functions package feed. Connector worker
extension 1.0.0 supports Poll delivery; no local extension checkout is required.

## Deploy to Azure

Run from this folder (`teamsApp\polling` in the sample collection):

```powershell
az login
azd auth login
azd env new teams-polling
azd env set TEAMS_GROUP_ID "<team / Microsoft 365 group object ID>"
azd env set TEAMS_CHANNEL_ID "<channel ID>"
azd up
```

Set both identifiers **before provisioning**. In Teams, copy a channel link and
use its `groupId` and URL-decoded channel ID. Alternatively retrieve IDs using
Microsoft Graph with the appropriate permissions. Trigger parameters are defined
in `infra\poll-triggers.bicep`; do not use team/channel display names as IDs.

The Connector Namespace defaults to `westcentralus`; override it with
`azd env set CONNECTOR_NAMESPACE_LOCATION "<supported-region>"`.
Use an environment name different from any webhook deployment.
Application Insights and Log Analytics default to `eastus2`, independently of the
Function App/namespace region, because Application Insights is unavailable in
`westcentralus`. Override with `azd env set TELEMETRY_LOCATION "<supported-region>"`.
The worker telemetry exporter uses `DefaultAzureCredential` for Entra-authenticated
ingestion (the Azure managed identity or signed-in developer locally).

Bicep provisions a resource group, .NET 10 Flex Consumption Function App,
managed identity, host/deployment storage, Application Insights/Log Analytics,
Connector Namespace, Teams OAuth connection, and enabled Poll trigger
configurations without webhook notification details. Separate connection access
policies authorize the namespace, Function App, and provisioning developer.

### Enable all events

Only the four original typed events are registered by default. To enable all 11:

1. Copy `infra\additional-triggers.example.json` over `infra\additional-triggers.json`.
2. Replace every placeholder with the connector's actual values. Obtain dynamic
   `requestBody`/`body` scopes and enum values from the Teams connector UI or
   exported trigger configuration. Preserve parameter names, JSON value types and
   nested scope structure. Do not copy callback keys or OAuth tokens.
3. Keep all seven entries, or remove events not needed, then run `azd up`.

The parameterless chat trigger monitors **all chats of the consenting account**,
not just the test channel. Select it only with explicit scope approval and an
appropriate test account. Recording/transcript events likewise need explicit
meeting/call scopes and appropriate licenses/tenant meeting policies.

The pre-provision hook rejects unknown/duplicate operations, missing required
scope parameters, empty values and unresolved placeholders. Dynamic schema and
tenant permission validation remains the service's responsibility. The sample
requires scoped `requestBody` for targeted message events even though the static
reference marks that dynamic parameter optional.

Bicep emits all 11 trigger-config names and disables unselected additional Poll
listeners using `AzureWebJobs.<operation>.Disabled=true`. Configured additional
events receive `false`. Regenerate local settings with `-ForceLocalSettings` after
changing selected events. Removing an entry does not delete an existing config
under ARM incremental deployment; explicitly disable/delete it in the namespace.

Build/template checks do not prove live service acceptance of each operation or
real event delivery; verify each selected event with its authorized source scope.

The post-deploy hook opens OAuth consent and creates ignored `local.settings.json`
from deployment outputs if it does not exist. Re-run using
`azd hooks run postdeploy`. Existing local settings are preserved.
Consent uses the service-provided direct login link and returns to
`https://connectors.azure.com`. Already-connected connections are not reauthorized.

## Run locally

There is no local Teams/Connector Namespace emulator. Use real Azure resources
and Azurite for Functions host storage. To provision without a competing deployed
listener, use the login, environment, and team/channel commands above, then:

```powershell
azd provision
pwsh -File .\infra\scripts\postdeploy.ps1
```

To deliberately regenerate existing local settings:

```powershell
pwsh -File .\infra\scripts\postdeploy.ps1 -ForceLocalSettings
```

Start Azurite separately, then:

```powershell
dotnet build
func start
```

Local listeners use the signed-in developer credentials. Do not copy Azure's
`ConnectorNamespace__credential=managedidentity` or `__clientId` into local
settings. If a different developer runs locally, grant that identity its own
connection-level access policy. Local and deployed listeners sharing a trigger
configuration compete for events; use separate environments for isolated tests.

### Existing namespace

Copy `local.settings.example.json` to ignored `local.settings.json` and fill in the
endpoint and trigger-config names for existing enabled Poll configurations
on an authorized Teams connection. `Connection = "ConnectorNamespace"` in the
binding is the settings prefix, not the Teams connection resource name.
Grant both namespace and developer identities connection access.
For each configured additional event, change its
`AzureWebJobs.<operation>.Disabled` setting to `false` only after its Poll config
exists. Leave unconfigured events disabled.

Derive `ConnectorNamespace__pollingEndpoint` from service-generated
`pollingEndpoints.receiveUri`:

| Receive URI | Setting |
| --- | --- |
| `https://<host>/api/triggerconfigs/<name>/receive` | `https://<host>` |
| `https://<host>/api/connectorGateways/<id>/triggerconfigs/<name>/receive` | `https://<host>/api/connectorGateways/<id>` |

Exclude operation paths and query strings. Never commit real endpoints,
credentials, or `local.settings.json`.

## Verify and clean up

After consent, post a new root message in the configured channel (replies do not
fire `OnNewChannelMessage`), mention the authorized user in a message, and add or
remove a test team member. Allow for the connector's upstream detection interval.
Inspect local function logs or Application Insights for the corresponding
function name and count. There is no output container to inspect.
For additional events, send a chat message, a scoped message/@mention, the
configured keywords, and the selected reaction under its running policy.
Record/transcribe a test meeting or call in the configured scope and wait for
the artifacts to become available. Verify each selected function independently.

Run `azd down --purge` from this folder when finished.

## References

- [Teams connector operations and limitations](https://learn.microsoft.com/connectors/teams/)
- [Connector trigger configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md)
- [Connector Poll samples](https://github.com/Azure/azure-functions-connector-extension/tree/main/test/poll)
