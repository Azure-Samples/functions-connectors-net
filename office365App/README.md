# Office 365 Outlook Triggers (.NET)

Demonstrates five Office 365 Outlook connector triggers — each fires an Azure Function and writes the payload to Blob Storage.

| Function | Trigger operation |
| --- | --- |
| `OnNewEmail` | `OnNewEmailV3` |
| `OnFlaggedEmail` | `OnFlaggedEmailV4` |
| `OnNewMentionMeEmail` | `OnNewMentionMeEmailV3` |
| `OnNewCalendarEvent` | `CalendarGetOnNewItemsV3` |
| `OnUpcomingEvent` | `OnUpcomingEventsV3` |

> [!CAUTION]
> **Personal data.** This sample writes email/calendar content to Blob Storage for demonstration only. Restrict access to the resources to appropriate users only, and run `azd down --purge` when done.

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

The post-deploy hook creates the trigger config on the Connector Namespace and opens a browser to authorize the Office 365 connection.

## Verify

Send yourself a high-importance email, then check Application Insights traces for `Received OnNewEmail trigger`.

## Trigger configuration

The post-deploy script configures the `OnNewEmail` trigger with these defaults:

| Setting | Value |
| ------- | ----- |
| `operationName` | `OnNewEmailV3` |
| `folderPath` | `Inbox` |
| `importance` | `High` |

Edit `infra/scripts/postdeploy.ps1` (or `.sh`) to change folder, importance, or add trigger configs for the other functions.

## What gets deployed

| Resource | Purpose |
| --- | --- |
| Function App (Flex Consumption) | Hosts the 5 trigger functions |
| Connector Namespace | Manages the Office 365 connection and trigger |
| Storage Account | Blob output for trigger payloads |
| Application Insights | Telemetry (OpenTelemetry) |
| User-Assigned Managed Identity | Function app identity |

## Re-deploying

For code-only changes: `azd deploy`

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md) — all supported triggers and their .NET, Python, and TypeScript signatures.
- [Built-in auth sample](https://github.com/Azure-Samples/functions-connectors-net-builtinauth) — secretless authentication using managed identity + Easy Auth.
