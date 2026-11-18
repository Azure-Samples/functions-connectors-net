# Planner polling quickstart

The Functions host receives and acknowledges queued Connector Namespace events using its system-assigned identity. No tunnel is needed. This standalone .NET isolated app uses Azure Connectors SDK 1.0.0 and Connector extension 1.0.0.

| Function | Planner operation | Scope |
| --- | --- | --- |
| `OnNewTask` | `OnNewTask_V3` | Tasks created in the selected basic plan |
| `OnCompleteTask` | `OnCompleteTask_V3` | Tasks completed in that plan |
| `OnTaskAssignedToMe` | `OnTaskAssignedToMe_V2` | Connection user's assignments across plans; opt-in |

Planner's source operations poll at a minimum six-minute interval. Host queue polling is a separate delivery step. Arbitrary task updates and premium plans are unsupported.

The plan-scoped operations use `groupId` and `id`, where `id` is the **plan ID**, not a task ID. Assignment uses no group/plan selectors: "me" is the user who consented to the connection.

## Prerequisites

Use .NET 10 SDK, Azure CLI >= 2.75.0, `azd` >= 1.33.0, and the [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli) version 1.0.0b33. The deployment scripts use the extension automatically for sign-in and source pickers. The signed-in identity needs read/write access to trigger configurations and permission to invoke source pickers.

Local execution also needs Functions Core Tools v4 and Azurite. Hooks use PowerShell 7 on Windows and `sh` on POSIX. Setup needs a terminal for choices and a writable temporary directory.

Have an explicitly approved Azure target with permission to deploy Flex Functions, Connector Namespace, storage, monitoring, and role assignments. Use an existing Microsoft 365 group-owned basic plan, its group and plan IDs, and a group-member connection user with Planner enabled in an eligible Microsoft 365 subscription. Tenant consent and conditional-access policies must permit [Planner connector OAuth](https://learn.microsoft.com/connectors/planner/).

The Function's system-assigned identity authenticates storage, monitoring, and Poll receive/acknowledge; local execution uses the developer granted connection access. Connector Namespace has a separate identity. Neither identity replaces the Planner user's OAuth consent.

## Deploy

`azd up` provisions the Azure resources, helps you set up triggers, and deploys the Function App.

Run from this directory, replacing `<unique-environment-name>` with a new name not used by another app:

```cmd
az login
azd auth login
azd env new "<unique-environment-name>"
azd up
```

Select the approved subscription/region when prompted. `CONNECTOR_NAMESPACE_LOCATION` defaults to `westcentralus`. Complete browser sign-in, choose at least one trigger, and select the group and plan to monitor when prompted. Only selected triggers are enabled.

`infra/scripts/polling-config.json` defines the available triggers; source choices depend on your account. Setup checks Azure's Connected status even if the browser window does not update. Deployment verifies delivery configuration and creates ignored `local.settings.json` only if missing. Existing settings are preserved byte-for-byte; review them manually when changing environments or choices.

## Optional

Assignment events cover the **connection user's tasks across plans**, not only a selected plan. Configure `OnTaskAssignedToMe` only with explicit scope approval.

Selections are saved in the active azd environment's `POLLING_TRIGGER_INPUTS` and reused. These settings are not encrypted; keep `.azure` out of source control. To choose again:

```cmd
azd env set POLLING_TRIGGER_INPUTS ""
azd up
```

Skipping a previously selected trigger disables its existing owned configuration while preserving other writable properties, and disables its app listener. Never-created skipped triggers stay absent. Reselecting re-enables the same named configuration. Setup refuses to overwrite webhook or unowned configurations.

If sign-in or trigger setup fails, correct the issue and rerun `azd up`. Resources already provisioned remain available.

## Local

For an already provisioned approved environment, regenerate missing settings without authorization or trigger changes:

```cmd
azd env select "<unique-environment-name>"
dotnet run --file ./infra/scripts/PollingSetup.cs -- finish
```

The same command works on Windows and POSIX and verifies the selected resources without changing source selections. Generated settings contain only Azurite/runtime configuration, Poll endpoint, trigger names, and enabled/disabled switches. The example defaults every listener to disabled and has a placeholder endpoint; it is not a runnable deployment configuration. Do not copy deployed managed-identity selectors into local settings. Existing files are never overwritten; reconcile their listener switches manually or deliberately archive them before regenerating.

**If the deployed app is running, stop it before local Poll testing** (`az functionapp stop -g <approved-resource-group> -n <approved-function-app>`). Cloud and local listeners otherwise compete for the same queue. Start Azurite separately, sign in with the developer identity granted connection access, then run:

```cmd
dotnet build
func start
```

Stop the local listener and restart the deployed app afterward with `az functionapp start` using the same approved resource group/app.

## Verify

On an approved basic plan, establish a trigger baseline, then create a test task and complete it. If assignment is enabled, assign an approved task to the OAuth connection user. Allow at least **six minutes** for source polling; a host queue poll is not a Planner source poll.

Observe one `Received OnNewTask trigger ({Count} tasks)` or `Received OnCompleteTask trigger ({Count} tasks)` receipt per invocation (and `OnTaskAssignedToMe` when enabled). Count is the actual SDK collection size, not a delivery count or metadata estimate. Build success alone does not prove source OAuth or end-to-end delivery.

## More

[Planner connector operations and limitations](https://learn.microsoft.com/connectors/planner/) · [Connector extension configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md)
