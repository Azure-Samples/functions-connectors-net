<!--
---
name: "Azure Functions Connector Samples (.NET): Salesforce webhook"
description: Receive Salesforce connector events through webhook delivery in a .NET Azure Functions app deployed using Azure Developer CLI (azd).
page_type: sample
languages:
- csharp
- bicep
- azdeveloper
products:
- azure
- azure-functions
urlFragment: functions-connectors-salesforce-webhook-dotnet
---
-->

# Salesforce Webhook delivery

This standalone .NET 10 isolated app receives Salesforce `GetOnNewItems` and `GetOnUpdatedItems` through the Connector extension callback route. **Salesforce is still polled by Connector Namespace**; this is not Salesforce native Webhook, CDC, Platform Event or outbound-message support. Both handlers use Azure.Connectors.Sdk 1.0.0 typed payloads and log only the trigger name and actual record count.

Use an API-enabled Salesforce Developer Edition org or isolated sandbox with an entitled edition; trial accounts are not supported by the connector. The consenting user needs API Enabled, read access to the chosen object and `Id`, `CreatedDate`, `LastModifiedDate` fields, record visibility and permission to authorize Salesforce OAuth. Azure managed identity does not authorize Salesforce. Creating or updating records requires separate object write permission and approval. See the [Salesforce connector reference](https://learn.microsoft.com/connectors/salesforce/) and [API edition requirements](https://developer.salesforce.com/docs/platform/api-rest/guide/intro-rest-compatible-editions.html).

## Quickstart

Install .NET 10 SDK, Azure Developer CLI (`azd`), Azure CLI 2.75.0 or later with the [connector-namespace extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli), Functions Core Tools v4 and Azurite. Hooks require PowerShell 7.3+ or Bash 3.2+ with `jq`, `mktemp` and standard shell utilities. Open a terminal in this folder, sign in to Azure and use a unique azd environment name for your deployment. **Provisioning and Salesforce authorization require approved targets.**

```powershell
azd env new 'your-unique-salesforce-webhook-name'
azd env set SALESFORCE_OBJECT Account
azd up
```

`SALESFORCE_OBJECT` is the exact approved object API name; `Account` is only an example. Optional settings: `SALESFORCE_FILTER`, `SALESFORCE_ORDER_BY`, `SALESFORCE_SELECT` (default `Id,CreatedDate,LastModifiedDate`), and `CONNECTOR_NAMESPACE_LOCATION` (default `westcentralus`). Bicep provisions a separate app, namespace and Salesforce connection. Manually authorize that connection for the approved org/environment and confirm Connected; Azure identity access does not authorize Salesforce.

The two functions are `OnNewRecord` and `OnUpdatedRecord`. Source parameter `table` comes from `SALESFORCE_OBJECT`; optional `$filter`, `$orderby` and `$select` use OData syntax, not SOQL. Updated-item tracking can include newly created records and does not detect attachment changes. Keep the date fields readable and avoid nullable sort fields.

The connection's `BasicAuthentication` parameter-set name still means hosted browser sign-in to Salesforce, not credentials to put in settings or source control. Confirm the login environment matches the approved org. Choose the object API name, such as `Account`, rather than its display label; Data Cloud objects such as `ssot__Account__dlm` may not provide the required `CreatedDate` field.

After the deployed host starts, the hook retrieves `systemKeys.connector_extension` without printing it and PUTs both enabled trigger configurations with `deliveryMode: Webhook`. Callback URLs use the deployed hostname and `/runtime/webhooks/connector?functionName=OnNewRecord` or `OnUpdatedRecord`; authentication is separately stored as `{ type: QueryString, name: code, value: <system key> }`. Temporary request files are ignored and removed on success/error. A missing key fails explicitly; let the host start, then rerun `postdeploy.ps1` or `bash ./infra/scripts/postdeploy.sh`. Registration does not delete existing configurations or initiate Salesforce consent.

To verify live delivery after authorization, create a new record you own in the approved object, then modify that record. Look for actual `OnNewRecord` and `OnUpdatedRecord` handler receipts with record counts; a Connected connection or Enabled trigger alone does not demonstrate delivery. Allow for connector polling latency and the configured filter.

The hook also generates ignored `local.settings.json` **only when missing**. Existing files are preserved byte-for-byte; directories and links are rejected. Only Azurite/runtime settings are generated; no cloud credentials, identity settings, system keys or callback URLs are placed in the file.

## Local checks

```powershell
pwsh -File .\infra\scripts\create-local-settings.ps1
dotnet build
func start --enableAuth
```

On Bash use `bash ./infra/scripts/create-local-settings.sh` (requires `jq`), then the same build/start commands. Start Azurite separately. Core Tools v4 bypasses local key authentication by default; use `--enableAuth`, especially before opening a public tunnel. Retrieve the local host's `connector_extension` system key using the [upstream local key guidance](https://github.com/Azure/azure-functions-connector-extension/blob/main/.github/skills/webhook-trigger-registration/SKILL.md#local-development-with-port-forwarding), not the deployed app's key, and supply it through the temporary `CONNECTOR_EXTENSION_KEY` environment variable. A **loopback-only** synthetic callback can be sent without Salesforce:

```powershell
Invoke-RestMethod -Method Post `
  -Uri 'http://localhost:7071/runtime/webhooks/connector?functionName=OnNewRecord' `
  -Headers @{ 'x-functions-key' = $env:CONNECTOR_EXTENSION_KEY } `
  -ContentType 'application/json' `
  -Body '{"body":{"value":[{"Id":"synthetic","Name":"not logged"}]}}'
```

Expect one receipt with trigger name and count `1`, not record contents. This tests callback conversion only, not OAuth, connector polling or Azure delivery.

Live local delivery needs a public HTTPS tunnel **only after explicit approval**. Keep `func start --enableAuth` running before exposing any port, and use the same local `connector_extension` key for tunnel registration, not a deployed key. Then invoke `postdeploy.ps1 -CallbackBaseUrl <https-authority> -ConnectorExtensionKey $env:CONNECTOR_EXTENSION_KEY` or set Bash `CALLBACK_BASE_URL` and `CONNECTOR_EXTENSION_KEY` before running `postdeploy.sh`. Keep key values out of shell history, logs and tracked files; clear the temporary key environment variable when finished.

Changing these trigger callbacks redirects delivery away from the deployed app. Stop the deployed app if reusing its host storage/namespace, keep the authenticated tunnel running during the test, and restore deployed callbacks by rerunning the hook **without** tunnel overrides afterward. Clear the temporary Bash environment overrides, close the tunnel and restart any app you stopped. Prefer separate test resources to avoid disrupting an existing consumer. Never create/update Salesforce records or relax org policies without the approved org/object and permission.
