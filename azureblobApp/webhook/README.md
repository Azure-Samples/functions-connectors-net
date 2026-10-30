# Azure Blob connector - Webhook delivery

Standalone .NET 10 isolated Azure Functions sample retaining the existing
`OnUpdatedFile` connector trigger. The Azure Blob operation `OnUpdatedFiles_V2`
detects added or modified blob properties and delivers
`AzureBlobOnUpdatedFilesTriggerPayload` to the Functions connector callback.
The handler only logs `Received OnUpdatedFile trigger`; it has no Blob output
binding and does not persist payloads.

## Prerequisites

- .NET 10 SDK, Azure CLI 2.75.0+, Azure Developer CLI (`azd`), PowerShell 7.
- The [connector-namespace CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli):
  `irm https://aka.ms/connector-namespace-cli-install-ps | iex` in PowerShell, or
  `curl -fsSL https://aka.ms/connector-namespace-cli-install | sh` in Bash.
- Azure permissions to deploy resources and role assignments.

The included `NuGet.config` supplies the public Azure Functions package feed,
including Connector extension 1.0.0. No machine-level or parent NuGet
configuration is required.

## Deploy

```powershell
cd azureblobApp\webhook
azd auth login
az login
azd env new azureblob-webhook
azd up
```

Use an environment name different from the polling app. The Connector Namespace
defaults to `westcentralus`; override with `CONNECTOR_NAMESPACE_LOCATION` in the
azd environment. `BLOB_CONTAINER_NAME` overrides the `connector-input` container.

If the Function region does not offer Application Insights (for example,
`westcentralus`), set `APPLICATIONINSIGHTS_LOCATION` to a supported region before
provisioning. Only the Application Insights component uses that override;
Functions, source/host storage, and the namespace retain their configured regions.

The deployment provisions the Flex Consumption Function App, its user-assigned
managed identity, host/deployment storage, Application Insights/Log Analytics,
a separate monitored storage account/container, and the Azure Blob connection.
The developer receives Storage Blob Data Contributor on the monitored account.
The connection uses **Entra ID OAuth**, not managed-identity source authentication.
Consent with that developer account, or separately grant the consenting user
appropriate source data access. Allow time for role assignments to propagate.

The interactive postdeploy hook authorizes the connection, fetches the
`connector_extension` system key, and registers the callback with query-string
authentication. It prints and opens the returned OAuth consent link, redirecting
to `https://connectors.azure.com`; already `Connected` connections skip consent.
The callback is
`https://<function-app-host>/runtime/webhooks/connector?functionName=OnUpdatedFile`.
Rerun setup with `azd hooks run postdeploy`. Do not share or commit callback keys.

Storage for the Functions runtime and deployment package remains required.
It is not a Blob output destination: no `connector-messages` container is used.
The worker's OpenTelemetry exporter explicitly uses `DefaultAzureCredential`:
Application Insights disables local authentication, so the connection string
alone is insufficient. In Azure, `AZURE_CLIENT_ID` selects the app's managed
identity, which has Monitoring Metrics Publisher access.

## Verify

Confirm that the Azure Blob connection is `Connected` and its `OnUpdatedFiles_V2`
trigger is enabled in the Connector Namespaces portal. Upload or modify a blob
in the monitored account's `connector-input` container:

```powershell
az storage blob upload --auth-mode login --account-name <monitoredStorageAccountName> --container-name connector-input --name sample.txt --file <local-file> --overwrite
```

Use the `monitoredStorageAccountName` deployment output, not the host storage
account. Allow for the connector's source polling interval, then look for
`Received OnUpdatedFile trigger` in Application Insights traces.

## Local development

Copy `local.settings.example.json` to the ignored `local.settings.json`, start
Azurite, and use Core Tools v4 supporting .NET 10 to run `func start`.
Webhook delivery requires a public HTTPS tunnel to the local Functions host and
a trigger callback registered against that tunnel with its local connector
system key. The deployed hook targets the deployed app, not localhost.
Do not run the deployed hook to register a local callback.

For a local sample without tunnels, callback registration, or system keys, use
the [standalone polling app](../polling/README.md). Polling of Azure Blob by the
connector service is independent of webhook versus Poll delivery to Functions.

See the [Azure Blob connector reference](https://learn.microsoft.com/connectors/azureblob/)
and [operations mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md).
