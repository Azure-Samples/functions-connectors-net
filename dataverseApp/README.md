# Microsoft Dataverse Connector Samples (.NET)

Choose how the Connector Namespace delivers events to Azure Functions:

| Sample | Delivery | Local development |
| --- | --- | --- |
| [Polling](polling/) | Function host receives events by polling the namespace | Outbound connection only; no tunnel required |
| [Webhook](webhook/) | Namespace calls the function's HTTPS callback | Public HTTPS callback required for real events |

Both samples log received events.

Combined row changes are enabled by default; separate added, modified and deleted events and action-performed events are opt-in.
