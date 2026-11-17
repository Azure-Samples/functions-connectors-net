# Salesforce Poll delivery

This standalone .NET 10 isolated app monitors Salesforce `GetOnNewItems` and `GetOnUpdatedItems` through Connector Namespace and receives events with `[ConnectorTrigger(DeliveryMode = Poll)]`. No inbound callback or tunnel is needed. Both handlers use Azure.Connectors.Sdk 1.0.0 typed payloads and log only the trigger name and actual record count.

Use an API-enabled Salesforce Developer Edition org or isolated sandbox with an entitled edition; trial accounts are not supported by the connector. The consenting user needs API Enabled, read access to the chosen object and `Id`, `CreatedDate`, `LastModifiedDate` fields, record visibility and permission to authorize Salesforce OAuth. Azure managed identity does not authorize Salesforce. Creating or updating records requires separate object write permission and approval. See the [Salesforce connector reference](https://learn.microsoft.com/connectors/salesforce/) and [API edition requirements](https://developer.salesforce.com/docs/platform/api-rest/guide/intro-rest-compatible-editions.html).

## Quickstart

Install .NET 10 SDK, Azure Developer CLI (`azd`), Azure CLI 2.75.0 or later with the [connector-namespace extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli), Functions Core Tools v4 and Azurite. Hooks require PowerShell 7.3+ or Bash 3.2+ with `jq`. Open a terminal in this folder, sign in to Azure and use a unique azd environment name for your deployment. Use the exact approved object API name, not its display label. **Provisioning and Salesforce authorization require approved targets.**

```powershell
azd env new 'your-unique-salesforce-poll-name'
azd env set SALESFORCE_OBJECT Account
azd up
```

`SALESFORCE_OBJECT` is required; `Account` is only an example. Optional environment settings: `SALESFORCE_FILTER`, `SALESFORCE_ORDER_BY`, `SALESFORCE_SELECT` (default `Id,CreatedDate,LastModifiedDate`), and `CONNECTOR_NAMESPACE_LOCATION` (default `westcentralus`). Deployment creates two enabled Poll trigger configurations, app and developer connection access policies, and an independent system-assigned app identity. Manually authorize the created Salesforce connection for the approved org/environment and confirm it is Connected; the hook does not open consent or change the org.

The two functions are `OnNewRecord` and `OnUpdatedRecord`. Source parameter `table` comes from `SALESFORCE_OBJECT`; optional `$filter`, `$orderby` and `$select` use OData syntax, not SOQL. Both source operations are polling-backed; updated-item tracking can include newly created records and does not detect attachment changes. Keep the date fields readable and avoid nullable sort fields.

The connection's `BasicAuthentication` parameter-set name still means hosted browser sign-in to Salesforce, not credentials to put in settings or source control. Confirm the login environment matches the approved org. Choose the object API name, such as `Account`, rather than its display label; Data Cloud objects such as `ssot__Account__dlm` may not provide the required `CreatedDate` field.

The postdeploy hook creates ignored `local.settings.json` **only when missing** from deployment outputs. Existing files are preserved byte-for-byte; directories and links are rejected. The file contains Azurite/runtime settings, the service-generated gateway-level polling endpoint and the two trigger names, never cloud identity selectors, credentials or callback details.

To generate the missing local file after selecting an already provisioned azd environment:

```powershell
pwsh -File .\infra\scripts\create-local-settings.ps1
dotnet build
func start
```

On Bash use `bash ./infra/scripts/create-local-settings.sh` (requires `jq`), then the same build/start commands. Start Azurite separately and sign in with the developer identity granted connection access. Do not copy deployed managed-identity settings into the local file. The checked-in `local.settings.example.json` shows the shape, but its placeholder endpoint is not runnable. Derive the real base only from `pollingEndpoints.receiveUri`: stable DNS uses `https://<host>`; the gateway-path form uses `https://<host>/api/connectorGateways/<id>`, never a full Receive URL or standalone `/api`.

If testing locally against the deployed app's same Poll configurations, **stop the deployed app first** to avoid competing consumers, then restore it afterward. A separate namespace/configuration is preferable. Trigger a new/modified record only in the approved org/object after explicit permission; the handler reports its trigger name and SDK collection count. Synthetic handler checks work offline, but `func start` with enabled Poll bindings contacts the real namespace and is not an offline source-delivery test.

To verify live delivery after authorization, create a new record you own in the approved object, then modify that record. Look for actual `OnNewRecord` and `OnUpdatedRecord` handler receipts with record counts; a Connected connection or Enabled trigger alone does not demonstrate delivery. Allow for connector polling latency and the configured filter.
