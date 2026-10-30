# Microsoft Teams Connector Triggers (.NET)

Choose a standalone sample:

| Sample | Delivery to Functions | Local development |
| --- | --- | --- |
| [Polling](polling/README.md) | Function host receives and acknowledges events outbound from a Connector Namespace | No public callback or tunnel |
| [Webhook](webhook/README.md) | Connector Namespace calls the function's authenticated callback | Requires a public HTTPS callback |

Both samples implement all 11 Teams catalog events. The original four use
strongly typed SDK payloads:

| Function / connector operation | Source |
| --- | --- |
| `OnNewChannelMessage` | New root message in the configured channel |
| `OnNewChannelMessageMentioningMe` | Channel message mentioning the authorized user |
| `OnGroupMembershipAdd` | Member added to the configured team |
| `OnGroupMembershipRemoval` | Member removed from the configured team |

## All-events SDK coverage

The Teams catalog includes 11 events, but the latest published
`Azure.Connectors.Sdk` (`0.14.0-preview.1`) supplies strongly typed trigger payload
models for only the four events above. Those events use the exact SDK types;
the other seven use explicitly approved raw JSON `string` payloads until the SDK
publishes event-specific wrappers. They log only the event name, never raw content.

| Catalog event | Connector operation | Strongly typed SDK trigger payload |
| --- | --- | --- |
| New channel message | `OnNewChannelMessage` | `TeamsOnNewChannelMessageTriggerPayload` |
| Mentioned in a channel message | `OnNewChannelMessageMentioningMe` | `TeamsOnNewChannelMessageMentioningMeTriggerPayload` |
| Team member added | `OnGroupMembershipAdd` | `TeamsOnTeamMemberAddedTriggerPayload` |
| Team member removed | `OnGroupMembershipRemoval` | `TeamsOnTeamMemberRemovedTriggerPayload` |
| New chat message | `WebhookChatMessageTrigger` | Missing |
| New message in a chat or channel | `WebhookNewMessageTrigger` | Missing |
| @mentioned | `WebhookAtMentionTrigger` | Missing |
| Keywords mentioned | `WebhookKeywordTrigger` | Missing |
| Message reaction | `WebhookMessageReactionTrigger` | Missing |
| Recording available | `RecordingTrigger` | Missing |
| Transcript available | `TranscriptTrigger` | Missing |

**All-11 strongly typed support needs SDK model additions.** The seven raw-JSON
handlers are implemented in `AdditionalTeamsFunctions.cs` in each sample.
The extension's
[operation mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md#microsoft-teams-connector)
also currently identifies their .NET payloads as raw strings.
Types named `WebhookChatMessageTriggerInput`, `CallRecordingResponse` or
`CallTranscriptResponse` are input/action-response models, not substitutes for
trigger callback envelopes.

Registration also requires explicit source configuration:
the chat/channel/mention/keyword/reaction operations use dynamic scopes and
filters; recording/transcript events use `scopeType` and dynamic `body` values.
These must come from the connector's actual configuration rather than guessed
schemas or enums. The parameterless chat trigger monitors all chats the account
belongs to, so it requires explicit scope approval rather than automatic
registration for a channel-only sample.

| Missing event-specific SDK wrapper for operation | Connector response schema |
| --- | --- |
| `WebhookChatMessageTrigger` | `ChatMessageWebhookResponseSchema`: `value[]` with conversation/message IDs and message links |
| `WebhookNewMessageTrigger` | Dynamic output schema |
| `WebhookAtMentionTrigger` | Dynamic output schema |
| `WebhookKeywordTrigger` | Dynamic output schema |
| `WebhookMessageReactionTrigger` | `MessageReactionWebhookResponseSchema`: scope/message/user IDs and reaction |
| `RecordingTrigger` | `RecordingWebhookResponseSchema`: artifact/meeting/call IDs, organizer identity, content URL and timestamps |
| `TranscriptTrigger` | `TranscriptWebhookResponseSchema`: artifact/meeting/call IDs, organizer identity, content URL and timestamps |

These are confirmed gaps in the published SDK's event-specific callback wrappers,
not proposed type names. Schema names and fields come from the
[Teams connector reference](https://learn.microsoft.com/connectors/teams/#triggers)
and its Definitions section.
The [SDK source at commit `1d9ce97`](https://github.com/Azure/Connectors-NET-SDK/blob/1d9ce974172e97862fee81dd29682ebfc5ac50d5/src/Azure.Connectors.Sdk/Generated/TeamsExtensions.cs#L3333-L3388)
also defines only those four typed callbacks. New operation constants or
registration input metadata do not supply the missing event payload models.

The four original events are registered by default. To register all 11, configure
all seven entries using the chosen sample's `infra/additional-triggers.example.json`
and README. Unselected Poll functions are disabled; broad chat, meeting and
recording subscriptions are never enabled implicitly.

Poll versus Webhook is the Connector Namespace's **delivery to Functions**, not
the Teams connector's upstream change-detection mechanism. The existing Teams
operation IDs are preserved in both modes. A `Webhook` prefix in an operation name
describes the source subscription, not the namespace's delivery to Functions.

Each function logs only the trigger name and, for typed events, message/member count. There is no
Blob output binding, payload serialization, or application output container.
Storage remains necessary for the Functions host and deployment packages.
Connector payload collections are independent of Poll invocation batching; these
samples do not enable batched invocation.

Run commands inside the chosen subfolder, not this folder. Each subfolder includes
its own project, package feed, host configuration, deployment templates, settings
example, and license, and can be copied to a separate repository.

Existing Teams code and deployment files have moved to `webhook`. For an existing
deployment, preserve the same azd environment values and environment name when
running from that folder; the resource naming inputs have not changed.
Do not use the same environment for Poll and Webhook samples.

See the [Teams connector reference](https://learn.microsoft.com/connectors/teams/)
and [connector delivery configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md).
