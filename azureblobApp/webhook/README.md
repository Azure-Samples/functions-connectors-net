# Azure Blob Storage Webhook Triggers (.NET)

Azure Functions sample using [Azure.Connectors.Sdk](https://www.nuget.org/packages/Azure.Connectors.Sdk) and the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector). The Connector Namespace delivers events to the function's public HTTPS callback. The handler uses `AzureBlobOnUpdatedFilesTriggerPayload` and logs only the trigger name and item count.

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnUpdatedFile` | [`OnUpdatedFiles_V2`](https://learn.microsoft.com/connectors/azureblob/#when-a-blob-is-added-or-modified-(properties-only)-(v2)) | Blob added or modified (properties only) |

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later
- PowerShell 7.3 (.NET 7) or later for the default hook, or Bash with jq 1.6+ for the alternative script
- Azure permissions to deploy resources and role assignments
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

The source connection uses the **Connector Namespace's system-assigned managed identity**, not a user's OAuth login. Deployment selects `managedIdentityAuth`, grants the namespace **Storage Blob Data Reader** on the monitored storage account, and adds a connection access policy for that identity. No browser consent is required.

The `AZURE_PRINCIPAL_ID` developer retains **Storage Blob Data Contributor** on the source account for test uploads. `az login` / `azd auth login` are still needed for deployment and local developer credentials; they do not authorize the source connection. Webhook delivery still uses the function's `connector_extension` system key, independently of source authentication.

The postdeploy hook verifies `managedIdentityAuth` and waits up to five minutes for **Ready** (the managed-identity status) or **Connected**, then registers the callback. Storage RBAC may take longer to propagate; connection readiness alone does not prove source access. If polling reports authorization errors, verify the namespace identity's source role and connection access policy, allow propagation, and rerun the hook.

Reprovisioning an existing environment creates a separate connection with a `-mi` suffix and registers the sample trigger against it. An existing OAuth connection retains its authentication mode even when its deployment requests managed identity, so it is preserved rather than reused or deleted. Rerunning the hook alone does not migrate authentication.

## Optional configuration

Set environment options with `azd env set <name> <value>` before provisioning.

| Option | Use |
| --- | --- |
| `BLOB_CONTAINER_NAME` | Source container; defaults to `connector-input` |
| `CONNECTOR_NAMESPACE_LOCATION` | Namespace region; defaults to `westcentralus` |
| `APPLICATIONINSIGHTS_LOCATION` | Telemetry region override, for example `eastus2`, when the Functions region lacks Application Insights |
| `azd hooks run postdeploy` | Check connection readiness and rerun callback registration |
| `bash ./infra/scripts/postdeploy.sh` | Run the Bash alternative |

Existing regular local settings are preserved byte-for-byte; directories and links are rejected. Reruns update the sample's named trigger configuration with the current source parameters and Azure callback, without deleting it first.

Worker telemetry uses the `ConnectorNamespace` identity settings: developer credentials locally, the Function App's system-assigned identity in Azure. Local settings omit cloud identity values.

To use Bash automatically, set `shell: sh` and `run: bash ./infra/scripts/postdeploy.sh` in `azure.yaml`.

## Local development

1. Prepare `local.settings.json`.

   Use the file generated during successful `azd up`; existing files are preserved. If missing, run `azd hooks run postdeploy` in the selected environment.

2. Start Azurite in a separate terminal:

   ```bash
   azurite
   ```

3. Build and start the local function host:

   ```bash
   dotnet build
   func start --enableAuth
   ```

   Core Tools v4 skips key enforcement by default. Use `--enableAuth` before exposing the host through any public HTTPS tunnel.

4. Open a public HTTPS tunnel to the local host. Manually register its `/runtime/webhooks/connector?functionName=OnUpdatedFile` callback using the local host's `connector_extension` system key, not the deployed Azure app's key. See [trigger configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md).

The deployment hooks target Azure, not localhost. Use [polling](../polling/) to avoid tunnels.

**Security:** never share or commit callback keys. Source access uses the namespace's managed identity, including when the callback targets a local function.

After testing locally, rerun `azd hooks run postdeploy` to restore Azure delivery, then close the tunnel.

## Verify

Check the `-mi` connection uses **Managed Identity** and is **Ready** or **Connected**, and its `OnUpdatedFiles_V2` trigger is **Enabled** in [Connector Namespaces](https://connectors.azure.com/). After provisioning and RBAC propagation, upload or modify a blob using the `monitoredStorageAccountName` and `monitoredContainerName` deployment outputs:

```bash
az storage blob upload --auth-mode login --account-name <monitoredStorageAccountName> --container-name <monitoredContainerName> --name sample.txt --file <local-file> --overwrite
```

Look for `Received OnUpdatedFile trigger (N items)` in function logs or Application Insights. Allow time for source polling.

Run `azd down --purge` from this folder to clean up.

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [Azure Blob Storage connector reference](https://learn.microsoft.com/connectors/azureblob/)
- [Trigger configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md)
