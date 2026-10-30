# OneDrive for Business webhook triggers (.NET)

Standalone Azure Functions sample preserving webhook delivery for the OneDrive
for Business connector. The Connector Namespace posts events to the Functions
connector webhook, authenticated with the `connector_extension` system key.

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnNewFileContent` | `OnNewFileV2` | File created, including content |
| `OnUpdatedFileContent` | `OnUpdatedFileV2` | File modified, including content |
| `OnNewFile` | `OnNewFilesV2` | File created (properties only) |
| `OnUpdatedFile` | `OnUpdatedFilesV2` | File modified (properties only) |

Content operations receive raw JSON as `string`; properties-only operations
receive typed SDK payloads. All four functions only log that the trigger was received.
SDK 0.14.0-preview.1 excludes binary-content triggers from its typed registry:
`OnNewFileV2` and `OnUpdatedFileV2` declare `type: string, format: binary`
responses upstream, with file metadata in response headers. There is no SDK
content-trigger payload model; those two raw bindings remain an explicit SDK
limitation, not fully strongly typed samples.
There is no Blob output binding or payload serialization. File content and
metadata are not logged. Storage is retained for Functions host state and
deployment artifacts, not connector outputs.
`NuGet.config` supplies the public Azure Functions package feed for standalone builds.

The connector skips files larger than 50 MB for the content operations, and moving
a file within OneDrive does not count as creating a new file.

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later
- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
- A OneDrive for Business account with permission to authorize the connection
- The [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli):

  ```powershell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

## Deploy to Azure

Run from this folder, using a different environment name from the polling sample:

```powershell
az login
azd auth login
azd env new onedrive-webhook
azd up
```

Bicep provisions the Flex Consumption .NET 10 Function App, managed identity,
host/deployment storage, Application Insights/Log Analytics, Connector Namespace,
and OneDrive connection. The post-deploy hook authorizes the connection, lets
you select a OneDrive folder, and creates the four trigger configurations with
authenticated callbacks. To preselect the folder instead of browsing:

```powershell
azd env set ONEDRIVE_FOLDER_ID root
azd hooks run postdeploy
```

Use the connector folder ID, not a display path.
The hook does not silently select root if folder selection is unavailable;
set `ONEDRIVE_FOLDER_ID` explicitly for non-interactive runs.
The namespace defaults to
`westcentralus`; override via `CONNECTOR_NAMESPACE_LOCATION`.
Application Insights/Log Analytics default to `eastus2` because Application
Insights is unavailable in `westcentralus`. Override with
`azd env set TELEMETRY_LOCATION <supported-region>` without moving the Function
App or Connector Namespace.

## Verify

Check the [Connector Namespaces portal](https://connectors.azure.com/) for a
**Connected** OneDrive connection and all four triggers **Enabled**. Create a file
smaller than 50 MB and modify it in the monitored folder. Allow time for connector detection,
then inspect the logs for `Received OnNewFileContent trigger`,
`Received OnUpdatedFileContent trigger`, `Received OnNewFile trigger`, and
`Received OnUpdatedFile trigger`:

```powershell
az functionapp log tail -g <resource-group> -n <function-app>
```

## Local development

Install Azure Functions Core Tools v4 and start Azurite for local host storage.
Copy `local.settings.example.json` to ignored `local.settings.json`, then run
`dotnet build` and `func start --enableAuth`. Live webhook events require a public
HTTPS tunnel and a trigger callback pointing to
`https://<public-host>/runtime/webhooks/connector?functionName=<FunctionName>`
with the connector system key supplied separately in `notificationDetails`
authentication (`QueryString`, `code`).
Do not expose an unauthenticated tunnel or commit system keys.
See the [webhook configuration guide](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md#webhook-delivery).
Use the [polling sample](../polling/README.md) for local development without a tunnel.

Run `azd down --purge` from this folder when finished.

## References

- [Operation-to-payload mappings](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md#onedrive-for-business-connector)
- [OneDrive for Business connector](https://learn.microsoft.com/connectors/onedriveforbusiness/)
