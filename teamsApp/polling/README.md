# Microsoft Teams Polling Triggers (.NET)

Azure Functions sample using [Azure.Connectors.Sdk](https://www.nuget.org/packages/Azure.Connectors.Sdk) and the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector) with `DeliveryMode = Poll`. The host receives events outbound from the Connector Namespace; no public callback or tunnel is required. All handlers use typed payloads and log the event name and item count.

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnNewChannelMessage` | [`OnNewChannelMessage`](https://learn.microsoft.com/connectors/teams/#when-a-new-channel-message-is-added) | New root channel message |
| `OnNewChannelMessageMentioningMe` | [`OnNewChannelMessageMentioningMe`](https://learn.microsoft.com/connectors/teams/#when-i-am-mentioned-in-a-channel-message) | Channel message mentioning the connection user |
| `OnGroupMembershipAdd` | [`OnGroupMembershipAdd`](https://learn.microsoft.com/connectors/teams/#when-a-new-team-member-is-added) | Team member added |
| `OnGroupMembershipRemoval` | [`OnGroupMembershipRemoval`](https://learn.microsoft.com/connectors/teams/#when-a-new-team-member-is-removed) | Team member removed |
| `WebhookChatMessageTrigger` | [`WebhookChatMessageTrigger`](https://learn.microsoft.com/connectors/teams/#when-a-new-chat-message-is-added) | New chat message (opt-in) |
| `WebhookNewMessageTrigger` | [`WebhookNewMessageTrigger`](https://learn.microsoft.com/connectors/teams/#when-a-new-message-is-added-to-a-chat-or-channel) | New chat/channel message (opt-in) |
| `WebhookAtMentionTrigger` | [`WebhookAtMentionTrigger`](https://learn.microsoft.com/connectors/teams/#when-i'm-@mentioned) | @mention (opt-in) |
| `WebhookKeywordTrigger` | [`WebhookKeywordTrigger`](https://learn.microsoft.com/connectors/teams/#when-keywords-are-mentioned) | Keyword mention (opt-in) |
| `WebhookMessageReactionTrigger` | [`WebhookMessageReactionTrigger`](https://learn.microsoft.com/connectors/teams/#when-someone-reacted-to-a-message-in-chat) | Message reaction (opt-in) |
| `RecordingTrigger` | [`RecordingTrigger`](https://learn.microsoft.com/connectors/teams/#when-a-recording-is-available) | Recording available (opt-in) |
| `TranscriptTrigger` | [`TranscriptTrigger`](https://learn.microsoft.com/connectors/teams/#when-a-transcript-is-available) | Transcript available (opt-in) |

`WebhookNewMessageTrigger`, `WebhookAtMentionTrigger`, and `WebhookKeywordTrigger` use dynamic schemas, with item fields exposed through `AdditionalProperties`. See [webhook callback schemas](https://github.com/Azure/Connectors-NET-SDK/blob/main/docs/triggers.md#webhook-callback-schemas). `Webhook` operation-name prefixes describe source subscriptions, not Functions delivery.

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) 1.33.0+
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later
- PowerShell 7 on Windows or `sh` on POSIX; a terminal and writable temporary directory for setup
- Azure Functions Core Tools v4 and Azurite for local development
- A Teams account with team/channel access and permission to authorize the connection
- [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli) version 1.0.0b33. The deployment scripts use it automatically for sign-in and source pickers:

  ```bash
  curl -fsSL https://aka.ms/connector-namespace-cli-install | sh
  ```

  Or in PowerShell:

  ```powershell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

## Deploy to Azure

`azd up` provisions the Azure resources, helps you set up triggers, and deploys the Function App.

```cmd
cd teamsApp/polling
az login
azd auth login
azd env new teams-polling
azd up
```

Use a different environment name from webhook. Complete browser sign-in, choose at least one trigger, and select the teams, channels or other sources to monitor when prompted. Only selected triggers are enabled. Setup checks Azure's Connected status even if a sign-in window remains stale.

## Optional configuration

| Setting / action | Purpose |
| --- | --- |
| `azd env set CONNECTOR_NAMESPACE_LOCATION <region>` | Namespace region; defaults to `westcentralus` |
| `azd env set TELEMETRY_LOCATION <region>` | Telemetry region; defaults to `eastus2` because Application Insights is unavailable in `westcentralus` |
| `infra/scripts/polling-config.json` | Catalog of all eleven functions and connector operations |

## Optional triggers

All events are explicitly selected during setup; no broad chat or meeting subscription is enabled implicitly. The metadata collector asks for required source inputs, including dynamic request-body fields. Select only authorized scopes. Important source requirements remain:

| Operation | Required source parameters |
| --- | --- |
| `WebhookChatMessageTrigger` | None; monitors **all chats of the connection user**, not just the channel |
| `WebhookNewMessageTrigger`, `WebhookAtMentionTrigger` | `threadType`, dynamic `requestBody` scope |
| `WebhookKeywordTrigger` | `threadType`, `$search`, dynamic `requestBody` scope |
| `WebhookMessageReactionTrigger` | `reactionKey`, `frequency`, `runningPolicy`, `threadType`, dynamic `requestBody` scope |
| `RecordingTrigger`, `TranscriptTrigger` | `scopeType`, dynamic `body` scope; appropriate meeting licenses/policies |

Use actual source identifiers, not placeholders or display names. Targeted events require `requestBody` even where metadata marks it optional; the service validates dynamic schemas, licensing and permissions.

Selections are saved in the active azd environment's `POLLING_TRIGGER_INPUTS` and reused. These settings are not encrypted; keep `.azure` out of source control. To choose again:

```cmd
azd env set POLLING_TRIGGER_INPUTS ""
azd up
```

**Selection safety:** Bicep enables selected configurations. Setup disables skipped owned configurations while preserving their other writable properties and disables corresponding app listeners; absent skipped configurations stay absent. Unrelated configurations are not changed. Setup refuses configurations with missing or conflicting destination ownership metadata; use a fresh sample environment for older configurations without it. Reselecting enables the same deterministic ID. Disabling does not tear down upstream subscriptions or remove queued events. This behavior applies to polling only, not webhook registrations.

If sign-in or trigger setup fails, correct the issue and rerun `azd up`. Resources already provisioned remain available. Deployment creates ignored `local.settings.json` only if missing. Existing files are preserved byte-for-byte; reconcile their switches manually or deliberately archive the file before regenerating.

## Local development

If the Function App is already deployed, stop it before running locally to avoid competing listeners.

1. Prepare `local.settings.json`.

   Use the file generated during successful `azd up`. Sign in with an identity granted developer connection access:

   ```cmd
   az login
   ```

   Only if the file is missing, run `dotnet run --file ./infra/scripts/PollingSetup.cs -- finish` to generate it. The example has a placeholder endpoint and all listeners disabled, so it is not runnable. Do not copy Azure managed-identity settings locally.

   Worker telemetry uses the same `ConnectorNamespace` identity settings as polling: the Function App's system-assigned identity in Azure, developer credentials locally.
2. Start Azurite in a separate terminal:

   ```cmd
   azurite
   ```

3. Build and start the host:

   ```cmd
   dotnet build
   func start
   ```

**Existing endpoint:** Derive it from `pollingEndpoints.receiveUri`, removing the query and `/triggerconfigs/<name>/receive`; retain a gateway path, or strip a final `/api`. There is no connector emulator. Never commit endpoints/local settings.

## Verify

Check the connection is **Connected** and selected triggers are **Enabled** in [Connector Namespaces](https://connectors.azure.com/). Post a new root channel message, not a reply, and look for `Received OnNewChannelMessage trigger` in logs. Verify mentions/membership only with authorized test activity; optional events require their scoped source action and prerequisites. Allow upstream detection delays; delivery is at least once. Build checks do not prove each real source event.

Run `azd down --purge` from this folder to clean up.

## More

- [Connector trigger payloads for Azure Functions](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md#microsoft-teams-connector)
- [Teams connector reference and callback schemas](https://learn.microsoft.com/connectors/teams/)
- [Connector trigger configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md)
