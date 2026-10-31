# Microsoft Teams Webhook Triggers (.NET)

Azure Functions sample using [Azure.Connectors.Sdk](https://www.nuget.org/packages/Azure.Connectors.Sdk)
and the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector).
The Connector Namespace delivers events to the function's public HTTPS callback.
Typed handlers log only `Received <FunctionName> trigger ({Count} items)`;
raw handlers log the event name only.

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnNewChannelMessage` | [`OnNewChannelMessage`](https://learn.microsoft.com/connectors/teams/#when-a-new-channel-message-is-added) | New root channel message |
| `OnNewChannelMessageMentioningMe` | [`OnNewChannelMessageMentioningMe`](https://learn.microsoft.com/connectors/teams/#when-i-am-mentioned-in-a-channel-message) | Channel message mentioning the connection user |
| `OnGroupMembershipAdd` | [`OnGroupMembershipAdd`](https://learn.microsoft.com/connectors/teams/#when-a-new-team-member-is-added) | Team member added |
| `OnGroupMembershipRemoval` | [`OnGroupMembershipRemoval`](https://learn.microsoft.com/connectors/teams/#when-a-new-team-member-is-removed) | Team member removed |
| `WebhookChatMessageTrigger` | [`WebhookChatMessageTrigger`](https://learn.microsoft.com/connectors/teams/#when-a-new-chat-message-is-added) | New chat message (opt-in, raw JSON) |
| `WebhookNewMessageTrigger` | [`WebhookNewMessageTrigger`](https://learn.microsoft.com/connectors/teams/#when-a-new-message-is-added-to-a-chat-or-channel) | New chat/channel message (opt-in, raw JSON) |
| `WebhookAtMentionTrigger` | [`WebhookAtMentionTrigger`](https://learn.microsoft.com/connectors/teams/#when-i'm-@mentioned) | @mention (opt-in, raw JSON) |
| `WebhookKeywordTrigger` | [`WebhookKeywordTrigger`](https://learn.microsoft.com/connectors/teams/#when-keywords-are-mentioned) | Keyword mention (opt-in, raw JSON) |
| `WebhookMessageReactionTrigger` | [`WebhookMessageReactionTrigger`](https://learn.microsoft.com/connectors/teams/#when-someone-reacted-to-a-message-in-chat) | Message reaction (opt-in, raw JSON) |
| `RecordingTrigger` | [`RecordingTrigger`](https://learn.microsoft.com/connectors/teams/#when-a-recording-is-available) | Recording available (opt-in, raw JSON) |
| `TranscriptTrigger` | [`TranscriptTrigger`](https://learn.microsoft.com/connectors/teams/#when-a-transcript-is-available) | Transcript available (opt-in, raw JSON) |

SDK 0.14.0-preview.1 provides typed callback wrappers only for the first four events.
The seven approved `string` bindings are explicit exceptions: no parsing, inferred
counts or input/action-response models substitute for missing callback wrappers.
See the [pinned SDK source](https://github.com/Azure/Connectors-NET-SDK/blob/1d9ce974172e97862fee81dd29682ebfc5ac50d5/src/Azure.Connectors.Sdk/Generated/TeamsExtensions.cs#L3333-L3388).

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later
- PowerShell 7 for the default hook and the alternative Bash wrapper
- Azure Functions Core Tools v4 and Azurite for local development
- A Teams account with team/channel access and permission to authorize the connection
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
cd teamsApp/webhook
az login
azd auth login
azd env new teams-webhook
azd env set TEAMS_GROUP_ID "<team / Microsoft 365 group object ID>"
azd env set TEAMS_CHANNEL_ID "<URL-decoded channel ID>"
azd up
```

Use IDs from a Teams channel link, not display names. Complete OAuth when the hook
opens your browser; connected accounts skip consent. Use a different environment
name from Poll. Azure resources incur charges; no always-ready instances are configured.

## Optional configuration

