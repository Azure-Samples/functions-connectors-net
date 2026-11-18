# Microsoft Dataverse Connector Samples (.NET)

Choose how the Connector Namespace delivers events to Azure Functions:

| Sample | Delivery | Local development |
| --- | --- | --- |
| [Polling](polling/) | Function host receives events by polling the namespace | Outbound connection only; no tunnel required |
| [Webhook](webhook/) | Namespace calls the function's HTTPS callback | Public HTTPS callback required for real events |

Both samples offer all five row-change and action-performed triggers. Interactive setup lists available source choices, saves your selections, and lets you skip individual triggers. Choose the combined row-change trigger or the separate row triggers to avoid overlapping events. See each sample's README for example prompts and reconfiguration.

[License](../LICENSE).
