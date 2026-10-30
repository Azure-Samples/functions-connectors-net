# Office 365 Outlook Connector Samples (.NET)

Choose how the Connector Namespace delivers events to Azure Functions:

| Sample | Delivery | Local development |
| --- | --- | --- |
| [Polling](polling/) | Functions polls the Connector Namespace | Outbound only; no tunnel |
| [Webhook](webhook/) | Namespace calls the HTTPS callback | Public HTTPS tunnel |

Both samples include seven non-deprecated triggers with typed SDK payloads and
logging of trigger names and item counts only. Build and deploy from the selected
folder using different azd environment names. See each README for trigger
documentation, limitations, setup, and costs.

Deprecated triggers are excluded. [License](../LICENSE).
