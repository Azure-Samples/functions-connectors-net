# Salesforce Webhook delivery

This standalone app receives `GetOnNewItems` and `GetOnUpdatedItems` through the Connector extension callback route. **Salesforce is still polled by Connector Namespace**; this is not Salesforce native Webhook, CDC, Platform Event or outbound-message support. See the [overview](../README.md) for source account/API permissions.

## Quickstart

Install the [root prerequisites](../../README.md#prerequisites), Functions Core Tools v4 and Azurite. Use a different azd environment from Poll delivery. **Provisioning and Salesforce authorization require approved targets.**

```powershell
Set-Location .\SalesforceApp\webhook
azd env new salesforce-webhook
azd env set SALESFORCE_OBJECT Account
azd up
```

`SALESFORCE_OBJECT` is the exact approved object API name; `Account` is only an example. Optional settings: `SALESFORCE_FILTER`, `SALESFORCE_ORDER_BY`, `SALESFORCE_SELECT` (default `Id,CreatedDate,LastModifiedDate`), and `CONNECTOR_NAMESPACE_LOCATION` (default `westcentralus`). Bicep provisions a separate app, namespace and Salesforce connection. Manually authorize that connection for the approved org/environment and confirm Connected; Azure identity access does not authorize Salesforce.

After the deployed host starts, the hook retrieves `systemKeys.connector_extension` without printing it and PUTs both enabled trigger configurations with `deliveryMode: Webhook`. Callback URLs use the deployed hostname and `/runtime/webhooks/connector?functionName=OnNewRecord` or `OnUpdatedRecord`; authentication is separately stored as `{ type: QueryString, name: code, value: <system key> }`. Temporary request files are ignored and removed on success/error. A missing key fails explicitly; let the host start, then rerun `postdeploy.ps1` or `bash ./infra/scripts/postdeploy.sh`. Registration does not delete existing configurations or initiate Salesforce consent.

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
