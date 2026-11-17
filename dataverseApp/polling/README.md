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
- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later
- For deployment hooks: PowerShell 7.3 or later on Windows; Bash and [jq](https://jqlang.org/download/) on macOS/Linux (PowerShell is not required)
- An Azure subscription with permission to create resources and role assignments
- A Dataverse organization and an account permitted to register organization-scoped subscriptions
- For local execution: [Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local#install-the-azure-functions-core-tools) and [Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite#install-azurite)
- The [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli):

```powershell
irm https://aka.ms/connector-namespace-cli-install-ps | iex
```

From Bash on macOS or Linux:

```bash
curl -fsSL https://aka.ms/connector-namespace-cli-install | sh
```

## Deploy to Azure

```cmd
cd dataverseApp\polling
az login
azd auth login
azd env new dataverse-polling
azd up
```

Authorize the Dataverse connection in the browser when prompted. Use a different azd environment name for each polling and webhook deployment.

The postdeploy hook runs the PowerShell implementation on Windows and the native Bash implementation on macOS/Linux.

## Choose and configure triggers

Triggers need source inputs such as an environment, table, scope, or action. After browser authorization, the postdeploy hook asks which of the five triggers to configure, then collects their required inputs. Choose at least one trigger.

**Choose the combined row-change trigger OR the separate added/modified/deleted triggers you need.** Configuring both against the same source produces overlapping events: the same change can invoke both handlers.

For example (available choices depend on your account and connector metadata):

```text
OnDataverseRowAdded (SubscribeOnNewItems)
Configure this trigger?
  [1] Configure
  [2] Skip
Enter number ...: 1

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

**Pressing Enter at any prompt skips that entire trigger**, not just that field. Choosing `Skip` does the same. If the trigger has never been configured, skipping it creates nothing. If you configured it on an earlier run and skip it now, the hook disables its Connector Namespace configuration and corresponding function, but does not delete either or disable the entire Function App. Choose at least one trigger; skipping all stops without changing trigger configurations or function settings.

### Rerun or correct a selection

Selections are saved in the selected azd environment as `DATAVERSE_POLLING_TRIGGER_INPUTS`. Ordinary `azd up` or `azd hooks run postdeploy` reuses them.

If you chose the wrong environment, table, or action, run either command from this folder to choose your triggers again and regenerate `local.settings.json`. Your new answers change the real trigger configuration resources in your Azure Connector Namespace. The corresponding Azure function settings are also updated.

```powershell
pwsh -File ./infra/scripts/postdeploy.ps1 -Reconfigure -ForceLocalSettings
```

```bash
bash ./infra/scripts/postdeploy.sh --reconfigure --force-local-settings
```

These commands replace `local.settings.json`, so save any custom values first.

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

Local testing still uses **real Azure and Dataverse resources**: the Connector Namespace, authorized Dataverse connection, and enabled Poll trigger configurations must already exist. Completing [Deploy to Azure](#deploy-to-azure), including its postdeploy prompts, creates the Azure resources and configures your selected triggers. Azurite only emulates local Functions storage; it does not simulate Dataverse events or replace the namespace.

Stop the deployed Function App before running locally to avoid competing listeners. Restart it after stopping the local host when you want Azure processing to resume.

1. A successful `azd up` creates `local.settings.json` in `dataverseApp\polling` if it does not already exist. If the file is missing, outdated, or you chose the wrong triggers, use the commands in [Rerun or correct a selection](#rerun-or-correct-a-selection) to choose your triggers again and regenerate it.

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

```powershell
azd down --purge
```

```bash
azd down --purge
```

[License](../../LICENSE).

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [Microsoft Dataverse connector reference](https://learn.microsoft.com/connectors/commondataservice/)
