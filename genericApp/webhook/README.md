# Generic Connector Webhook Triggers (.NET)

This standalone sample retains five untyped webhook handlers. Each uses
`[ConnectorTrigger] string payload`, receives the raw JSON, and logs only its
function name and payload length. No SDK model, payload serialization, Blob output
binding, or Storage Blobs output package is used.

| Function | Example source |
| --- | --- |
| `OnGenericOffice365NewEmail` | Office 365 email |
| `OnGenericAzureBlobUpdated` | Azure Blob changes |
| `OnGenericSharepointNewFile` | SharePoint files |
| `OnGenericTeamsChannelMessage` | Teams channel messages |
| `OnGenericCustomConnectorEvent` | Another supported connector operation |

These names are routing destinations, **not automatically provisioned
subscriptions**. Choose the supported operation and its parameters in your
Connector Namespace trigger configuration. A function name alone does not select
an operation. The custom handler is a generic destination, not a fictional custom
connector resource.

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)
- [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local)
- [Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite)
  for local Functions host storage
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) and the
  [Connector Namespace CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli)
- An Azure Connector Namespace with system-assigned identity enabled, an
  authorized connection, and enabled webhook trigger configurations for the
  operations you want to monitor

The sample includes no `azd` infrastructure or authorization script because those
depend on your chosen connector. Follow the extension's
[Webhook registration guide](https://github.com/Azure/azure-functions-connector-extension/blob/main/.github/skills/webhook-trigger-registration/SKILL.md)
for trigger configuration requests, callback authentication, and local tunnels.

## Run locally

Run from this folder (`genericApp\webhook` in the sample collection):

```powershell
Copy-Item local.settings.example.json local.settings.json
dotnet build
```

Start Azurite separately, then start the host:

```powershell
func start
```

For a local smoke test without an Azure source, post a synthetic JSON body directly
to a handler:

```powershell
Invoke-RestMethod -Method Post `
  -Uri 'http://localhost:7071/runtime/webhooks/connector?functionName=OnGenericCustomConnectorEvent' `
  -ContentType 'application/json' -Body '{"example":"event"}'
```

Verify the corresponding function-name and payload-length log entries. This only
checks local callback reception, not a real connector subscription.

Actual connector delivery requires a public HTTPS callback. If exposing the host
through a development tunnel, use `func start --enableAuth` and system-key
authentication. Never expose an unauthenticated local webhook. Register the tunnel
callback following the same authentication structure described below.

## Deploy to an existing Function App

Create or use a .NET 10 isolated Function App with Functions host storage and the
deployment storage required by its hosting plan. From this folder:

```powershell
func azure functionapp publish <function-app-name>
```

Retain the app's `AzureWebJobsStorage` (or identity-based
`AzureWebJobsStorage__*`) configuration and deployment storage. Removing the Blob
output binding does not remove these platform requirements. Do not use the local
Azurite connection string in Azure. Optionally configure
`APPLICATIONINSIGHTS_CONNECTION_STRING` for telemetry.
For Microsoft Entra-authenticated telemetry, also set
`APPLICATIONINSIGHTS_AUTHENTICATION_STRING` (for example `Authorization=AAD`).
The worker exporter then uses `DefaultAzureCredential`; assign its identity the
Monitoring Metrics Publisher role on Application Insights. For a user-assigned
identity, set `AZURE_CLIENT_ID` to its client ID for worker credential selection.

For each source you enable, configure the Connector Namespace trigger's
`notificationDetails.callbackUrl` as:

```text
https://<function-app-host>/runtime/webhooks/connector?functionName=<FunctionName>
```

Set `notificationDetails.authentication` to `type: "QueryString"`, `name: "code"`,
and `value` equal to the Function App's `connector_extension` **system key**.
The Functions host creates that key when the extension loads. Keep it separate
from the stored callback URL and never commit keys or real local settings.

Webhook is the default binding mode when `DeliveryMode` is omitted. Do not add Poll
endpoint or trigger-name settings: they are unnecessary for these webhook handlers.
Webhook-only reception does not require the Function/developer identity to have
connection access; code invoking connector actions would require it.

## Verify delivery

Cause a source event for each operation you configured. Look for its handler name
and `Payload length: ... chars` in local logs or Azure telemetry. The sample never
logs payload content or produces output blobs. Only configured sources send
events; the five handlers do not subscribe automatically.

Retries may produce duplicate log entries. Production processing should be
idempotent. Remove resources created for testing using your provisioning method,
without deleting shared namespaces or connections.

For outbound delivery without a public callback, use the separate
[polling sample](../polling/README.md).
