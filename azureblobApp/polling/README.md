# Azure Blob connector - Poll delivery

Standalone .NET 10 isolated Azure Functions sample. `OnUpdatedFile` receives
`AzureBlobOnUpdatedFilesTriggerPayload` for the Azure Blob connector operation
[`OnUpdatedFiles_V2`](https://learn.microsoft.com/connectors/azureblob/#when-a-blob-is-added-or-modified-(properties-only)-(v2)).
The handler logs `Received OnUpdatedFile trigger`. There is no Blob output binding,
payload persistence, public callback, or callback system key.

## Prerequisites

- .NET 10 SDK, Azure CLI 2.75.0+, Azure Developer CLI (`azd`), and PowerShell 7 (`pwsh`).
- The [connector-namespace CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli):
  `irm https://aka.ms/connector-namespace-cli-install-ps | iex` in PowerShell, or
  `curl -fsSL https://aka.ms/connector-namespace-cli-install | sh` in Bash.
- An Azure subscription with permission to deploy resources and role assignments.
- For local execution: Azure Functions Core Tools v4 supporting .NET 10 and Azurite.

The included `NuGet.config` supplies the public Azure Functions package feed,
including Connector extension 1.0.0. No machine-level or parent NuGet
configuration is required.

## Deploy

Run from this directory and use a distinct environment name from the webhook app:

```powershell
cd azureblobApp\polling
azd auth login
az login
azd env new azureblob-polling
azd up
```

By default the Connector Namespace deploys in `westcentralus`. To override, run
`azd env set CONNECTOR_NAMESPACE_LOCATION <region>` before provisioning. Set
`BLOB_CONTAINER_NAME` to override the default `connector-input` source container.

If the Function region does not offer Application Insights (for example,
`westcentralus`), set `APPLICATIONINSIGHTS_LOCATION` to a supported region before
provisioning. Only the Application Insights component uses that override;
Functions, source/host storage, and the namespace retain their configured regions.

Infrastructure provisions the Function App (Flex Consumption), managed identity,
Application Insights/Log Analytics, host/deployment storage, a separate monitored
storage account, an OAuth Azure Blob connection, and an enabled Poll trigger
configuration. The source container ID is base64 of `%2f<container-name>`, as
required by the connector. `dataset` identifies the monitored storage account.

**Ongoing cost:** this template permanently provisions one 2048-MB always-ready
instance for `OnUpdatedFile` (`function:onupdatedfile`). It keeps the Poll listener
active, including when there are no events, and incurs Flex Consumption
always-ready baseline charges while idle. It is not a temporary test setting.
The webhook sample does not configure an always-ready instance.

The postdeploy hook prints and opens the returned OAuth consent link, redirecting
to `https://connectors.azure.com`. Already `Connected` connections skip consent.
Sign in with the developer account represented by `AZURE_PRINCIPAL_ID`;
it receives Storage Blob Data Contributor
on the monitored account so it can upload test blobs and authorize source access.
If consenting with a different account, grant that account suitable source data
access separately. Storage role assignments may take time to propagate.

The namespace identity, Functions identity, and developer identity receive
connection-level access policies. The deployed host uses
`ConnectorNamespace__credential=managedidentity` and its user-assigned identity's
`ConnectorNamespace__clientId`. The `OnUpdatedFileTriggerConfigName` setting
selects the enabled `azureblob-onupdatedfile` trigger. Bicep derives
`ConnectorNamespace__pollingEndpoint` from the service-generated receive URI,
preserving a gateway path if present and removing `/api` for stable-DNS endpoints.
It is a base URL, not a receive-operation URL or a URL containing query parameters.

The Azure Blob source still uses **OAuth**, not the host's managed identity.
Storage accounts and runtime storage roles remain necessary even though there
is no output binding. No `connector-messages` output container is used.
The worker's OpenTelemetry exporter explicitly uses `DefaultAzureCredential`:
Application Insights disables local authentication, so the connection string
alone is insufficient. In Azure, `AZURE_CLIENT_ID` selects the app's managed
identity, which has Monitoring Metrics Publisher access.

## Run locally

The postdeploy hook creates ignored `local.settings.json` using Azurite and
developer credentials. It preserves an existing file. To regenerate deliberately:

```powershell
pwsh -File .\infra\scripts\postdeploy.ps1 -ForceLocalSettings
```

Alternatively, copy `local.settings.example.json` to `local.settings.json` and
replace its polling endpoint with the `connectorPollingEndpoint` deployment
output. Do not copy deployed managed-identity settings to the local file.

Start Azurite in a separate terminal, sign in with `az login` as the provisioned
developer, and start this host:

```powershell
func start
```

The local and deployed hosts compete for the same queued events; stop the deployed
app when testing locally if you need every event to reach the local host.
No tunnel or publicly accessible local URL is required.

## Verify

In the Connector Namespaces portal, confirm that the Azure Blob connection is
`Connected` and `azureblob-onupdatedfile` is enabled with delivery mode `Poll`.
Upload or modify a blob in `connector-input` in the monitored storage account
(the `monitoredStorageAccountName` deployment output):

```powershell
az storage blob upload --auth-mode login --account-name <monitoredStorageAccountName> --container-name connector-input --name sample.txt --file <local-file> --overwrite
```

Allow for the connector's source polling interval, then check the local terminal
or Application Insights traces for `Received OnUpdatedFile trigger`. Existing
blobs need not generate a new event: upload or modify a blob after authorization.
Verify that no payload is written to host storage.

## Troubleshooting

- Consent fails: rerun `azd hooks run postdeploy` and verify the consenting user's
  Blob data permissions on the source account.
- Poll returns unauthorized: verify the caller's connection access policy and
  that local credentials use the same tenant/account as `userPrincipalId`.
- No events: check trigger state, `dataset`, encoded `folderId`, and connection
  status. Verify the base polling endpoint has no receive path or query.

See the [webhook alternative](../webhook/README.md) and
[extension configuration reference](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md).
