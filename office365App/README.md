# Office 365 Outlook Connector Samples (.NET)

Choose how the Connector Namespace delivers events to Azure Functions:

| Sample | Delivery | Local development |
| --- | --- | --- |
| [Webhook](webhook/) | Namespace calls the function's HTTPS callback | Public HTTPS tunnel required for real events |
| [Polling](polling/) | Function host receives events by polling the namespace | Outbound connection only; no tunnel required |

Both samples demonstrate new email, flagged email, email mentioning you, new
calendar event, and upcoming event triggers, writing their payloads to Blob Storage.

Each folder contains its own project, infrastructure, scripts, configuration
templates, license, and setup instructions. Build, run, and deploy from the selected
folder, not this directory. Either folder's contents can be copied into an
independent repository without any dependencies on this collection.

Use different azd environment names for the two samples to keep deployments
independent. See each sample's README for prerequisites and local setup.
