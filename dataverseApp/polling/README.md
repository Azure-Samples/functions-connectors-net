# Microsoft Dataverse Poll delivery + action (.NET)

This standalone Functions app receives new Dataverse rows through **Poll delivery**.
Connector Namespace checks Dataverse using `GetOnNewItems_V2`; the Functions connector
extension pulls queued events and acknowledges successful invocations. It logs row counts
only, with no Blob output binding. `ListDataverseRows` retains the typed SDK List rows action
(`GetItems_V2`) at `GET /api/rows?table=accounts&top=5`.

The sample follows [Office 365 polling](../../office365App/polling/README.md) and uses
connector extension 1.0.0. It is not a TimerTrigger that periodically calls List rows.
For inbound push delivery, use the separate [webhook app](../webhook/README.md).

## Prerequisites

- .NET 10 SDK, Azure CLI >= 2.75.0, Azure Developer CLI (`azd`), and PowerShell 7 (`pwsh`)
  on every platform (the post-deploy hook runs PowerShell).
- The `connector-namespace` CLI extension. Install with
  `irm https://aka.ms/connector-namespace-cli-install-ps | iex` in PowerShell, or
  `curl -fsSL https://aka.ms/connector-namespace-cli-install | sh` in Bash.
- A Dataverse environment URL and an OAuth account with **Global Read** on the target table.
- For local execution: Functions Core Tools v4 and Azurite for host storage.

The legacy `commondataservice` connector is intentional: `commondataserviceforapps` is
not yet available in Connector Namespace. This sample uses only the existing new-row
operation, not `SubscribeWebhookTrigger` (added, modified, or deleted). The latter has a
known trigger-creation failure documented in the webhook app. Dataverse-specific Poll
delivery still needs live verification against your namespace/region; source and build
checks do not establish service-side availability.

## Deploy

```powershell
cd dataverseApp\polling
azd auth login
az login
azd env new dataverse-polling
azd env set DATAVERSE_ENVIRONMENT_URL "https://contoso.crm.dynamics.com"
azd env set DATAVERSE_TABLE_NAME "accounts"
azd up
```

Use the **org URL**, not its friendly name. Unlike the webhook app, polling requires the URL
before provisioning because Bicep creates the trigger configuration. The table defaults to
`accounts`; use the plural logical/entity-set name. Do not add `$top` to trigger parameters:
the existing Dataverse trigger rejects it with Change Tracking enabled.

Infrastructure provisions an enabled `deliveryMode: Poll` trigger named
`dataverse-ondataverserowchanged`, operation `GetOnNewItems_V2`, with `dataset` and `table`
parameters and a five-minute recurrence. ARM/Bicep is used because the current CLI
`trigger create` command does not expose `deliveryMode`. No notification details,
public callback URL, connector extension key, or webhook registration is required.

The deployment includes Flex Consumption hosting, host/deployment storage, telemetry,
a user-assigned Function identity, and a Connector Namespace with an OAuth connection.
Storage and its host permissions remain necessary; they do not store trigger payloads.
Connection access policies authorize the namespace identity to check Dataverse, the
Function identity to receive/acknowledge events and call List rows, and the provisioning
user to run locally. The post-deploy hook obtains interactive OAuth consent and writes
an ignored `local.settings.json`, preserving an existing file unless invoked with
`-ForceLocalSettings`.

| App setting | Purpose |
| --- | --- |
| `ConnectorNamespace__pollingEndpoint` | Gateway-level base derived from service-returned `pollingEndpoints.receiveUri`; not the full `/receive` URL |
| `OnDataverseRowChangedTriggerConfigName` | Name of the enabled Poll trigger |
| `ConnectorNamespace__credential` / `ConnectorNamespace__clientId` | Deployed host-pull managed identity |
| `AZURE_CLIENT_ID` | Managed identity used by the SDK action |
| `DATAVERSE_CONNECTION_RUNTIME_URL` | Connection runtime URL used by the action |
| `DATAVERSE_ENVIRONMENT_URL` / `DATAVERSE_TABLE_NAME` | Action dataset and default table |

Change the environment/table with `azd env set`, then run `azd provision` and
`azd hooks run postdeploy`. Regenerate stale local settings explicitly:

```powershell
.\infra\scripts\postdeploy.ps1 -ForceLocalSettings
```

## Run locally

Use the generated local settings, or copy `local.settings.example.json` to
`local.settings.json` and fill in the endpoint, runtime URL, and org URL from your deployment.
The example deliberately omits managed-identity settings so the host and SDK use your
developer credentials. Sign in with `az login` as the provisioning user; other developers
must first get a connection-level access policy. Start Azurite, then:

```powershell
dotnet build
func start
```

No tunnel is required. Do not run local and deployed listeners against the same trigger
when expecting every event locally: they compete for queued events.

## Verify

```powershell
$rg = azd env get-value resourceGroupName
$ns = azd env get-value connectorNamespaceName
$connection = azd env get-value connectorNamespaceConnectionName
az connector-namespace connection show -g $rg --namespace $ns -n $connection `
  --query "properties.overallStatus" -o tsv
az connector-namespace trigger show -g $rg --namespace $ns -n dataverse-ondataverserowchanged `
  --query "properties.{state:state,deliveryMode:deliveryMode,operation:operationName}" -o json
```

Expect `Connected`, `Enabled`, `Poll`, and `GetOnNewItems_V2`. Add a new row after the
trigger is initialized, allow at least one five-minute interval, then inspect
Application Insights for `Received OnDataverseRowChanged trigger with ... row(s).`
The SDK action returns rows to its authorized caller; it does not persist them:

```powershell
$app = azd env get-value functionAppName
$hostname = az resource show -g $rg -n $app --resource-type Microsoft.Web/sites `
  --query properties.defaultHostName -o tsv
Invoke-RestMethod "https://$hostname/api/rows?table=accounts&top=5&code=<function-key>"
```

If provisioning rejects Poll delivery or omits `pollingEndpoints.receiveUri`, retain
the error as evidence of a service capability/region limitation; do not substitute a
webhook URL. Use the webhook app independently until Poll support is available.

## Cleanup

Run `azd down --purge` from this folder. Treat action responses as personal data, restrict
resource/function-key access, and do not commit generated local settings.
