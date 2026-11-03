# Generic Connector Polling Trigger (.NET)

`OnGenericConnectorEvent` receives raw JSON through `[ConnectorTrigger] string payload` with `DeliveryMode = Poll`, logging only the trigger name per invocation. Generic intentionally uses no SDK model. No public callback or tunnel is needed.

## Prerequisites

Requires .NET 10 SDK, Functions Core Tools v4, Azure CLI, and Azurite for local storage. Use an existing authorized Connector Namespace connection and enabled Poll trigger configuration; this sample has no `azd` provisioning or postdeploy hooks. Follow the [Poll setup and access-policy guide](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md#poll-delivery). The receiving developer/app identity needs connection access.

## Deploy to Azure

Use an existing .NET 10 isolated Function App with host/deployment storage. Enable its **system-assigned managed identity** and use that app's principal ID for connection access and resource roles. Keep the namespace's system-assigned identity. Configure its settings:

| Setting | Value |
| --- | --- |
| `GenericTriggerConfigName` | Existing enabled Poll trigger configuration name |
| `ConnectorNamespace__pollingEndpoint` | Base derived from its service `pollingEndpoints.receiveUri` |
| `ConnectorNamespace__credential` | `managedidentity`; uses the app's system-assigned identity |
| `AzureWebJobsStorage__credential` | `managedidentity` |
| `AzureWebJobsStorage__blobServiceUri`, `AzureWebJobsStorage__queueServiceUri`, `AzureWebJobsStorage__tableServiceUri` | Host storage account's Blob, Queue, and Table endpoints |

Grant the app principal Storage Blob Data Owner, Storage Queue Data Contributor, and Storage Table Data Contributor on host storage. For Flex deployment storage, use `SystemAssignedIdentity` authentication and grant Storage Blob Data Contributor on its container (the host account's Blob Data Owner role covers it if shared).

Publish from this folder:

```shell
az login
func azure functionapp publish <function-app-name>
```

Local settings are not published. Use separate trigger configurations for separate delivery environments.

## Optional configuration

| Option | Configuration |
| --- | --- |
| Telemetry | Set `APPLICATIONINSIGHTS_CONNECTION_STRING` |
| Entra telemetry | Set `APPLICATIONINSIGHTS_AUTHENTICATION_STRING=Authorization=AAD`; grant the app's system principal Monitoring Metrics Publisher on Application Insights. The worker independently uses `ConnectorNamespace__credential=managedidentity`; omit identity settings locally for developer credentials |

## Local development

1. Prepare `local.settings.json`. If absent, copy `local.settings.example.json`; otherwise preserve existing values.
2. Set `GenericTriggerConfigName` and `ConnectorNamespace__pollingEndpoint`. Derive the endpoint from the service's `pollingEndpoints.receiveUri`:

   | Receive URI | Endpoint setting |
   | --- | --- |
   | `https://<host>/api/triggerconfigs/<name>/receive` | `https://<host>` |
   | `https://<host>/api/connectorGateways/<id>/triggerconfigs/<name>/receive` | `https://<host>/api/connectorGateways/<id>` |

   Preserve the host/gateway; omit operation paths and queries. The same rule applies in Azure. `ConnectorNamespace` is a setting prefix, not a connection name.
3. Omit managed-identity settings locally and sign in with your developer identity:

   ```shell
   az login
   ```

4. Start Azurite for Functions storage. `UseDevelopmentStorage=true` is local only.

If the Function App is already deployed, stop it before running locally to avoid competing listeners. Separate trigger configurations also provide isolated testing.

5. Build and start from this folder:

   ```shell
   dotnet build
   func start
   ```

## Verify

Cause an event for your configured operation. The approved E2E example uses [Azure Blob add/modify (properties only) V2](https://learn.microsoft.com/connectors/azureblob/#when-a-blob-is-added-or-modified-(properties-only)-(v2)); the handler itself remains connector-neutral. Expect `OnGenericConnectorEvent (generic API) trigger received.` for each invocation.

Confirm a successful function invocation, not merely a running HTTP/admin host. Delivery is at least once; failures may be redelivered. This sample neither deduplicates nor exposes Poll `MessageId` metadata. Do not delete shared resources during cleanup.

## More

- [Connector trigger configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md)
- [Azure Blob source example reference](https://learn.microsoft.com/connectors/azureblob/)
- [Flex system-assigned identity and storage reference](https://github.com/Azure-Samples/azure-functions-flex-consumption-samples/blob/main/IaC/bicep/main.bicep)