| Setting / action | Purpose |
| --- | --- |
| `azd env set CONNECTOR_NAMESPACE_LOCATION <region>` | Namespace region; defaults to `westcentralus` |
| `azd env set TELEMETRY_LOCATION <region>` | Telemetry region; defaults to `eastus2` because Application Insights is unavailable in `westcentralus` |
| `infra/additional-triggers.json` | Select optional events below |
| Omit team/channel IDs | Hook offers interactive Graph selection; set both explicitly for noninteractive runs |
| `azd hooks run postdeploy` | Rerun registration/consent without redeployment |
| `bash ./infra/scripts/postdeploy.sh` | Alternative entry point; still requires PowerShell 7. For the postdeploy azd hook, use `shell: sh` and this script's path as `run` |

## Optional triggers

Four events are configured by default. To add others, copy the example
configuration, keep only the events you need, and fill in their required source
parameters. Setup registers callbacks for the selected events; no separate manual
listener flags are needed.

1. Copy `infra/additional-triggers.example.json` to `infra/additional-triggers.json`.
2. Keep only explicitly authorized events and replace placeholders using actual
   scopes/enums from the connector UI or exported configuration.

| Operation | Required source parameters |
| --- | --- |
| `WebhookChatMessageTrigger` | None; monitors **all chats of the connection user**, not just the channel |
| `WebhookNewMessageTrigger`, `WebhookAtMentionTrigger` | `threadType`, dynamic `requestBody` scope |
| `WebhookKeywordTrigger` | `threadType`, `$search`, dynamic `requestBody` scope |
| `WebhookMessageReactionTrigger` | `reactionKey`, `frequency`, `runningPolicy`, `threadType`, dynamic `requestBody` scope |
| `RecordingTrigger`, `TranscriptTrigger` | `scopeType`, dynamic `body` scope; appropriate meeting licenses/policies |

3. Preserve exact operation/parameter casing, JSON types and nested values.
   Never copy keys or tokens. Targeted events require `requestBody` even when
   marked optional in the catalog.
4. Apply the selection:

   ```bash
   azd up
   ```

Hooks reject unsupported/duplicate names, missing/empty values and placeholders;
the service validates dynamic schemas and permissions.

**Selection safety:** Removing an entry does not delete an existing config;
explicitly disable/delete it to stop callbacks. Broad chats and meeting
subscriptions are never enabled implicitly.

## Local development

1. Prepare `local.settings.json`.

   Use the file generated by postdeploy after `azd up`; existing files are preserved.
   Only if it is missing, run `azd hooks run postdeploy` to generate it.
2. Start Azurite in a separate terminal:

   ```bash
   azurite
   ```

3. Build and start the host:

   ```bash
   dotnet build
   func start
   ```

4. Open a public HTTPS tunnel to the local host and register **separate** configs
   using `/runtime/webhooks/connector?functionName=<FunctionName>`.
   Authenticate with the local `connector_extension` system key as the `code`
   query parameter.

**Hook behavior:** The hook targets Azure; it has no local callback override.
Separate local configs leave deployed callbacks unchanged. If you manually replace
the deployed configs, rerun `azd hooks run postdeploy` to restore Azure delivery.

**Access and safety:** The namespace identity requires connection access;
webhook-only reception needs no Function/developer connection access policy.
Never commit keys/local settings or expose unauthenticated callbacks.
Prefer [Poll](../polling/) without a public endpoint.

## Verify

Check the connection is **Connected** and selected triggers are **Enabled** in
[Connector Namespaces](https://connectors.azure.com/). Post a new root channel
message, not a reply, and look for `Received OnNewChannelMessage trigger` in logs.
Verify mentions/membership only with authorized test activity; optional events
require their scoped source action and prerequisites. Allow upstream detection
delays; delivery is at least once. Verify each selected event separately.

Run `azd down --purge` from this folder to clean up. Use a different environment
from Poll; preserve the environment name/values when continuing an existing deployment.

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md#microsoft-teams-connector)
- [Teams connector reference and callback schemas](https://learn.microsoft.com/connectors/teams/)
- [Connector trigger configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md)
