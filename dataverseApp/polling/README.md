# Microsoft Dataverse Polling Triggers (.NET)

Azure Functions sample using the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector) with `DeliveryMode = Poll`. The host receives events outbound from the Connector Namespace; no public callback or tunnel is needed.

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnDataverseRowChanged` | [`SubscribeWebhookTrigger`](https://learn.microsoft.com/connectors/commondataservice/#when-a-row-is-added,-modified-or-deleted) | Combined row added, modified or deleted |
| `OnDataverseActionPerformed` | [`BusinessEventsTrigger`](https://learn.microsoft.com/connectors/commondataservice/#when-an-action-is-performed) | Selected action performed |
| `OnDataverseRowAdded` | `SubscribeOnNewItems` | When a row is added |
| `OnDataverseRowModified` | `SubscribeOnUpdatedItems` | When a row is modified |
| `OnDataverseRowDeleted` | `SubscribeOnDeletedItems` | When a row is deleted |

These are the five operations displayed in the Connector Namespace portal.

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) 1.33.0+
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later
- PowerShell 7 on Windows or `sh` on POSIX; a terminal and writable temporary directory for setup
- An Azure subscription with permission to create resources and role assignments
- A Dataverse organization and an account permitted to register organization-scoped subscriptions
- For local execution: [Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local#install-the-azure-functions-core-tools) and [Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite#install-azurite)
- The [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli) version 1.0.0b33. The deployment scripts use it automatically for sign-in and source pickers:

```powershell
irm https://aka.ms/connector-namespace-cli-install-ps | iex
```

From Bash on macOS or Linux:

```bash
curl -fsSL https://aka.ms/connector-namespace-cli-install | sh
```

## Deploy to Azure

`azd up` provisions the Azure resources, helps you set up triggers, and deploys the Function App.

```cmd
cd dataverseApp/polling
az login
azd auth login
azd env new dataverse-polling
azd up
```

Authorize the Dataverse connection in the browser when prompted. Use a different azd environment name for each polling and webhook deployment.

Only selected triggers are enabled. Select a Flex Consumption app region and an Application Insights-supported `TELEMETRY_LOCATION` when prompted. The namespace defaults to `westcentralus` independently.

## Choose and configure triggers

Triggers need source inputs such as an environment, table, scope, or action. After browser authorization, setup asks Configure/Skip for each function, then collects inputs using connector metadata and source pickers. Choose at least one trigger. Setup confirms Azure reports Connected even if a sign-in window remains stale.

The catalog is `infra/scripts/polling-config.json`. The combined row-change trigger monitors rows being **added, modified, or deleted** in the selected table **across the Dataverse organization**, rather than only rows owned by the signed-in user. Setup asks you to choose the environment and table. Choose only sources you are authorized to monitor.

**Choose the combined row-change trigger OR the separate added/modified/deleted triggers you need.** Configuring both against the same source produces overlapping events: the same change can invoke both handlers.

For example (available choices depend on your account and connector metadata):

```text
Configure OnDataverseRowAdded?
  [1] Skip
  [2] Configure
Enter number (1-2): 2

Environment
  [1] Contoso development
Enter number ...: 1

Table
  [1] Accounts
  [2] Contacts
