# SharePoint Online Connector Samples (.NET)

Choose how the Connector Namespace delivers events to Azure Functions:

| Sample | Delivery | Local development |
| --- | --- | --- |
| [Polling](polling/) | Function host receives events by polling the namespace | Outbound connection only; no tunnel required |
| [Webhook](webhook/) | Namespace calls the function's HTTPS callback | Public HTTPS tunnel required for real events |

Both samples include ten non-deprecated triggers with typed SDK payloads and
receipt logging only. Build and deploy from the selected folder using different
azd environment names. See each README for trigger documentation and setup.
