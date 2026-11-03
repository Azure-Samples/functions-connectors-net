# Microsoft Dataverse Connector Samples (.NET)

Choose how the Connector Namespace delivers events to Azure Functions:

| Sample | Delivery | Local development |
| --- | --- | --- |
| [Polling](polling/) | Function host receives events by polling the namespace | Outbound connection only; no tunnel required |
| [Webhook](webhook/) | Namespace calls the function's HTTPS callback | Public HTTPS callback required for real events |

Both samples include combined row changes, action-performed events, and three opt-in separate row-added, row-modified and row-deleted operations exposed by Connector Namespace. Combined row changes are enabled by default. See each sample's README for setup and supported triggers.
