<!--
---
name: "Azure Functions Connector Samples (.NET): Salesforce polling"
description: Receive Salesforce connector events with polling in a .NET Azure Functions app deployed using Azure Developer CLI (azd).
page_type: sample
languages:
- csharp
- bicep
- azdeveloper
products:
- azure
- azure-functions
urlFragment: functions-connectors-salesforce-polling-dotnet
---
-->

# Salesforce Poll delivery

This standalone .NET 10 isolated app monitors Salesforce `GetOnNewItems` and `GetOnUpdatedItems` through Connector Namespace and receives events with `[ConnectorTrigger(DeliveryMode = Poll)]`. No inbound callback or tunnel is needed. Both handlers use Azure.Connectors.Sdk 1.0.0 typed payloads and log only the trigger name and actual record count.

Use an API-enabled Salesforce Developer Edition org or isolated sandbox with an entitled edition; trial accounts are not supported by the connector. The consenting user needs API Enabled, read access to the chosen object and `Id`, `CreatedDate`, `LastModifiedDate` fields, record visibility and permission to authorize Salesforce OAuth. Azure managed identity does not authorize Salesforce. Creating or updating records requires separate object write permission and approval. See the [Salesforce connector reference](https://learn.microsoft.com/connectors/salesforce/) and [API edition requirements](https://developer.salesforce.com/docs/platform/api-rest/guide/intro-rest-compatible-editions.html).

## Quickstart

`azd up` provisions the Azure resources, helps you set up triggers, and deploys the Function App.

Install .NET 10 SDK, Azure Developer CLI (`azd`) 1.33.0+, and Azure CLI 2.75.0+ with the [connector-namespace extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli) version 1.0.0b33. The deployment scripts use the extension automatically for sign-in and source pickers. Hooks use PowerShell 7 on Windows and `sh` on POSIX, and need a terminal and writable temporary directory. Local execution also needs Functions Core Tools v4 and Azurite. Open a terminal in this folder and use a unique azd environment name. **Provisioning and Salesforce authorization require approved targets.**

```cmd
az login
azd auth login
azd env new "your-unique-salesforce-poll-name"
azd up
```

Complete Salesforce browser sign-in, choose at least one trigger, and select the object to monitor when prompted. Only selected triggers are enabled. `CONNECTOR_NAMESPACE_LOCATION` defaults to `westcentralus`. The deployment identity also needs trigger read/write permissions and permission to invoke source pickers.

The catalog in `infra/scripts/polling-config.json` offers `OnNewRecord` and `OnUpdatedRecord`; connector metadata provides the detailed prompts. Select the approved object through the `table` picker. Optional `$filter`, `$orderby` and `$select` use OData syntax, not SOQL. Both source operations are polling-backed; updated-item tracking can include newly created records and does not detect attachment changes. Keep `Id`, `CreatedDate` and `LastModifiedDate` available for tracking and avoid nullable sort fields.

The connection's `BasicAuthentication` parameter-set name still means hosted browser sign-in to Salesforce, not credentials to put in settings or source control. Confirm the login environment matches the approved org. Choose the object API name, such as `Account`, rather than its display label; Data Cloud objects such as `ssot__Account__dlm` may not provide the required `CreatedDate` field.

Setup confirms Azure reports Connected even if a sign-in window remains stale. Deployment verifies selected configurations and creates ignored `local.settings.json` **only when missing**. Existing files are preserved byte-for-byte. The file contains Azurite/runtime settings, the service-generated gateway-level Poll endpoint, trigger names and disabled flags, never cloud identity selectors or callback credentials.

Selections are saved in the active azd environment's `POLLING_TRIGGER_INPUTS` and reused. These settings are not encrypted; keep `.azure` out of source control. To choose again:

```cmd
azd env set POLLING_TRIGGER_INPUTS ""
azd up
```

Skipped owned configurations are disabled with their other writable properties preserved, and their app listeners are disabled. Never-created skipped configurations stay absent. Setup refuses to overwrite webhook or unowned configurations. If sign-in or trigger setup fails, correct the issue and rerun `azd up`. Resources already provisioned remain available.

## Local development

`azd up` creates `local.settings.json` automatically if it is missing. Only if you need to generate a missing file separately, select the already provisioned azd environment and run:

```cmd
dotnet run --file ./infra/scripts/PollingSetup.cs -- finish
```

The same command works on Windows and POSIX and verifies selected resources without changing source selections. Existing local settings are never overwritten; manually reconcile their listener switches or deliberately archive the file before regenerating. Do not copy deployed managed-identity settings into the local file. The example defaults all listeners to disabled and has a placeholder endpoint, so it is not runnable. Derive the real base only from `pollingEndpoints.receiveUri`: stable DNS uses `https://<host>`; the gateway-path form uses `https://<host>/api/connectorGateways/<id>`, never a full Receive URL or standalone `/api`.

Start Azurite separately, sign in with the developer identity granted connection access, and run:

```cmd
dotnet build
func start
```

If testing locally against the deployed app's same Poll configurations, **stop the deployed app first** to avoid competing consumers, then restore it afterward. A separate namespace/configuration is preferable. Trigger a new/modified record only in the approved org/object after explicit permission; the handler reports its trigger name and SDK collection count. Synthetic handler checks work offline, but `func start` with enabled Poll bindings contacts the real namespace and is not an offline source-delivery test.

To verify live delivery after authorization, create a new record you own in the approved object, then modify that record. Look for actual `OnNewRecord` and `OnUpdatedRecord` handler receipts with record counts; a Connected connection or Enabled trigger alone does not demonstrate delivery. Allow for connector polling latency and the configured filter.
