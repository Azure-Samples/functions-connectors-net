# Generic Connector Polling Trigger (.NET)

This standalone sample uses the untyped `ConnectorTrigger` binding with
`DeliveryMode = Poll`. `OnGenericConnectorEvent` receives each event as a raw JSON
`string` and logs only its function name and payload length. It neither
deserializes the payload into an SDK model nor writes event data to Blob Storage.
There is no `Azure.Connectors.Sdk` or Storage Blobs output package.

The host connects outbound to a Connector Namespace to receive and acknowledge
events. No callback URL, system key, or development tunnel is needed.

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)
- [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) and the
  [Connector Namespace CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli)
  to manage your connection and trigger configuration
- [Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite)
  for local Functions host storage
- An Azure Connector Namespace, an authorized connection, and an enabled trigger
  configuration with service `deliveryMode: "Poll"` for an operation that supports
  Poll delivery

The sample deliberately does not choose a connector, operation, or authorization
scheme. The generic binding does not make an arbitrary operation support polling.
Configure the connection and operation-specific parameters according to your
connector's reference. See the extension's
[Poll registration guide](https://github.com/Azure/azure-functions-connector-extension/blob/main/.github/skills/poll-trigger-registration/SKILL.md)
for trigger configuration requests and access policies.

Grant connection-level access policies to both the Connector Namespace identity
that runs the upstream trigger and the identity that runs this sample (the
signed-in developer locally or Function App managed identity in Azure).

## Configure and run locally

Run all commands from this folder (`genericApp\polling` in the sample collection):

```powershell
az login
Copy-Item local.settings.example.json local.settings.json
```

In the ignored `local.settings.json`, replace these placeholders:

| Setting | Value |
| --- | --- |
| `ConnectorNamespace__pollingEndpoint` | Endpoint derived from the service-generated `pollingEndpoints.receiveUri` below |
| `GenericTriggerConfigName` | The name of your existing enabled Poll trigger configuration |

| Service Receive URI | Polling endpoint setting |
| --- | --- |
| `https://<host>/api/triggerconfigs/<name>/receive` | `https://<host>` |
| `https://<host>/api/connectorGateways/<id>/triggerconfigs/<name>/receive` | `https://<host>/api/connectorGateways/<id>` |

Preserve the service-provided host and gateway ID. Do not include an operation
path, query string, or standalone `/api` suffix in the setting.

The binding is:

```csharp
[ConnectorTrigger(
    DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
    Connection = "ConnectorNamespace",
    TriggerConfigName = "%GenericTriggerConfigName%")]
string payload
```

`Connection` is an app-setting prefix, not the connector connection resource name.
The trigger configuration selects the connector, operation, and parameters;
the C# function name does not select them. The same handler can receive events
from different connectors by pointing it at the corresponding trigger
configuration. Use separate listeners/configurations to monitor multiple sources.
This sample uses single-event invocation, not batching.

Start Azurite in a separate terminal, then:

```powershell
dotnet build
func start
```

The local developer credential is used when `ConnectorNamespace__credential` and
identity selectors are omitted. Do not copy Azure managed-identity settings into
local settings. There is no local emulator for the Connector Namespace: source
events still require real Azure resources and a working connector connection.

## Deploy to an existing Function App

Create or use a .NET 10 isolated Function App with Functions host storage and the
deployment storage required by its hosting plan. This sample includes no `azd`
infrastructure because connector provisioning and authorization are scenario-specific.
From this folder, publish with:

```powershell
func azure functionapp publish <function-app-name>
```

Configure these Function App settings separately; publishing does not upload
`local.settings.json`:

| Setting | Value |
| --- | --- |
| `FUNCTIONS_WORKER_RUNTIME` | `dotnet-isolated` (where required by the hosting plan) |
| `ConnectorNamespace__pollingEndpoint` | The endpoint used above |
| `GenericTriggerConfigName` | Your Azure Poll trigger configuration name |
| `ConnectorNamespace__credential` | `managedidentity` |
| `ConnectorNamespace__clientId` | User-assigned managed identity client ID; omit for system-assigned identity |

Enable the selected identity on the app and grant it a connection-level access
policy. Retain the app's `AzureWebJobsStorage` configuration (or its
identity-based `AzureWebJobsStorage__*` settings) and deployment storage. Azurite's
`UseDevelopmentStorage=true` is only for local use. Optionally configure
`APPLICATIONINSIGHTS_CONNECTION_STRING` for telemetry.

## Verify delivery

Cause an event for the configured connector operation and allow time for upstream
polling. The logs should show `OnGenericConnectorEvent (generic API) trigger received.`
and `Payload length: ... chars`. No event body or output blob is produced.

Delivery is at least once. A successful invocation is acknowledged by the extension;
failed invocations can be redelivered. This sample only logs and does not
deduplicate. Raw `string` binding does not expose the Poll `MessageId`; use
`ConnectorEvent<T>` if your application needs delivery metadata for idempotency.

Do not run local and deployed listeners against the same trigger configuration
when expecting every event locally: they compete for messages. Use a separate
configuration/environment for isolated testing.

Remove resources created for testing using your provisioning method. Do not delete
a shared namespace or connection used by other applications.

## References

- [Connector trigger configuration and payload types](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md)
- [Typed Office 365 polling sample](../../office365App/polling/README.md)
