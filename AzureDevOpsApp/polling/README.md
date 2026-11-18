# Azure DevOps - Poll delivery

An independent .NET 10 isolated Function App using Azure.Connectors.Sdk 1.0.0 to receive Connector Namespace Poll events, without a public callback or tunnel. The managed connector identifier is `visualstudioteamservices` (Azure DevOps, formerly VSTS).

## Source operations and permissions

Every operation requires `account` (organization name, not URL) and `project` (existing project name). Interactive setup collects these from connector metadata after authentication. Confirm access to the exact organization/project before deployment; Azure resource permissions and GitHub access do not grant Azure DevOps access.

| Operation ID | Selection | Source requirements |
| --- | --- | --- |
| `OnWorkItemCreatedV2` | Choose during setup | Read work items in the project/area |
| `OnWorkItemUpdatedV2` | Choose during setup | Read work items; link-only changes do not trigger |
| `OnWorkItemClosedV2` | Choose during setup | Read work items; closed states depend on the process |
| `OnWorkItemAssignedV2` | Opt-in | `team` and `wiql__System_AssignedTo`; read work items and team membership |
| `OnGitPush` | Opt-in | Existing `repository` name and repository Read |
| `OnGitPullCreated` | Opt-in | Existing `repository` name and repository Read |
| `OnGitPullClosed` | Opt-in | Existing `repository` name and repository Read |
| `OnBuildCompleted` | Opt-in | Existing build definitions and View builds |
| `OnTfvcCheckIn` | Opt-in | Existing TFVC project and source-control Read |

Choose Configure or Skip for each trigger; only selected listeners are enabled. Optional work-item type filters use `wiql__System_WorkItemType`. For creation-only monitoring, select `OnWorkItemCreated` and skip the other work-item triggers. Do not enable TFVC in a Git-only project or queue a production pipeline merely to generate a test event.

Source authentication is separate from the Function App's system-assigned identity. The template creates the connection directly with Microsoft Entra ID OAuth (`EntraOAuth`); setup launches browser sign-in if it is not Connected. PAT and deprecated Default OAuth are not used. The connection user needs the project's resource permissions. Follow the [connector authentication requirements](https://learn.microsoft.com/connectors/visualstudioteamservices/), including applicable organization policies.

For EntraOAuth, sign in through the organization's home tenant; organizations associated with another tenant are not listed for that connection. A Connected connection or Enabled configuration alone does not prove delivery: validate an approved event against the selected operation and actual handler.

The five build/Git/TFVC handlers use SDK envelopes and log only the trigger name and actual collection count. Work-item V2 handlers receive raw strings because SDK 1.0.0 does not provide matching V2 payload models; their logs contain only the trigger name.

## Quickstart

`azd up` provisions the Azure resources, helps you set up triggers, and deploys the Function App.

Install the [.NET 10 SDK](https://dotnet.microsoft.com/download), [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) 1.33.0+, [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0+, and the [`connector-namespace` extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli) version 1.0.0b33. The deployment scripts use the extension automatically for sign-in and source pickers.

Windows hooks use PowerShell 7; POSIX hooks use `sh`. Helpers need a writable temporary directory and a terminal for interactive choices.

The deployment identity needs permission to create the app, namespace and storage/telemetry resources and assign their required roles. Setup needs permission to read/update trigger configurations and invoke connector source pickers. These permissions do not replace source permissions.

Local runs additionally need Functions Core Tools and Azurite. Run from **this directory**, with an environment name distinct from the webhook app.

After the exact Azure deployment target and source organization/project have been approved:

```cmd
az login
azd auth login
azd env new azuredevops-poll-demo
azd env set AZURE_LOCATION westcentralus
azd env set AZURE_TELEMETRY_LOCATION eastus2
azd up
```

The example places the app and storage in West Central US and both telemetry resources in East US 2. If `AZURE_TELEMETRY_LOCATION` is unset, telemetry retains the app region; choose a region supported by both Application Insights and Log Analytics. `CONNECTOR_NAMESPACE_LOCATION` defaults independently to West Central US.

Complete browser sign-in, choose at least one trigger, and select the organization, project and other sources to monitor when prompted. Only selected triggers are enabled.

The full trigger/auth catalog lives in `infra/scripts/polling-config.json`; available organizations, projects, repositories, teams and other choices depend on your account. Setup confirms Azure reports Connected even when a sign-in window remains stale.

Deployment verifies the selected configurations and creates ignored `local.settings.json` only if missing, with Azurite storage, the real Poll endpoint, trigger names and lowercase disabled flags. Existing files are preserved byte-for-byte. It does not copy cloud identity selectors or telemetry credentials. Local credentials use the signed-in developer; cloud credentials use managed identity. An interrupted create can leave a partial file; inspect and deliberately archive it before regenerating.

Only if `local.settings.json` is missing after successful provisioning, generate it with `dotnet run --file ./infra/scripts/PollingSetup.cs -- finish`. This verifies the selected resources without changing source selections.

Start Azurite separately, then:

```cmd
az login
func start
```

Only after approval, generate a safe event in the chosen target. Typed handlers log only their name and actual SDK collection count; raw V2 handlers log only their name. Poll invocation cardinality is single (one connector envelope per invocation), not a count inferred from the delivery batch.

## Stopping and conditional triggers

Stopping the local host does **not** stop namespace polling. Choices are saved in the active azd environment's `POLLING_TRIGGER_INPUTS` and reused on reruns. These settings are not encrypted; keep `.azure` out of source control. To choose again:

```cmd
azd env set POLLING_TRIGGER_INPUTS ""
azd up
```

Provisioning creates selected configurations explicitly in the **Enabled** state with **Poll** delivery and re-enables reselected configurations at the same deterministic resource IDs. Setup disables skipped owned configurations while preserving their other writable properties, and refuses to overwrite webhook or unowned configurations. It also disables the corresponding app listeners.

Never-created opt-out configurations are skipped. Existing configurations are retained, not deleted and recreated; ordinary opt-out needs no manual cloud cleanup.

An existing local settings file is intentionally preserved; manually reconcile its disabled flags after changing selections, or archive it deliberately before regenerating. Never run simultaneous local and deployed receivers against the same configuration when testing a single consumer.

If sign-in or trigger setup fails, correct the issue and rerun `azd up`. Resources already provisioned remain available.

`AZURE_DEVOPS_POLLING_READY_INSTANCE_COUNT` defaults to `0`. Setting it to `1` reserves a paid instance for **each selected function**; validate connector scale-from-zero support and cost before opting in.

Offline commands:

```cmd
dotnet build --warnaserror
az bicep build --file infra/main.bicep --stdout
az bicep build --file infra/poll-triggers.bicep --stdout
az bicep build --file infra/function-app.bicep --stdout
```

These commands do not prove live delivery or source authorization. Preview Connector Namespace Bicep type-schema warnings are expected; no cloud validation/deployment is performed by compilation.
