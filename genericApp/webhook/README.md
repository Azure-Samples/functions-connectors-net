# Generic Connector Webhook Triggers (.NET)

Each handler receives raw JSON via `[ConnectorTrigger] string payload` and logs only the trigger name per invocation. Generic intentionally uses no SDK models. Function names route callbacks; they do not subscribe automatically.

| Function | Example supported operation |
| --- | --- |
| `OnGenericOffice365NewEmail` | [New email (V3)](https://learn.microsoft.com/connectors/office365/#when-a-new-email-arrives-(v3)) |
| `OnGenericAzureBlobUpdated` | [Blob added/modified, properties only (V2)](https://learn.microsoft.com/connectors/azureblob/#when-a-blob-is-added-or-modified-(properties-only)-(v2)) |
| `OnGenericSharepointNewFile` | [File created, properties only](https://learn.microsoft.com/connectors/sharepointonline/#when-a-file-is-created-(properties-only)) |
| `OnGenericTeamsChannelMessage` | [New channel message](https://learn.microsoft.com/connectors/teams/#when-a-new-channel-message-is-added) |
| `OnGenericCustomConnectorEvent` | Another supported connector operation |

These are illustrative mappings, not provisioned resources or deprecated native webhook operations. Choose the supported operation and parameters in the Connector Namespace trigger configuration; generic binding only changes the C# payload type.

## Prerequisites

Requires .NET 10 SDK, Functions Core Tools v4, Azure CLI, and Azurite for local storage. Use an existing Connector Namespace with system-assigned identity, authorized connection, and enabled webhook trigger configurations. There are no `azd` provisioning or postdeploy hooks. Follow the [webhook configuration guide](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md#webhook-delivery).

## Deploy to Azure

Enable the existing Function App's **system-assigned managed identity**. Use its principal ID for resource roles; keep the namespace's system-assigned identity.

| Host storage setting | Value |
| --- | --- |
| `AzureWebJobsStorage__credential` | `managedidentity` |
| `AzureWebJobsStorage__blobServiceUri`, `AzureWebJobsStorage__queueServiceUri`, `AzureWebJobsStorage__tableServiceUri` | Host storage account's Blob, Queue, and Table endpoints |

Grant the app principal Storage Blob Data Owner, Storage Queue Data Contributor, and Storage Table Data Contributor on host storage. For Flex deployment storage, use `SystemAssignedIdentity` authentication and grant Storage Blob Data Contributor on its container (the host account's Blob Data Owner role covers it if shared).

1. Publish from this folder to an existing .NET 10 isolated Function App:

   ```shell
   func azure functionapp publish <function-app-name>
   ```

   Retain Azure Functions host/deployment storage. Local settings are not published.
2. Set each trigger's `notificationDetails.callbackUrl`:

   ```text
   https://<function-app-host>/runtime/webhooks/connector?functionName=<FunctionName>
   ```

3. Set `notificationDetails.authentication` to `type: "QueryString"`, `name: "code"`, and `value` equal to the host's `connector_extension` system key.

Keep the key separate from the stored callback URL and never commit keys. Use separate trigger configurations for separate delivery environments. No Poll endpoint or trigger-name app settings are required.

## Optional configuration

| Option | Configuration |
| --- | --- |
| Telemetry | Set `APPLICATIONINSIGHTS_CONNECTION_STRING` |
| Entra telemetry | Set `APPLICATIONINSIGHTS_AUTHENTICATION_STRING=Authorization=AAD`; grant the app's system principal Monitoring Metrics Publisher on Application Insights. Set `ConnectorNamespace__credential=managedidentity` for the worker's independent identity-only section; omit it locally for developer credentials |

## Local development

1. Prepare `local.settings.json`. If absent, copy `local.settings.example.json`; otherwise preserve existing values.
2. Start Azurite for Functions storage. `UseDevelopmentStorage=true` is local only.
3. Build and start from this folder for a local smoke check:

   ```shell
   dotnet build
   func start --enableAuth
   ```

4. For real events, use a public HTTPS tunnel. Core Tools v4 bypasses key authentication locally by default; use `--enableAuth` as shown above before exposing the host publicly.

5. Point a separate trigger configuration at the tunnel callback. Use the callback path and authentication fields above, with the local host's `connector_extension` system key.

Never expose an unauthenticated webhook or replace a shared deployed callback for local testing.

## Verify

Cause a real source event for each configured operation. Expect the corresponding handler's trigger-name log and successful callback. Retries may duplicate events; production processing should be idempotent. Do not delete shared resources during cleanup.

Use the [polling sample](../polling/README.md) for outbound delivery without a callback.

## More

- [Connector trigger configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md)
- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [Flex system-assigned identity and storage reference](https://github.com/Azure-Samples/azure-functions-flex-consumption-samples/blob/main/IaC/bicep/main.bicep)
