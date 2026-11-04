# Generic Connector Triggers (.NET)

Choose how the Connector Namespace delivers events to Azure Functions:

| Sample | Delivery | Local development |
| --- | --- | --- |
| [Polling](polling/) | Function host receives events by polling the namespace | Outbound connection only; no tunnel required |
| [Webhook](webhook/) | Namespace calls the function's HTTPS callback | Public HTTPS tunnel required for real events |

Connector-neutral samples for Connector Namespace triggers. See each sample's README for setup and supported triggers.
