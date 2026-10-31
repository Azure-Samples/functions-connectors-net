# Generic Connector Webhook Triggers (.NET)

Each handler receives raw JSON via `[ConnectorTrigger] string payload` and logs
only the trigger name per invocation. Generic intentionally uses no SDK models.
Function names route callbacks; they do not subscribe automatically.

| Function | Example supported operation |
| --- | --- |
| `OnGenericOffice365NewEmail` | [New email (V3)](https://learn.microsoft.com/connectors/office365/#when-a-new-email-arrives-(v3)) |
| `OnGenericAzureBlobUpdated` | [Blob added/modified, properties only (V2)](https://learn.microsoft.com/connectors/azureblob/#when-a-blob-is-added-or-modified-(properties-only)-(v2)) |
| `OnGenericSharepointNewFile` | [File created, properties only](https://learn.microsoft.com/connectors/sharepointonline/#when-a-file-is-created-(properties-only)) |
| `OnGenericTeamsChannelMessage` | [New channel message](https://learn.microsoft.com/connectors/teams/#when-a-new-channel-message-is-added) |
| `OnGenericCustomConnectorEvent` | Another supported connector operation |

These are illustrative mappings, not provisioned resources or deprecated native
webhook operations. Choose the supported operation and parameters in the Connector
Namespace trigger configuration; generic binding only changes the C# payload type.

## Prerequisites

Requires .NET 10 SDK, Functions Core Tools v4, Azure CLI, and Azurite for local storage.
Use an existing Connector Namespace with system-assigned
identity, authorized connection, and enabled webhook trigger configurations.
There are no `azd` provisioning or postdeploy hooks. Follow the
[webhook configuration guide](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md#webhook-delivery).

## Deploy to Azure

1. Publish from this folder to an existing .NET 10 isolated Function App:

   ```shell
   func azure functionapp publish <function-app-name>
   ```

   Retain Azure Functions host/deployment storage. Local settings are not published.
2. Set each trigger's `notificationDetails.callbackUrl`:

   ```text
   https://<function-app-host>/runtime/webhooks/connector?functionName=<FunctionName>
   ```

3. Set `notificationDetails.authentication` to `type: "QueryString"`, `name: "code"`,
   and `value` equal to the host's `connector_extension` system key.

Keep the key separate from the stored callback URL and never commit keys.
Use separate trigger configurations for separate delivery environments.
No Poll endpoint or trigger-name app settings are required.

## Optional configuration

| Option | Configuration |
| --- | --- |
| Telemetry | Set `APPLICATIONINSIGHTS_CONNECTION_STRING` |
| Entra telemetry | Also set `APPLICATIONINSIGHTS_AUTHENTICATION_STRING=Authorization=AAD`, grant Monitoring Metrics Publisher, and set `AZURE_CLIENT_ID` for a user-assigned identity; the worker uses `DefaultAzureCredential` |

## Local development

1. Prepare `local.settings.json`.
   If absent, copy `local.settings.example.json`; otherwise preserve existing values.
2. Start Azurite for Functions storage. `UseDevelopmentStorage=true` is local only.
3. Build and start from this folder for a local smoke check:

   ```shell
   dotnet build
   func start
   ```

4. For real events, use a public HTTPS tunnel and restart the host with authentication:

   ```shell
   func start --enableAuth
   ```

5. Point a separate trigger configuration at the tunnel callback. Use the callback
   path and authentication fields above, with the local host's `connector_extension`
   system key.

Never expose an unauthenticated webhook or replace a shared deployed callback for
local testing.

## Verify

Cause a real source event for each configured operation. Expect the corresponding
handler's trigger-name log and successful callback. Retries may duplicate events; production
processing should be idempotent. Do not delete shared resources during cleanup.

Use the [polling sample](../polling/README.md) for outbound delivery without a callback.

## More

- [Connector trigger configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md)
- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
