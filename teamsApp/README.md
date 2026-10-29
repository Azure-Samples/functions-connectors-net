# Microsoft Teams Connector Triggers (.NET)

Choose a standalone sample:

| Sample | Delivery to Functions | Local development |
| --- | --- | --- |
| [Polling](polling/README.md) | Function host receives and acknowledges events outbound from a Connector Namespace | No public callback or tunnel |
| [Webhook](webhook/README.md) | Connector Namespace calls the function's authenticated callback | Requires a public HTTPS callback |

Both samples implement the same four Teams operations:

| Function / connector operation | Source |
| --- | --- |
| `OnNewChannelMessage` | New root message in the configured channel |
| `OnNewChannelMessageMentioningMe` | Channel message mentioning the authorized user |
| `OnGroupMembershipAdd` | Member added to the configured team |
| `OnGroupMembershipRemoval` | Member removed from the configured team |

Poll versus Webhook is the Connector Namespace's **delivery to Functions**, not
the Teams connector's upstream change-detection mechanism. The existing Teams
operations and typed payloads are used in both modes; this sample does not
substitute the separate `Webhook*` Teams operations.

Each function logs only the trigger name and message/member count. There is no
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
