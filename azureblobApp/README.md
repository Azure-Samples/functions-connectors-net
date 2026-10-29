# Azure Blob connector triggers (.NET)

Two standalone Azure Functions apps demonstrate the Azure Blob connector's
`OnUpdatedFiles_V2` operation using `AzureBlobOnUpdatedFilesTriggerPayload`:

| Sample | Delivery | Local development |
| --- | --- | --- |
| [Polling](polling/README.md) | The Functions host receives and acknowledges queued events using managed identity | No public callback required |
| [Webhook](webhook/README.md) | The Connector Namespace sends events to the Functions callback | Requires a public HTTPS callback |

Both apps log invocation only: there is no Blob output binding and no payload is
written to storage. Azure Blob remains the **source connector**. Storage for the
Functions host and deployment package is still required, and a separate source
storage account contains the monitored `connector-input` container.

Use distinct `azd` environment names and run commands from the selected sample
directory, not this directory. The Azure Blob source connection uses interactive
Entra ID OAuth consent. Managed identity authenticates the deployed Functions host
to its runtime storage and, for Poll delivery, to the Connector Namespace; it does
not replace the source account's OAuth connection.

The existing app has moved to `webhook/`. Select `polling/` for the callback-free
host-pull sample. Connector service polling of Azure Blob and delivery to the
Functions host are separate concepts: webhook delivery remains supported.
