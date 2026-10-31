# Azure Blob Storage Webhook Triggers (.NET)

Azure Functions sample using [Azure.Connectors.Sdk](https://www.nuget.org/packages/Azure.Connectors.Sdk)
and the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector).
The Connector Namespace delivers events to the function's public HTTPS callback.
The handler uses `AzureBlobOnUpdatedFilesTriggerPayload` and logs only the trigger
name and item count.

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnUpdatedFile` | [`OnUpdatedFiles_V2`](https://learn.microsoft.com/connectors/azureblob/#when-a-blob-is-added-or-modified-(properties-only)-(v2)) | Blob added or modified (properties only) |

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later
- PowerShell 7.3 or later for the default hook, or Bash for the alternative script
- Azure permissions to deploy resources and role assignments and authorize the source connection
- For local execution: Functions Core Tools v4 supporting .NET 10 and Azurite.
- [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli):

  ```bash
  curl -fsSL https://aka.ms/connector-namespace-cli-install | sh
  ```

  Or in PowerShell:

  ```powershell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

## Deploy to Azure

```bash
cd azureblobApp/webhook
az login
azd auth login
azd env new azureblob-webhook
azd up
```

Use a different environment from polling.

Complete OAuth consent with an account granted **Storage Blob Data Contributor**
on the source account. Deployment grants this to the `AZURE_PRINCIPAL_ID` developer;
grant access separately if consenting as another user. Allow role propagation.

Already **Connected** connections skip consent.

No always-ready instance is configured by this webhook sample.

## Optional configuration

Set environment options with `azd env set <name> <value>` before provisioning.

| Option | Use |
| --- | --- |
| `BLOB_CONTAINER_NAME` | Source container; defaults to `connector-input` |
| `CONNECTOR_NAMESPACE_LOCATION` | Namespace region; defaults to `westcentralus` |
| `APPLICATIONINSIGHTS_LOCATION` | Telemetry region override, for example `eastus2`, when the Functions region lacks Application Insights |
| `azd hooks run postdeploy` | Rerun callback registration or consent |
| `bash ./infra/scripts/postdeploy.sh` | Run the Bash alternative |

To use Bash automatically, set `shell: sh` and
`run: bash ./infra/scripts/postdeploy.sh` in `azure.yaml`.

The included `NuGet.config` supplies the public package feed.

## Local development

1. Prepare `local.settings.json`.

   Use the file generated during successful `azd up`; existing files are preserved.
   If missing, run `azd hooks run postdeploy` in the selected environment.

2. Start Azurite in a separate terminal:

   ```bash
   azurite
   ```

3. Build and start the local function host:

   ```bash
   dotnet build
   func start
   ```

4. Open a public HTTPS tunnel to the local host. Manually register its
   `/runtime/webhooks/connector?functionName=OnUpdatedFile` callback using the local
   host's `connector_extension` system key. See [trigger configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md).

The deployment hooks target Azure, not localhost. Use [polling](../polling/) to avoid tunnels.

**Security:** never share or commit callback keys. Source access uses OAuth.

After testing locally, rerun `azd hooks run postdeploy` to restore Azure delivery,
then close the tunnel.

## Verify

Check the connection is **Connected** and its `OnUpdatedFiles_V2` trigger is
**Enabled** in [Connector Namespaces](https://connectors.azure.com/).
Upload or modify a blob **after consent**, using the `monitoredStorageAccountName`
and `monitoredContainerName` deployment outputs:

```bash
az storage blob upload --auth-mode login --account-name <monitoredStorageAccountName> --container-name <monitoredContainerName> --name sample.txt --file <local-file> --overwrite
```

Look for `Received OnUpdatedFile trigger (N items)` in function logs or Application
Insights. Allow time for source polling.

Run `azd down --purge` from this folder to clean up.

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [Azure Blob Storage connector reference](https://learn.microsoft.com/connectors/azureblob/)
- [Trigger configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md)