Enter number ...: 1
```
If no usable choices are available, the prompt asks for the exact connector identifier:

```text
No usable options returned for Table. Enter its connector identifier manually, or leave blank to skip.
Table (Enter to skip this trigger): accounts
```

Choose `Skip` to leave a trigger unselected. Where a manual fallback explicitly offers Enter to skip, leaving it blank skips that trigger. If the trigger has never been configured, skipping creates nothing. Otherwise setup disables the owned Connector Namespace configuration and corresponding app listener, but does not delete either or disable the entire Function App. Skipping all stops without changing trigger configurations or function settings.

### Rerun or correct a selection

Selections are saved in the active azd environment's `POLLING_TRIGGER_INPUTS` and reused by `azd up`. These settings are not encrypted; keep `.azure` out of source control.

To choose a different environment, table, action or trigger set, run from this folder:

```cmd
azd env set POLLING_TRIGGER_INPUTS ""
azd up
```

New answers change real trigger resources and app listener settings. Existing `local.settings.json` is preserved byte-for-byte; update its listener switches manually or deliberately archive it before generating a new file.

If sign-in or trigger setup fails, correct the issue and rerun `azd up`. Resources already provisioned remain available. Setup refuses configurations with missing or conflicting destination ownership metadata instead of adopting them; use a fresh sample environment for older configurations without that metadata.

## Verify and test

1. In [Connector Namespaces](https://connectors.azure.com/), check the connection is **Connected** and selected trigger configurations are **Enabled**. Check for source-registration errors or pending initialization before testing; Enabled alone does not prove event delivery.

2. Keep the deployed Function App running for Azure testing. In the Azure portal, open the Function App's **Overview**, find the corresponding connector-trigger function in the functions list, and click **Invocations and more** in its **Monitor** column. After each test below, check for a successful invocation of that function.

3. In [Power Apps](https://make.powerapps.com/), select the Dataverse environment and table you configured. Create a clearly named test row, filling in required fields. Save it, change a field and save again, then delete it when testing is complete. Use a row within your chosen scope, such as one you own for user-scoped triggers. Do not modify business rows.

   | Test operation | Expected function invocation for selected triggers |
   | --- | --- |
   | Create a row | `OnDataverseRowChanged` or `OnDataverseRowAdded` |
   | Modify and save the row | `OnDataverseRowChanged` or `OnDataverseRowModified` |
   | Delete the row | `OnDataverseRowChanged` or `OnDataverseRowDeleted` |

   Only expect invocations for triggers you selected. If both combined and separate triggers cover that row, both can run for the event. Wait for each expected invocation before the next operation, especially before deletion: Dataverse callbacks are asynchronous, and deleting too early can cancel pending update/action processing. Invocation records can take time to appear; refresh the invocation list as needed.

4. If you selected action-performed, execute the exact configured action using an authorized Dataverse client or application on your test row, where applicable. Creating or editing a row does not necessarily execute that action. Check **Invocations and more** for a successful `OnDataverseActionPerformed` invocation before deleting the row; a successful action response alone does not prove event delivery.

## Local development

Local testing still uses **real Azure and Dataverse resources**: the Connector Namespace, authorized Dataverse connection, and enabled Poll trigger configurations must already exist. Completing [Deploy to Azure](#deploy-to-azure), including its trigger-configuration prompts, creates these resources. Azurite only emulates local Functions storage; it does not simulate Dataverse events or replace the namespace.

Stop the deployed Function App before running locally to avoid competing listeners. Restart it after stopping the local host when you want Azure processing to resume.

1. A successful `azd up` creates `local.settings.json` in `dataverseApp/polling` only if missing. To generate a missing file separately, run `dotnet run --file ./infra/scripts/PollingSetup.cs -- finish`. For changed selections, follow [Rerun or correct a selection](#rerun-or-correct-a-selection). The example has a placeholder endpoint and disabled listeners, so it is not runnable.

2. Sign in as the provisioned developer principal:

   ```cmd
   az login
   ```

3. Start Azurite in a separate terminal:

   ```cmd
   azurite
   ```

4. Start the local host:

   ```cmd
   dotnet build
   func start
   ```

The locally running Functions host uses your developer credentials from `az login` to authenticate to the Connector Namespace and poll events. The deployed Azure Function App uses its managed identity instead.

With the host running, follow [Verify and test](#verify-and-test) to generate real Dataverse events and check the local terminal for the expected logs. Starting `func start` alone does not generate an event.

## Cleanup

Remove this environment's Azure resources from this folder:

```cmd
azd down --purge
```

## More

- [Connector trigger payloads for Azure Functions](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [Microsoft Dataverse connector reference](https://learn.microsoft.com/connectors/commondataservice/)
