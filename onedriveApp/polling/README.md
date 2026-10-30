# OneDrive for Business polling triggers (.NET)

Standalone Azure Functions sample using `DeliveryMode = Poll`. The host connects
outbound to a Connector Namespace to receive and acknowledge events; it needs no
public callback, function system key, or development tunnel.

| Function | Connector operation | Payload |
| --- | --- | --- |
| `OnNewFileContent` | `OnNewFileV2` | `string` (raw JSON with file content) |
| `OnUpdatedFileContent` | `OnUpdatedFileV2` | `string` (raw JSON with file content) |
| `OnNewFile` | `OnNewFilesV2` | `OneDriveForBusinessOnNewFilesTriggerPayload` |
| `OnUpdatedFile` | `OnUpdatedFilesV2` | `OneDriveForBusinessOnUpdatedFilesTriggerPayload` |

All four events shown by the OneDrive for Business connector are covered:
file creation and modification, each with content or properties only.
Content operations use raw JSON `string` bindings, as specified by the extension's
operation mappings; properties-only operations use typed SDK payloads.
The SDK 0.14.0-preview.1 trigger registry explicitly excludes binary-content
triggers. `OnNewFileV2` and `OnUpdatedFileV2` have upstream response schemas
`type: string, format: binary`, with file metadata in response headers; no SDK
content-trigger payload class is available. Strong typing for those two events
requires SDK support for the Connector Namespace binary callback envelope.
All functions simply log that
the trigger was received. No file content or metadata is logged or written to
Blob Storage. Poll delivery is at least once, so duplicate log entries are
possible. Production processing should be idempotent.

The connector skips files larger than 50 MB for the content operations, and moving
a file within OneDrive does not count as creating a new file.

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local)
- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later
- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) for the hook on all platforms
- [Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite) for local Functions host storage
- A OneDrive for Business account and permission to authorize the connection
- The [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli):

  ```powershell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

The sample uses connector extension `1.0.0`, which supports Poll delivery, and
the typed payloads in `Azure.Connectors.Sdk`.
`NuGet.config` supplies the public Azure Functions package feed so a copied sample
does not depend on parent or machine-specific package sources.

## Deploy to Azure

Run from this folder:

```powershell
az login
azd auth login
azd env new onedrive-polling
azd env set ONEDRIVE_FOLDER_ID root
azd up
```

`ONEDRIVE_FOLDER_ID` defaults to `root`. To monitor another folder, set its
connector folder identifier (not its display path) before provisioning. The
namespace defaults to `westcentralus`; change it with
`azd env set CONNECTOR_NAMESPACE_LOCATION <supported-region>`.

Bicep provisions a resource group, .NET 10 Flex Consumption Function App,
managed identity, storage account, Application Insights/Log Analytics, Connector
Namespace, OneDrive connection, and four enabled `deliveryMode: 'Poll'` trigger
configurations. It grants connection access separately to the namespace identity
(source detection), Function App identity (receive/acknowledge), and developer
identity (local receive/acknowledge). Storage is retained only for Functions
runtime state and deployment artifacts.

The post-deploy hook opens OAuth consent and creates ignored
`local.settings.json` if absent. Existing local settings are preserved.
To repeat consent/setup:

```powershell
azd hooks run postdeploy
```

## Run locally

Local development uses real Azure connector resources, not a OneDrive emulator.
Use resources from `azd up`, or provision an isolated local environment without
deploying function code:

```powershell
az login
azd auth login
azd env new onedrive-polling-local
azd env set ONEDRIVE_FOLDER_ID root
azd provision
pwsh -File .\infra\scripts\postdeploy.ps1
```

The hook supplies the deployed polling endpoint and all four trigger-config names.
Use `-ForceLocalSettings` to explicitly regenerate an existing settings file.
Start Azurite separately, then run:

```powershell
dotnet build
func start
```

Local listeners use the signed-in developer credentials. Do not copy Azure's
`ConnectorNamespace__credential=managedidentity` or `__clientId` into local
settings. A different developer needs a connection-level access policy.
Do not run local and deployed listeners against the same trigger configuration
when expecting every event locally: they are competing consumers.

### Existing namespace

Copy `local.settings.example.json` to ignored `local.settings.json`. Set the
endpoint from the service-generated `pollingEndpoints.receiveUri`, not from a
guessed hostname:

| Receive URI | `ConnectorNamespace__pollingEndpoint` |
| --- | --- |
| `https://<host>/api/triggerconfigs/<name>/receive` | `https://<host>` |
| `https://<host>/api/connectorGateways/<id>/triggerconfigs/<name>/receive` | `https://<host>/api/connectorGateways/<id>` |

Omit the operation path and query string. Set all four `*TriggerConfigName` values
to existing enabled Poll trigger configs for the authorized OneDrive connection.
`Connection = "ConnectorNamespace"` in the binding is a configuration prefix,
not the connection resource name. Both the namespace and receiving identity need
connection access policies. Poll trigger configs must not contain webhook
`notificationDetails`.

## Verify and clean up

Create a new file smaller than 50 MB, then modify it in the configured folder.
Allow time for OneDrive source detection and inspect the function logs for
`Received OnNewFileContent trigger`, `Received OnUpdatedFileContent trigger`,
`Received OnNewFile trigger`, and `Received OnUpdatedFile trigger`.
The sample does not create a `connector-messages` output container.

```powershell
az functionapp log tail -g <resource-group> -n <function-app>
azd down --purge
```

## References

- [Connector trigger configuration and Poll delivery](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md)
- [Operation-to-payload mappings](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md#onedrive-for-business-connector)
- [OneDrive for Business connector](https://learn.microsoft.com/connectors/onedriveforbusiness/)
