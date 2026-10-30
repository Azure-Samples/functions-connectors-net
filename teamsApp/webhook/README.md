# Microsoft Teams Webhook Triggers (.NET)

This standalone sample supports all 11 Teams events, preserving the typed operations:
`OnNewChannelMessage`, `OnNewChannelMessageMentioningMe`,
`OnGroupMembershipAdd`, and `OnGroupMembershipRemoval`. Each receives a typed
Teams payload and logs only the trigger name and message/member count.
Payloads are not written to Blob Storage or application logs.

**SDK coverage limitation:** The seven other catalog events
(`WebhookChatMessageTrigger`, `WebhookNewMessageTrigger`, `WebhookAtMentionTrigger`,
`WebhookKeywordTrigger`, `WebhookMessageReactionTrigger`, `RecordingTrigger`,
`TranscriptTrigger`) lack strongly typed trigger payload wrappers in
`Azure.Connectors.Sdk` 0.14.0-preview.1. As an approved exception, those seven
handlers receive raw JSON `string` payloads and log only the event name. Supporting
all 11 with SDK types requires wrappers to be published; input/action-response
models are not replacements.
See the extension's
[Teams operation mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md#microsoft-teams-connector).

Webhook is the default when `DeliveryMode` is omitted from `[ConnectorTrigger]`.
The Connector Namespace delivers callbacks to
`https://<function-host>/runtime/webhooks/connector?functionName=<function-name>`
using the connector extension system key in the `code` query parameter.
The namespace identity has connection access to detect Teams changes;
webhook-only reception needs no Function/developer connection access policy.
For outbound-only local development, use the separate Poll sample.

## Prerequisites

- .NET 10 SDK.
- Azure Developer CLI (`azd`), Azure CLI (`az`) 2.75.0 or later, and PowerShell 7.
- A Teams account and permission to authorize the Teams connector.
- [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli):

  ```powershell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

The included `NuGet.config` provides the public Azure Functions package feed.
Copy this entire folder to use it independently of the sample collection.

## Deploy

Run from this folder (`teamsApp\webhook` in the sample collection):

```powershell
az login
azd auth login
azd env new teams-webhook
azd env set TEAMS_GROUP_ID "<team / Microsoft 365 group object ID>"
azd env set TEAMS_CHANNEL_ID "<channel ID>"
azd up
```

Use the identifiers from a Teams channel link (`groupId` and URL-decoded channel
ID), or Microsoft Graph. Message triggers require both IDs; membership triggers
require only the group ID. If unset, the post-deploy hook offers interactive
team/channel selection via Microsoft Graph with the permissions of your CLI
identity. Set them explicitly for noninteractive runs.
The Connector Namespace defaults to `westcentralus`; change it via
`CONNECTOR_NAMESPACE_LOCATION` if needed.
Application Insights and Log Analytics default to `eastus2`, independently of the
Function App/namespace region; Application Insights is unavailable in
`westcentralus`. Override via `TELEMETRY_LOCATION` if needed. The worker telemetry
exporter uses `DefaultAzureCredential` for Entra-authenticated ingestion.

Deployment includes a Flex Consumption .NET 10 Function App, managed identity,
Functions host/deployment storage, Application Insights/Log Analytics, Connector
Namespace, and Teams OAuth connection. The post-deploy hook registers the selected
callback trigger configurations and opens connection consent. Re-run using
`azd hooks run postdeploy`.
Consent uses the actual service-provided login link with redirect
`https://connectors.azure.com`; already-connected connections skip reauthorization.

### Enable all events

Only the four original typed events are registered by default. For all 11, copy
`infra\additional-triggers.example.json` over `infra\additional-triggers.json`
and fill all seven entries:

| Operation | Parameters |
| --- | --- |
| `WebhookChatMessageTrigger` | None; all chats of the authorized account |
| `WebhookNewMessageTrigger` | `threadType`, dynamic `requestBody` chat/channel scope |
| `WebhookAtMentionTrigger` | `threadType`, dynamic `requestBody` chat/channel scope |
| `WebhookKeywordTrigger` | `threadType`, `$search` (comma-separated keywords), dynamic `requestBody` |
| `WebhookMessageReactionTrigger` | `reactionKey`, `frequency`, `runningPolicy`, `threadType`, dynamic `requestBody` |
| `RecordingTrigger` | `scopeType`, dynamic `body` recording scope |
| `TranscriptTrigger` | `scopeType`, dynamic `body` transcript scope |

Obtain actual enum values and dynamic bodies from the Teams connector UI or an
exported trigger configuration. Preserve parameter names, JSON value types and
nested scope structure. Do not copy callback keys or OAuth tokens. Keep all seven
entries for all-events coverage, or remove unneeded entries. The sample requires a
scoped `requestBody` for targeted message events even though the static reference
marks it optional.

The parameterless chat event observes **all chats the account belongs to**,
not just the test channel; explicitly approve that scope and use an appropriate
test account. Recording/transcript scopes must also be selected explicitly.

Run `pwsh -File .\infra\scripts\validate-triggers.ps1` before `azd up`. Hooks reject
unknown/duplicate operations, missing scope parameters, empty values and unresolved
placeholders. Dynamic schema and tenant permission validation remains the service's
responsibility. The shell hook delegates to PowerShell to keep registration
consistent. Removing an entry does not delete its existing namespace config;
disable/delete that config explicitly to stop its callbacks.

There is no application output container or Blob binding. The storage account
and its identity roles are retained for Functions host state and deployment.
Existing `connector-messages` blobs from an earlier deployment are not deleted;
remove those separately if appropriate.

## Local development

Prefer the Poll sample when a public endpoint is unavailable. Webhook delivery
requires Azure Functions Core Tools v4, Azurite, and a public HTTPS tunnel to the
local host. Copy `local.settings.example.json` to ignored `local.settings.json`,
start Azurite, then run `dotnet build` and `func start`.

Register separate webhook trigger configurations on an authorized Teams connection
using your tunnel callback URL, matching function names, and the local host's
connector extension system key. The deployment hook targets the **deployed**
Function App, not a local tunnel. Never expose an unauthenticated callback or
commit function keys/local settings.
See [webhook registration](https://github.com/Azure/azure-functions-connector-extension/blob/main/.github/skills/webhook-trigger-registration/SKILL.md).

## Verify and clean up

Confirm the Teams connection is `Connected` and all four trigger configs are
enabled in the [Connector Namespaces portal](https://connectors.azure.com/).
Post a new root channel message (not a reply), mention the authorized account,
and add/remove a test member with the appropriate permissions. Check local
function logs or Application Insights for the corresponding trigger name/count.
Allow for upstream detection delays; retries can produce duplicate logs.
For additional events, send a chat message, scoped message/@mention, configured
keywords, and the selected reaction under its running policy. Record/transcribe
a test meeting or call matching the configured scope and wait for the artifacts
to become available. These require the appropriate licenses and tenant policies.
Verify each selected function independently.

Run `azd down --purge` from this folder when finished. Do not reuse the polling
environment. To continue an existing pre-split Teams deployment, preserve its azd
environment values under this folder and retain the same environment name.

See [Teams connector operations and limitations](https://learn.microsoft.com/connectors/teams/)
and [connector delivery configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md).
