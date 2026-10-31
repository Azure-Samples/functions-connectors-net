# Generic Connector Polling Trigger (.NET)

`OnGenericConnectorEvent` receives raw JSON through `[ConnectorTrigger] string
payload` with `DeliveryMode = Poll`, logging only the trigger name per invocation.
Generic intentionally uses no SDK model. No public callback or
tunnel is needed.

## Prerequisites

Requires .NET 10 SDK, Functions Core Tools v4, Azure CLI, and Azurite for local storage.
Use an existing authorized Connector Namespace connection and
enabled Poll trigger configuration; this sample has no `azd` provisioning or
postdeploy hooks. Follow the [Poll setup and access-policy guide](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md#poll-delivery).
Both the namespace identity and receiving developer/app identity need connection access.

## Deploy to Azure

Use an existing .NET 10 isolated Function App with host/deployment storage.
Configure its settings:

| Setting | Value |
| --- | --- |
| `GenericTriggerConfigName` | Existing enabled Poll trigger configuration name |
| `ConnectorNamespace__pollingEndpoint` | Base derived from its service `pollingEndpoints.receiveUri` |
| `ConnectorNamespace__credential` | `managedidentity`; enable the app's identity and grant connection access |
| `ConnectorNamespace__clientId` | User-assigned identity client ID; omit for system-assigned identity |

Publish from this folder:

```shell
az login
func azure functionapp publish <function-app-name>
```

Local settings are not published. Use separate trigger configurations for separate
delivery environments.

The retained Flex E2E setup uses **one billed always-ready
instance**, including while idle ([pricing](https://azure.microsoft.com/pricing/details/functions/)):

```shell
az functionapp scale config always-ready set --subscription <subscription-id> --resource-group <resource-group> --name <function-app> --settings function:ongenericconnectorevent=1
az functionapp scale config show --subscription <subscription-id> --resource-group <resource-group> --name <function-app> --query alwaysReady
```

## Optional configuration

| Option | Configuration |
| --- | --- |
| Verified always-ready setup | PowerShell 7: `infra/scripts/set-always-ready.ps1 -SubscriptionId <id> -ResourceGroupName <group> -FunctionAppName <app>`; retains the same paid instance |
| Telemetry | Set `APPLICATIONINSIGHTS_CONNECTION_STRING` |
| Entra telemetry | Also set `APPLICATIONINSIGHTS_AUTHENTICATION_STRING=Authorization=AAD`, grant Monitoring Metrics Publisher, and set `AZURE_CLIENT_ID` for a user-assigned identity; the worker uses `DefaultAzureCredential` |

## Local development

1. Prepare `local.settings.json`.
   If absent, copy `local.settings.example.json`; otherwise preserve existing values.
2. Set `GenericTriggerConfigName` and `ConnectorNamespace__pollingEndpoint`.
   Derive the endpoint from the service's `pollingEndpoints.receiveUri`:

   | Receive URI | Endpoint setting |
   | --- | --- |
   | `https://<host>/api/triggerconfigs/<name>/receive` | `https://<host>` |
   | `https://<host>/api/connectorGateways/<id>/triggerconfigs/<name>/receive` | `https://<host>/api/connectorGateways/<id>` |

   Preserve the host/gateway; omit operation paths and queries. The same rule
   applies in Azure. `ConnectorNamespace` is a setting prefix, not a connection name.
3. Omit managed-identity settings locally and sign in with your developer identity:

   ```shell
   az login
   ```

4. Start Azurite for Functions storage. `UseDevelopmentStorage=true` is local only.

If the Function App is already deployed, stop it before running locally to avoid competing listeners.
Separate trigger configurations also provide isolated testing.

5. Build and start from this folder:

   ```shell
   dotnet build
   func start
   ```

## Verify

Cause an event for your configured operation. The approved E2E example uses
[Azure Blob add/modify (properties only) V2](https://learn.microsoft.com/connectors/azureblob/#when-a-blob-is-added-or-modified-(properties-only)-(v2));
the handler itself remains connector-neutral. Expect `OnGenericConnectorEvent
(generic API) trigger received.` for each invocation.

Confirm a successful function invocation, not merely a running HTTP/admin host.
Delivery is at least once; failures may be redelivered. This sample neither
deduplicates nor exposes Poll `MessageId` metadata. Do not delete shared resources
during cleanup.

## More

- [Connector trigger configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md)
- [Azure Blob source example reference](https://learn.microsoft.com/connectors/azureblob/)
