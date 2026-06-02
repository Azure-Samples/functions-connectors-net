# Office 365 Email Trigger (.NET)

Triggers an Azure Function when a new email arrives in your Microsoft 365 mailbox. The email payload is serialized to Azure Blob Storage. Authentication between the Connector Namespace and the Function App uses **managed identity + built-in auth (Easy Auth)** — no shared keys or secrets.

> [!CAUTION]
> **Personal data.** This sample writes email content (sender, subject, body) to Blob Storage for demonstration only. Scope the trigger, restrict access to the Storage account and App Insights, and run `azd down --purge` when done. See [Data and privacy](#data-and-privacy) below.

## Prerequisites

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli)
- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- `jq` (macOS/Linux only, for the bash post-deploy script)

## Quickstart

```bash
cd office365App
azd auth login
az login
azd up
```

> Some tenants require a Service Management Reference for Entra app registration. If provision fails with `ServiceManagementReference field is required`, run:
>
> ```bash
> azd env set SERVICE_MANAGEMENT_REFERENCE <your-service-tree-guid>
> azd up
> ```

The post-deploy hook creates the trigger config on the Connector Namespace and opens a browser to authorize the Office 365 connection.

## Verify

**Auth gate (expect 401):**

```bash
curl -i "https://<your-func>.azurewebsites.net/runtime/webhooks/connector?functionName=OnNewEmail"
```

**End-to-end:** Send yourself a high-importance email, then check Application Insights traces for `Received connector trigger payload`.

## Trigger configuration

The post-deploy script configures the trigger with these defaults:

| Setting | Value |
| ------- | ----- |
| `operationName` | `OnNewEmailV3` |
| `folderPath` | `Inbox` |
| `importance` | `High` |
| `authentication.type` | `ManagedServiceIdentity` |

Edit `infra/scripts/postdeploy.ps1` (or `.sh`) to change folder, importance, or other parameters before deploying.

## What gets deployed

| Resource | Purpose |
| --- | --- |
| Function App (Flex Consumption) | Hosts the `OnNewEmail` function |
| Connector Namespace | Manages the Office 365 connection and trigger |
| Storage Account | Blob output for email payloads |
| Application Insights | Telemetry (OpenTelemetry) |
| Entra App Registration | Audience for built-in auth tokens |
| 2 User-Assigned Managed Identities | Function app identity + trigger identity |

## Security model

Zero secrets. The Connector Namespace authenticates to the Function App via an Entra ID token validated by App Service built-in authentication. The function webhook is set to `Anonymous` authorization level — built-in auth is the only gate.

For details on the token validation flow, federated identity credentials, and `authsettingsV2` configuration, see the [built-in auth sample](https://github.com/Azure-Samples/functions-connectors-net-builtinauth).

## Data and privacy

- This sample serializes the **full email trigger payload** (sender, subject, body) to the configured Storage account.
- Ensure the **Storage account** and **Application Insights** are accessible only to the mailbox owner.
- **Scope the trigger** by adjusting `folderPath` and `importance` in the post-deploy script.
- Run `azd down --purge` when done to remove all resources and avoid retaining personal data.

## Re-deploying

After the first `azd up`, set this to avoid a Connector Namespace identity update error:

```bash
azd env set CREATE_CONNECTOR_NAMESPACE false
azd up
```

For code-only changes: `azd deploy`

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md) — all supported triggers and their .NET, Python, and TypeScript signatures.
- [Built-in auth sample](https://github.com/Azure-Samples/functions-connectors-net-builtinauth) — detailed security model walkthrough.
