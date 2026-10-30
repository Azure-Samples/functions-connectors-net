# Dataverse current events with webhook delivery

Connector Namespace pushes current Dataverse events to the Functions connector webhook.
`OnDataverseRowChanged` registers `SubscribeWebhookTrigger` for added, modified, and deleted
rows (`message=7`, organization scope `scope=4`).
`OnDataverseActionPerformed` registers `BusinessEventsTrigger` only after opting in and
supplying its real catalog/category/table/action identifiers.

These two event handlers are explicitly approved `JsonElement` exceptions because the
SDK lacks models for the current operations. They log receipt and JSON kind only.
There are no deprecated individual-row handlers, deprecated SDK List rows action,
Blob bindings, or persisted event payloads.
See [SDK gaps and service limitations](../README.md).

## Prerequisites

- .NET 10 SDK, Azure CLI >= 2.75.0, Azure Developer CLI (`azd`), PowerShell 7 (`pwsh`)
  on all platforms (the `azd` hook directly runs the same PowerShell script)
- The `connector-namespace` CLI extension:
  `irm https://aka.ms/connector-namespace-cli-install-ps | iex` in PowerShell, or
  `curl -fsSL https://aka.ms/connector-namespace-cli-install | sh` in Bash
- Dataverse org URL and an OAuth identity authorized for organization-scoped subscriptions
- For local execution: Functions Core Tools v4 and Azurite

## Deploy

```powershell
cd dataverseApp\webhook
azd auth login
az login
azd env new dataverse-webhook
azd env set DATAVERSE_ENVIRONMENT_URL "https://contoso.crm.dynamics.com"
azd env set DATAVERSE_TABLE_NAME "account"
# If needed, choose an approved telemetry region:
azd env set TELEMETRY_LOCATION "eastus2"
azd up
```

Use the org URL, not a friendly environment name. The table defaults to the logical name
`account`, not the Web API entity set `accounts`.
The hook preserves connected OAuth consent or prints and opens a direct consent link
using the `https://connectors.azure.com` redirect. It then gets the connector extension
system key and actual Function hostname, and creates the current subscriptions with
authenticated callback URLs. A failed registration makes the hook fail explicitly.
No legacy `dataset`/`table` parameters or deprecated fallback registrations are used.

Flex Consumption hosting, host/deployment storage, telemetry, managed identities, the
namespace and OAuth connection remain provisioned. Webhook delivery has no always-ready
allocation. Storage is required for the host and deployment package, not event output.

After changing source configuration, run `azd provision` and `azd hooks run postdeploy`.
For action-performed, set the four event identifiers and flag documented in the parent
README before provisioning; the Function is otherwise disabled.

## Run locally

Copy `local.settings.example.json` to ignored `local.settings.json`, start Azurite and
run `func start`. Real webhook delivery requires a publicly reachable HTTPS callback;
the post-deploy hook configures the deployed app, not an automatic local tunnel.

## Verify

Check `Connected` OAuth state and enabled current-operation configurations. Webhook trigger
names are the connection name plus the lower-case Function name, for example
`<connection>-ondataverserowchanged`.

Only after registration succeeds, create a clearly named sample-owned row, observe the
`Received OnDataverseRowChanged trigger` log, update only that row and observe another
event, then delete it and observe deletion. Verify the selected safe business action
separately after its subscription is configured. Never alter existing business data.

Also check `triggerStatuses/latest`: an enabled configuration alone is not proof of
successful source registration. For example, `accounts` instead of logical `account`
fails with `0x80040203: Entity not present in cache: accounts`.

```powershell
$rg = azd env get-value resourceGroupName
$ns = azd env get-value connectorNamespaceName
$connection = azd env get-value connectorNamespaceConnectionName
$subscription = azd env get-value AZURE_SUBSCRIPTION_ID
$uri = "https://management.azure.com/subscriptions/$subscription/resourceGroups/$rg/providers/Microsoft.Web/connectorGateways/$ns/triggerConfigs/$connection-ondataverserowchanged/triggerStatuses/latest?api-version=2026-05-01-preview"
az rest --method get --url $uri `
  --query "{status:lastExecutionStatus,code:lastExecutionStatusCode,error:lastExecutionOutputs.body.error}" -o json
```

Preserve service errors; an SDK build, OAuth consent, or success of the former deprecated
sample does not prove current trigger support.

Run `azd down --purge` when finished.
