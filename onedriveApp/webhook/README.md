# OneDrive for Business Webhook Triggers (.NET)

Azure Functions sample using [Azure.Connectors.Sdk](https://www.nuget.org/packages/Azure.Connectors.Sdk)
and the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector).
The Connector Namespace delivers authenticated events to the function's public HTTPS callback.
Each function logs the trigger name and, for typed batches, the item count
(for example, `Received OnNewFile trigger (2 items)`). No item metadata, file
content, or payload length is logged. Storage is required for Functions host state
and deployment.

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnNewFileContent` | [`OnNewFileV2`](https://learn.microsoft.com/connectors/onedriveforbusiness/#when-a-file-is-created) | File created, including content |
| `OnUpdatedFileContent` | [`OnUpdatedFileV2`](https://learn.microsoft.com/connectors/onedriveforbusiness/#when-a-file-is-modified) | File modified, including content |
| `OnNewFile` | [`OnNewFilesV2`](https://learn.microsoft.com/connectors/onedriveforbusiness/#when-a-file-is-created-(properties-only)) | File created (properties only) |
| `OnUpdatedFile` | [`OnUpdatedFilesV2`](https://learn.microsoft.com/connectors/onedriveforbusiness/#when-a-file-is-modified-(properties-only)) | File modified (properties only) |

Properties-only events use typed SDK models. The SDK has no payload models for
the binary-content events (`type: string, format: binary` upstream); those bind
raw JSON as `string` and log only the trigger name, without parsing for a count.

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

Run from this folder, using a different environment name from the polling sample:

```powershell
az login
azd auth login
azd env new onedrive-webhook
azd up
```

Complete OAuth in the browser opened by the hook, wait for **Connected**, and
select the folder to monitor. Non-interactive runs require `ONEDRIVE_FOLDER_ID`
set to a connector folder ID, not a name/path; use `root` explicitly for root.
Selection errors do not fall back to root.

## Optional configuration

Set environment values with `azd env set <setting> <value>` before `azd up`.

| Setting / action | Use |
| --- | --- |
| `ONEDRIVE_FOLDER_ID` | Skip interactive folder selection; required for unattended runs |
| `CONNECTOR_NAMESPACE_LOCATION` | Namespace region; default `westcentralus` |
| `TELEMETRY_LOCATION` | Application Insights/Log Analytics region; default `eastus2` because Application Insights is unavailable in `westcentralus` |
| Bash hook | In `azure.yaml`, set `shell: sh` and `run: bash ./infra/scripts/postdeploy.sh` |
| Rerun setup | `azd hooks run postdeploy`, or `bash ./infra/scripts/postdeploy.sh` |

## Local development

Requires an authorized Azure connector connection.

1. Prepare `local.settings.json`.

   Use the ignored file generated during `azd up`; existing settings are preserved.
   Only if the file is missing, rerun setup:

   ```powershell
   azd hooks run postdeploy
   ```

2. Start Azurite in a separate terminal:

   ```powershell
   azurite
   ```

3. Build and start the host with authentication enabled:

   ```powershell
   dotnet build
   func start --enableAuth
   ```

4. Configure a public HTTPS tunnel and each function's callback using the
   [webhook configuration guide](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md#webhook-delivery).

**Security:** Use the local `connector_extension` system key and keep `--enableAuth` enabled while the tunnel is public.

After testing locally, rerun `azd hooks run postdeploy` to restore Azure delivery, then close the tunnel.

Use [polling](../polling/README.md) to avoid a tunnel.

## Verify

Check the connection is **Connected** and all four triggers are **Enabled** in
[Connector Namespaces](https://connectors.azure.com/).
Create a file smaller than 50 MB and then modify it in the selected folder.
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

Moving a file within OneDrive does not create a new-file event.

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md#onedrive-for-business-connector)
- [OneDrive for Business connector reference](https://learn.microsoft.com/connectors/onedriveforbusiness/)
