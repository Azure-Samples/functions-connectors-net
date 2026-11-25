<!--
---
name: "Azure Functions Connector Samples (.NET): Office 365 Outlook polling"
description: Receive Office 365 Outlook connector events with polling in a .NET Azure Functions app deployed using Azure Developer CLI (azd).
page_type: sample
languages:
- csharp
- bicep
- azdeveloper
products:
- azure
- azure-functions
urlFragment: functions-connectors-office365-polling-dotnet
---
-->

# Office 365 Outlook Polling Triggers (.NET)

Azure Functions sample using [Azure.Connectors.Sdk](https://www.nuget.org/packages/Azure.Connectors.Sdk) and the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector) with `DeliveryMode = Poll`. The host receives events outbound from the Connector Namespace; no public callback or tunnel is required. All handlers use typed payloads and log only the trigger name and item count.

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnNewEmail` | [`OnNewEmailV3`](https://learn.microsoft.com/connectors/office365/#when-a-new-email-arrives-(v3)) | New email |
| `OnFlaggedEmail` | [`OnFlaggedEmailV4`](https://learn.microsoft.com/connectors/office365/#when-an-email-is-flagged-(v4)-(preview)) | Flagged email (preview) |
| `OnNewMentionMeEmail` | [`OnNewMentionMeEmailV3`](https://learn.microsoft.com/connectors/office365/#when-a-new-email-mentioning-me-arrives-(v3)) | Email mentioning me |
| `OnNewCalendarEvent` | [`CalendarGetOnNewItemsV3`](https://learn.microsoft.com/connectors/office365/#when-a-new-event-is-created-(v3)) | New event |
| `OnCalendarUpdatedItems` | [`CalendarGetOnUpdatedItemsV3`](https://learn.microsoft.com/connectors/office365/#when-an-event-is-modified-(v3)) | Modified event |
| `OnUpcomingEvent` | [`OnUpcomingEventsV3`](https://learn.microsoft.com/connectors/office365/#when-an-upcoming-event-is-starting-soon-(v3)) | Upcoming event |
| `OnSharedMailboxNewEmail` | [`SharedMailboxOnNewEmailV2`](https://learn.microsoft.com/connectors/office365/#when-a-new-email-arrives-in-a-shared-mailbox-(v2)) | Shared mailbox email (opt-in) |
| Not included | [`CalendarGetOnChangedItemsV3`](https://learn.microsoft.com/connectors/office365/#when-an-event-is-added,-updated-or-deleted-(v3)) | Event added, updated or deleted; preview subscription fails with missing `TABLE` |

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) 1.33.0+
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later, signed in with permission to read and write trigger configurations in the Connector Namespace; polling state updates use `az rest`
- PowerShell 7 on Windows or `sh` on POSIX; a terminal and writable temporary directory for setup
- An Office 365 mailbox and permission to authorize the connection
- [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local) and Azurite for local development
- [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli) version 1.0.0b33. The deployment scripts use it automatically for sign-in and source pickers:

  ```bash
  curl -fsSL https://aka.ms/connector-namespace-cli-install | sh
  ```

  Or in PowerShell:

  ```powershell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

## Deploy to Azure

`azd up` provisions the Azure resources, helps you set up triggers, and deploys the Function App.

```cmd
cd office365App/polling
az login
azd auth login
azd env new office365-polling
azd up
```

Complete OAuth with the mailbox account to monitor. Use a different azd environment from webhook.

Choose at least one trigger and select the folders, calendars or mailboxes to monitor when prompted. Only selected triggers are enabled. Setup checks Azure's Connected status even if a sign-in window remains stale.

## Optional configuration

The catalog in `infra/scripts/polling-config.json` offers all seven handlers. `OnNewEmail` monitors Inbox. Other selected triggers collect their required folder, calendar, mailbox or subscription inputs interactively; choose actual connector calendar IDs rather than the placeholder `Calendar`. Shared-mailbox monitoring requires full access to the approved mailbox and is never enabled implicitly.

| Setting / option | Purpose |
| --- | --- |
| `CONNECTOR_NAMESPACE_LOCATION` | Namespace region; defaults to `westcentralus` |
| `APPLICATION_INSIGHTS_LOCATION=eastus2` | Telemetry region override if the host region lacks Application Insights |

Selections are saved in the active azd environment's `POLLING_TRIGGER_INPUTS` and reused. These settings are not encrypted; keep `.azure` out of source control. To choose again:

```cmd
azd env set POLLING_TRIGGER_INPUTS ""
azd up
```

Skipping a previously selected owned configuration disables it while preserving other writable properties, and disables its app listener. Never-created skipped configurations stay absent. Reselecting re-enables the same named configuration. This does not tear down upstream subscriptions or remove queued events. Setup refuses configurations with missing or conflicting destination ownership metadata; use a fresh environment for older deployments without that metadata.

If sign-in or trigger setup fails, correct the issue and rerun `azd up`. Resources already provisioned remain available. Deployment creates ignored `local.settings.json` only if missing; existing files are preserved byte-for-byte. Manually reconcile their listener switches or deliberately archive the file before regenerating.

## Local development

If the Function App is already deployed, stop it before running locally to avoid competing listeners.

1. Prepare `local.settings.json`.

   Use the file generated during successful `azd up`. Only if it is missing, rerun:

   ```cmd
   dotnet run --file ./infra/scripts/PollingSetup.cs -- finish
   ```

2. Sign in with your developer account for local credentials.

   ```cmd
   az login
   ```

3. Start Azurite in a separate terminal.

   ```cmd
   azurite
   ```

4. Build and start the local Functions host.

   ```cmd
   dotnet build
   func start
   ```

Do not copy cloud managed-identity settings locally. Functions host/deployment storage is required. Never commit local settings.

Worker telemetry uses the `ConnectorNamespace` identity settings: the Function App's system-assigned managed identity in Azure, or standard developer credentials when identity settings are absent locally.

## Verify

Check the connection is **Connected** and selected triggers are **Enabled** in [Connector Namespaces](https://connectors.azure.com/). Generate mail/calendar events and check worker logs for `Received <FunctionName> trigger (<Count> items)`; build/deployment success alone is not real-event verification. Delivery is at least once and source detection may be delayed.

Run `azd down --purge` when finished to remove deployed resources.

## More

- [Connector trigger payloads for Azure Functions](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [Office 365 Outlook connector reference](https://learn.microsoft.com/connectors/office365/)
