# SharePoint Online Connector Samples (.NET)

| Sample | Delivery | Local development |
| --- | --- | --- |
| [Polling](polling/README.md) | Function host polls the namespace | Outbound connection; no tunnel |
| [Webhook](webhook/README.md) | Namespace calls the function's HTTPS callback | Public HTTPS tunnel |

Both samples demonstrate ten SharePoint triggers with typed SDK payloads, logging only trigger names and item counts. Use the child README for prerequisites, deployment, and local setup; deploy each sample with a different `azd` environment name.
