# Salesforce Poll delivery

This standalone app monitors `GetOnNewItems` and `GetOnUpdatedItems` through Connector Namespace and receives events with `[ConnectorTrigger(DeliveryMode = Poll)]`. No inbound callback or tunnel is needed. See the [overview](../README.md) for Salesforce edition, OAuth, permissions and testability requirements.

## Quickstart

Install the [root prerequisites](../../README.md#prerequisites), Functions Core Tools v4 and Azurite. Use a distinct azd environment and the exact approved object API name, not its display label. **Provisioning and Salesforce authorization require approved targets.**

```powershell
Set-Location .\SalesforceApp\polling
azd env new salesforce-poll
azd env set SALESFORCE_OBJECT Account
azd up
```

`SALESFORCE_OBJECT` is required; `Account` is only an example. Optional environment settings: `SALESFORCE_FILTER`, `SALESFORCE_ORDER_BY`, `SALESFORCE_SELECT` (default `Id,CreatedDate,LastModifiedDate`), and `CONNECTOR_NAMESPACE_LOCATION` (default `westcentralus`). Deployment creates two enabled Poll trigger configurations, app and developer connection access policies, and an independent system-assigned app identity. Manually authorize the created Salesforce connection for the approved org/environment and confirm it is Connected; the hook does not open consent or change the org.

The postdeploy hook creates ignored `local.settings.json` **only when missing** from deployment outputs. Existing files are preserved byte-for-byte; directories and links are rejected. The file contains Azurite/runtime settings, the service-generated gateway-level polling endpoint and the two trigger names, never cloud identity selectors, credentials or callback details.

To generate the missing local file after selecting an already provisioned azd environment:

```powershell
pwsh -File .\infra\scripts\create-local-settings.ps1
dotnet build
func start
```

On Bash use `bash ./infra/scripts/create-local-settings.sh` (requires `jq`), then the same build/start commands. Start Azurite separately and sign in with the developer identity granted connection access. Do not copy deployed managed-identity settings into the local file. The checked-in `local.settings.example.json` shows the shape, but its placeholder endpoint is not runnable. Derive the real base only from `pollingEndpoints.receiveUri`: stable DNS uses `https://<host>`; the gateway-path form uses `https://<host>/api/connectorGateways/<id>`, never a full Receive URL or standalone `/api`.

If testing locally against the deployed app's same Poll configurations, **stop the deployed app first** to avoid competing consumers, then restore it afterward. A separate namespace/configuration is preferable. Trigger a new/modified record only in the approved org/object after explicit permission; the handler reports its trigger name and SDK collection count. Synthetic handler checks work offline, but `func start` with enabled Poll bindings contacts the real namespace and is not an offline source-delivery test.
