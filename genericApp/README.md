# Generic Connector Triggers (.NET)

These standalone samples receive connector payloads as raw JSON `string` values,
without `Azure.Connectors.Sdk` or connector-specific models.

Generic is the deliberate **untyped exception** in this collection.
Connector-specific samples use strongly typed SDK payloads; these samples instead
demonstrate receiving operations without a generated model. A raw JSON `string`
is not a strongly typed SDK payload.

| Sample | Delivery | Setup |
| --- | --- | --- |
| [polling](polling/README.md) | Outbound receive and acknowledgement; no callback or tunnel | Existing authorized connection and enabled Poll trigger configuration |
| [webhook](webhook/README.md) | Public HTTPS callback | Existing authorized connection and webhook trigger configuration |

Each folder contains its own project, host configuration, package sources, and
local settings template. Copy either folder on its own to build and run it.
Handlers log the function name and payload length only, never the payload itself,
and do not write event data to Blob Storage.

Generic binding changes the C# payload type, not the connector operation. Polling
selects an existing trigger configuration by name; webhook delivery routes by the
callback's `functionName`. Neither sample automatically discovers a connector or
provisions Azure resources. Choose the connector, operation, parameters, and
authorization appropriate to your scenario using the
[Connector Namespace CLI](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli).

Functions host storage (`AzureWebJobsStorage`) and Azure deployment storage remain
required; removing Blob output does not remove those platform requirements.
