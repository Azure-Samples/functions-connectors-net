# OneDrive for Business Polling Triggers (.NET)

Azure Functions sample using [Azure.Connectors.Sdk](https://www.nuget.org/packages/Azure.Connectors.Sdk)
and the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector)
with `DeliveryMode = Poll`. The host receives events outbound from the Connector
Namespace; no public callback or tunnel is required. Each function logs the trigger
name and, for typed batches, the item count (for example,
`Received OnNewFile trigger (2 items)`).

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnNewFileContent` | [`OnNewFileV2`](https://learn.microsoft.com/connectors/onedriveforbusiness/#when-a-file-is-created) | File created, including content |
| `OnUpdatedFileContent` | [`OnUpdatedFileV2`](https://learn.microsoft.com/connectors/onedriveforbusiness/#when-a-file-is-modified) | File modified, including content |
| `OnNewFile` | [`OnNewFilesV2`](https://learn.microsoft.com/connectors/onedriveforbusiness/#when-a-file-is-created-(properties-only)) | File created (properties only) |
| `OnUpdatedFile` | [`OnUpdatedFilesV2`](https://learn.microsoft.com/connectors/onedriveforbusiness/#when-a-file-is-modified-(properties-only)) | File modified (properties only) |

Properties-only events use typed SDK models. The SDK has no payload models for
the binary-content events (`type: string, format: binary` upstream); those bind
raw JSON as `string` and log only the trigger name, without parsing for a count.
No item metadata, file content, or payload length is logged.

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download), [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75+,
  and [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd).
- PowerShell 7 (default hook), or Bash with `jq` for the alternative hook.
- For local development: [Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local)
  and [Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite).
- A OneDrive for Business account and permission to complete OAuth consent.
- [Connector Namespace CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli):

  ```powershell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

  Bash: `curl -fsSL https://aka.ms/connector-namespace-cli-install | sh`.

## Deploy to Azure

Run from this folder, using a different environment name from the webhook sample.
Use the **connector folder ID**, not a name/path; set `root` explicitly to monitor
the root folder. See [Folder ID setup](#folder-id-setup) if you need to resolve it.

```powershell
az login
azd auth login
azd env new onedrive-polling
azd env set ONEDRIVE_FOLDER_ID <connector-folder-id>
azd up
```

Complete OAuth in the browser opened by the hook and wait for **Connected**.

**Cost:** Four 2048 MB always-ready instances (one per function) incur ongoing
baseline charges while idle to keep the Poll listeners running.

## Optional configuration

Set environment values with `azd env set <setting> <value>` before `azd up`.

| Setting / action | Use |
| --- | --- |
| `ONEDRIVE_FOLDER_ID` | Connector folder ID; defaults to `root` if omitted |
| `CONNECTOR_NAMESPACE_LOCATION` | Namespace region; default `westcentralus` |
| `TELEMETRY_LOCATION` | Application Insights/Log Analytics region; default `eastus2` because Application Insights is unavailable in `westcentralus` |
| Bash hook | In `azure.yaml`, set `shell: sh` and `run: bash ./infra/scripts/postdeploy.sh`; requires `jq` |
| Rerun setup | `azd hooks run postdeploy`, or `bash ./infra/scripts/postdeploy.sh` |
| Regenerate local settings | Run the PowerShell script with `-ForceLocalSettings`, or Bash with `--force-local-settings`; otherwise existing settings are preserved |

### Folder ID setup

Resolve the ID through an authorized connection before provisioning. If you have none:

1. Deploy the [webhook sample](../webhook/README.md) in a separate environment and complete OAuth/folder selection.
2. From the webhook folder, read the selected folder ID:

   ```powershell
   azd env get-value ONEDRIVE_FOLDER_ID
   ```

3. Use that ID in the polling deployment commands above.

When no longer needed, remove the selected bootstrap environment from the webhook folder:

```powershell
azd down --purge
```

## Local development

Requires real Azure connector resources.

If the Function App is already deployed, stop it before running locally to avoid competing listeners.

1. Prepare `local.settings.json`.

   Use the ignored file generated during `azd up`, containing the endpoint and four config names.
   Sign in as the authorized developer:

   ```powershell
   az login
   ```

   Only if the file is missing, run `azd hooks run postdeploy` from this folder's selected environment.
   Existing files are preserved; see Optional configuration to regenerate changed settings.

2. Start Azurite in a separate terminal:

   ```powershell
   azurite
   ```

3. Build and start the local host:

   ```powershell
   dotnet build
   func start
   ```

Use developer credentials locally, not deployed managed-identity settings.

## Verify

Check the connection is **Connected** and all four triggers are **Enabled** in
[Connector Namespaces](https://connectors.azure.com/).
Create a file smaller than 50 MB and then modify it in the monitored folder.
Allow time for connector detection and telemetry ingestion. In the deployed
Application Insights resource, open **Logs** and run this query to check all four
function names across instances:

```kusto
traces
| where timestamp > ago(1h)
| where message startswith "Received On"
| project timestamp, message, cloud_RoleInstance
| order by timestamp asc
```

See [Application Insights queries](https://learn.microsoft.com/azure/azure-functions/analyze-telemetry-data).
After verification, clean up from this sample's selected environment:

```powershell
azd down --purge
```

Delivery is at least once; moving a file within OneDrive does not create a new-file
event.

## More

- [Poll configuration and identity/endpoint setup](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md#poll-delivery)
- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md#onedrive-for-business-connector)
- [OneDrive for Business connector reference](https://learn.microsoft.com/connectors/onedriveforbusiness/)
