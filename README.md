# Azure Functions Connector Samples (.NET)

[![CI](https://github.com/Azure-Samples/functions-connectors-net/actions/workflows/ci.yml/badge.svg)](https://github.com/Azure-Samples/functions-connectors-net/actions/workflows/ci.yml)

.NET samples for the [Azure Functions Connector Samples](https://github.com/Azure-Samples/functions-connectors/) repo, using the [Azure Connectors .NET SDK](https://github.com/Azure/Connectors-NET-SDK) and the [Connector trigger extension](https://github.com/Azure/azure-functions-connector-extension) to receive events from Microsoft 365, SharePoint, Teams, and other connectors.

See [CONTRIBUTING.md](CONTRIBUTING.md) to contribute and [CHANGELOG.md](CHANGELOG.md) for notable changes.

## Samples

| Guide | Connector |
| --- | --- |
| [Office 365](office365App/README.md) | [Office 365 Outlook](https://learn.microsoft.com/connectors/office365/) |
| [SharePoint](sharepointApp/README.md) | [SharePoint Online](https://learn.microsoft.com/connectors/sharepointonline/) |
| [OneDrive](onedriveApp/README.md) | [OneDrive for Business](https://learn.microsoft.com/connectors/onedriveforbusiness/) |
| [Teams](teamsApp/README.md) | [Microsoft Teams](https://learn.microsoft.com/connectors/teams/) |
| [Dataverse](dataverseApp/README.md) | [Microsoft Dataverse (Common Data Service)](https://learn.microsoft.com/connectors/commondataservice/) |
| [Planner](PlannerApp/README.md) | [Planner](https://learn.microsoft.com/connectors/planner/) |
| [Salesforce](SalesforceApp/README.md) | [Salesforce](https://learn.microsoft.com/connectors/salesforce/) |
| [Azure DevOps](AzureDevOpsApp/README.md) | [Azure DevOps (VSTS)](https://learn.microsoft.com/connectors/visualstudioteamservices/) |
| [Azure Blob](azureblobApp/README.md) | [Azure Blob Storage](https://learn.microsoft.com/connectors/azureblob/) |
| [Generic](genericApp/README.md) | [Any connector](https://learn.microsoft.com/connectors/), using raw string payloads |

Guides without links are work in progress. Each available sample is a self-contained Azure Functions app with its own `azure.yaml`, `infra/`, and source code. Navigate into a sample folder and run `azd up` to deploy.

## More triggers and operations

See the full [Connector trigger payloads for Azure Functions](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md) for all supported connector triggers and their .NET, Python, and TypeScript signatures.

## Prerequisites

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) — 1.33.0+ for polling samples
- [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli) ≥ 2.75.0
- [.NET 10 SDK](https://dotnet.microsoft.com/download)
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

- `jq` (for webhook Bash scripts on macOS/Linux; not needed by polling setup)

## Polling setup

The nine connector-specific polling samples use a C# setup helper run automatically by `azd up` with the .NET 10 SDK already required by the app. No separate helper installation is needed.

During deployment, complete browser sign-in and choose the triggers and source inputs when prompted. Azure Blob uses managed identity and does not require source-service OAuth consent. The scripts call the connector CLI for you; the OAuth-based polling samples use extension version 1.0.0b33.

Deployment also creates a missing `local.settings.json` and preserves any existing file. Each polling README includes a .NET recovery command for generating a missing file separately. Webhook samples retain their existing setup scripts and prerequisites.

## Related .NET samples

- [**Email → user lookup → Teams (end-to-end)**](https://github.com/Azure-Samples/functions-connectors-net-e2e-email-users-teams) — Trigger on new email, enrich via Office 365 Users connector, post adaptive card to Teams. Demonstrates multi-client DI and per-connection runtime URLs.
- [**Built-in authentication with managed identity**](https://github.com/Azure-Samples/functions-connectors-net-builtinauth) — Replace the `connector_extension` system key with App Service built-in auth (Easy Auth) backed by Entra ID. Includes Bicep for federated credentials and `authsettingsV2`.

## Related repos

- [**Azure Functions Connector Extension**](https://github.com/Azure/azure-functions-connector-extension) — The trigger binding that connects Connector Namespace events to Azure Functions.
- [**Azure Connectors .NET SDK**](https://github.com/Azure/Connectors-NET-SDK) — Typed clients for calling connector operations (Office 365, Teams, SharePoint, etc.).
