# Microsoft Dataverse Trigger + Action (.NET)

Azure Functions sample app demonstrating the **Microsoft Dataverse** (Common Data Service)
connector using the
[Microsoft.Azure.Functions.Worker.Extensions.Connector](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector)
worker extension for the trigger, plus a managed-identity HTTP function that **calls** a connector
action through the typed [Azure.Connectors.Sdk](https://www.nuget.org/packages/Azure.Connectors.Sdk).

| Function | Type | Connector operation | Description |
| --- | --- | --- | --- |
| `OnDataverseRowChanged` | Trigger | [`GetOnNewItems_V2`](https://learn.microsoft.com/connectors/commondataservice/#when-a-row-is-added-(admin-only)-[deprecated]) | Fires when a **new row is added** to the configured Dataverse table |
| `ListDataverseRows` | Action (HTTP) | [`GetItems_V2`](https://learn.microsoft.com/connectors/commondataservice/#list-rows-(legacy)-[deprecated]) (via `Azure.Connectors.Sdk`) | On-demand endpoint that **calls** the connector to list rows from the table |

> **Trigger scope & known issue:** this sample uses the **new-row** trigger `GetOnNewItems_V2`
> (*"When a row is created"*), validated end-to-end over Connector Namespace. The broader
> `SubscribeWebhookTrigger` (*"added, modified or deleted"*) is **not usable via Connector Namespace
> yet** — creating its trigger config currently fails with **HTTP 500** (`Regex.Match` null-reference).
> The team is adding support; until then, use `GetOnNewItems_V2`.

> **Why `commondataservice` (not `commondataserviceforapps`):** the successor connector ships only to
> Power Automate and **isn't available for Logic Apps / Connector Namespaces yet**. The legacy
> [`commondataservice`](https://learn.microsoft.com/connectors/commondataservice/) stays
> supported there until it is. Don't switch until the replacement is available in that environment.

> [!CAUTION]
> **Personal data.** This sample writes Dataverse row content to Blob Storage for demonstration only.
> Restrict access to the resources to appropriate users only, and run `azd down --purge` when done.

## What you configure

Point the sample at any environment / table without editing code — all via `azd env set`:

| Input | azd env var | Default | Notes |
| --- | --- | --- | --- |
| **Environment (name)** | `DATAVERSE_ENVIRONMENT_NAME` | _(empty)_ | Friendly name, e.g. `Contoso (default)`. The org URL is auto-resolved from this name during post-deploy. |
| **Environment (URL)** | `DATAVERSE_ENVIRONMENT_URL` | _(empty)_ | Explicit org URL, e.g. `https://org.crm.dynamics.com`. Takes precedence when set. Passed to the trigger as the `dataset` value. |
| **Table name** | `DATAVERSE_TABLE_NAME` | `accounts` | The entity set (plural logical) name, e.g. `accounts`, `contacts`. |

Provide **either** `DATAVERSE_ENVIRONMENT_NAME` (recommended — the URL is discovered for you)
**or** `DATAVERSE_ENVIRONMENT_URL`.

## Prerequisites

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli) ≥ 2.75.0
- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- A Microsoft Dataverse environment and an account with access to the target table
- [`connector-namespace` Azure CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli) — install with:

  ```bash
  # Bash
  curl -fsSL https://aka.ms/connector-namespace-cli-install | sh
  ```

  or

  ```pwsh
  # PowerShell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

## Deploy to Azure

```bash
cd dataverseApp
azd auth login
az login

# Configure the trigger (name is auto-resolved to the org URL; or set the URL directly).
azd env set DATAVERSE_ENVIRONMENT_NAME "Contoso (default)"
azd env set DATAVERSE_TABLE_NAME       "accounts"

azd up
```

### Resources provisioned

| Resource | Purpose |
| --- | --- |
| **Resource Group** | Contains all resources |
| **Flex Consumption Function App** (.NET 10 isolated) | Hosts the trigger + action functions |
| **App Service Plan** (FC1) | Flex Consumption plan |
| **User-Assigned Managed Identity** | Identity for the function app (used by the SDK action) |
| **Storage Account** | Deployment artifacts, function runtime state, and trigger payload output |
| **Log Analytics Workspace** | Backing store for Application Insights |
| **Application Insights** | Telemetry and logging |
| **Connector Namespace** | Hosts the Dataverse connection and trigger config |
| **Dataverse Connection** (OAuth) | Connects to your Dataverse environment |

The connection uses **OAuth**. After provisioning, a post-deploy hook opens a browser for
interactive consent, then creates the trigger config pointing at the function's connector webhook
URL. To re-run trigger setup (e.g. after changing the table):

```bash
azd env set DATAVERSE_TABLE_NAME "contacts"
azd provision          # re-applies app settings + access policies
azd hooks run postdeploy
```

## Call the connector action (List rows)

Besides *receiving* the trigger, `ListDataverseRows` *calls* the Dataverse **List rows** action
against the connection's runtime URL using the typed
[`Azure.Connectors.Sdk`](https://www.nuget.org/packages/Azure.Connectors.Sdk) client:

```csharp
var client = new CommondataserviceClient(new Uri(runtimeUrl), credential);
var items = await client.GetItemsAsync(
    environment: environmentUrl,   // the Dataverse org URL (dataset)
    tableName: table,              // entity set plural name, e.g. "accounts"
    topCount: top);
```

The SDK builds the request (including URL encoding of the dataset and table) and returns the parsed
`ItemsList` — no manual URL building. The `environment` argument is the Dataverse org URL (the
dataset), and `tableName` is the entity set plural name.

### Authentication (managed identity)

The client authenticates with `DefaultAzureCredential`, registered once in `Program.cs`:

```csharp
services.AddSingleton<TokenCredential>(new DefaultAzureCredential());
```

`DefaultAzureCredential` honours the `AZURE_CLIENT_ID` app setting, so **in Azure** it authenticates
as the function app's **user-assigned managed identity**; **locally** it falls back to your `az login`
identity. For the token exchange to succeed, that identity must have an **access policy** on the
connection. The infrastructure grants:

| Access policy | Principal | Why |
| --- | --- | --- |
| `functionapp-msi` | Function app user-assigned MI | Lets the deployed `ListDataverseRows` action call the connector |
| `connector-namespace-msi` | Connector Namespace system MI | Required for the namespace to poll the trigger |

Invoke it after deploying. Resolve the function app's host name instead of hard-coding the
domain (Flex Consumption apps don't always use `azurewebsites.net`), and get the function key
from the portal or `az functionapp keys list`:

```bash
HOSTNAME=$(az resource show -g <resourceGroup> -n <functionAppName> \
  --resource-type "Microsoft.Web/sites" --query properties.defaultHostName -o tsv)

curl "https://$HOSTNAME/api/rows?table=accounts&top=5&code=<function-key>"
```

The response is the connector's `ItemsList` payload: `{ "value": [ ...rows... ] }`.

## Run locally

```bash
func start
```

Set `DATAVERSE_CONNECTION_RUNTIME_URL` (the connection's runtime URL), `DATAVERSE_ENVIRONMENT_URL`
(the org URL) and `DATAVERSE_TABLE_NAME` in `local.settings.json` before starting. Locally the action
uses your signed-in `az login` (user) identity via `DefaultAzureCredential`. To call the action from
your machine, grant your own identity an access policy on the connection first:

```bash
az connector-namespace connection access-policy create -g <resourceGroup> \
  --namespace <connectorNamespaceName> --connection-name <connectionName> -n dev-user \
  --principal '{"type":"ActiveDirectory","identity":{"objectId":"<your-object-id>","tenantId":"<tenant-id>"}}'
```

## Verify

The Dataverse connector namespace can be **viewed** in the portal once created via ARM/CLI, but
**creating or updating** connections and trigger configs isn't supported there yet — so drive those
from the CLI. Capture the names created by `azd up`:

```bash
RG=$(azd env get-value resourceGroupName)
NS=$(azd env get-value connectorNamespaceName)
CONN=$(azd env get-value connectorNamespaceConnectionName)
FUNC=$(azd env get-value dataverseFunctionName)
TRIGGER="${CONN}-$(echo "$FUNC" | tr '[:upper:]' '[:lower:]')"
```

- **Connection is authenticated** (`overallStatus` should be `Connected`):

  ```bash
  az connector-namespace connection show -g $RG --namespace $NS -n $CONN \
    --query "{name:name, status:properties.overallStatus}" -o jsonc
  ```

- **Trigger config is enabled**:

  ```bash
  az connector-namespace trigger show -g $RG --namespace $NS -n $TRIGGER \
    --query "{state:properties.state, operation:properties.operationName}" -o jsonc
  ```

Now **add a new row** to the configured table (e.g. create an account), wait one polling interval
(5 minutes in this sample), then tail the function logs to see the trigger fire:

```bash
az functionapp log tail -g $RG -n $(azd env get-value functionAppName)
```

> **Permissions note:** these row triggers are **Admin Only** — the OAuth-connected Dataverse
> identity needs **Global Read** on the selected table, or the poll fails with `403 Forbidden`.

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [Common Data Service connector reference](https://learn.microsoft.com/connectors/commondataservice/)
- [Azure Connectors .NET SDK](https://github.com/Azure/Connectors-NET-SDK)
