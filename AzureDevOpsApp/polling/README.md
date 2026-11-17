# Azure DevOps - Poll delivery

An independent .NET 10 isolated Function App using Azure.Connectors.Sdk 1.0.0 to receive Connector Namespace Poll events, without a public callback or tunnel. The managed connector identifier is `visualstudioteamservices` (Azure DevOps, formerly VSTS).

## Source operations and permissions

Every operation requires `account` (organization name, not URL) and `project` (existing project name). Provisioning maps `organization` to `account`. Confirm access to the exact organization/project before deployment; Azure resource permissions and GitHub access do not grant Azure DevOps access.

| Operation ID | Selection | Source requirements |
| --- | --- | --- |
| `OnWorkItemCreatedV2` | Default | Read work items in the project/area |
| `OnWorkItemUpdatedV2` | Default | Read work items; link-only changes do not trigger |
| `OnWorkItemClosedV2` | Default | Read work items; closed states depend on the process |
| `OnWorkItemAssignedV2` | Opt-in | `team` and `wiql__System_AssignedTo`; read work items and team membership |
| `OnGitPush` | Opt-in | Existing `repository` name and repository Read |
| `OnGitPullCreated` | Opt-in | Existing `repository` name and repository Read |
| `OnGitPullClosed` | Opt-in | Existing `repository` name and repository Read |
| `OnBuildCompleted` | Opt-in | Existing build definitions and View builds |
| `OnTfvcCheckIn` | Opt-in | Existing TFVC project and source-control Read |

`workItemType` optionally filters work-item operations through `wiql__System_WorkItemType`. Git, build, assignment and TFVC inputs remain disabled/empty until explicitly selected. Do not enable TFVC in a Git-only project or queue a production pipeline merely to generate a test event.

Source authentication is separate from the Function App's system-assigned identity. Configure the approved connection authentication type (`EntraOAuth`, `OauthSP`, `CertOauth`, or `connectionfic`) before consent. PAT and deprecated Default OAuth are not supported paths here. User connections need the user's project/resource permissions; application identities must be onboarded into the organization with the required access level and permissions. Follow the [connector authentication requirements](https://learn.microsoft.com/connectors/visualstudioteamservices/), including applicable organization policies. Hooks neither select an authentication type nor perform consent.

For EntraOAuth, sign in through the organization's home tenant; organizations associated with another tenant are not listed for that connection. A Connected connection or Enabled configuration alone does not prove delivery: validate an approved event against the selected operation and actual handler.

The five build/Git/TFVC handlers use SDK envelopes and log only the trigger name and actual collection count. Work-item V2 handlers receive raw strings because SDK 1.0.0 does not provide matching V2 payload models; their logs contain only the trigger name.

## Quickstart

Install the [.NET 10 SDK](https://dotnet.microsoft.com/download), [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd), [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0+ with `az rest`, and the [`connector-namespace` extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli). The extension is still used to list configurations and manage source connections.

Windows hooks use PowerShell 7; Bash hooks need Bash and `jq` 1.7+ to preserve unmodified large numeric literals, plus the bundled `cygpath` when using Git Bash on Windows. Hooks need a writable private temporary directory.

The deployment identity needs permission to create the app, namespace and storage/telemetry resources and assign their required roles. Postdeploy needs permission to list, read and update trigger configurations in the selected namespace. These permissions do not replace source permissions.

Local runs additionally need Functions Core Tools and Azurite. Run from **this directory**, with an environment name distinct from the webhook app.

After the exact Azure deployment target and source organization/project have been approved:

```pwsh
azd init
azd env new azuredevops-poll-demo
azd env set AZURE_LOCATION westcentralus
azd env set AZURE_TELEMETRY_LOCATION eastus2
azd provision
azd deploy
```

The example places the app and storage in West Central US and both telemetry resources in East US 2. If `AZURE_TELEMETRY_LOCATION` is unset, telemetry retains the app region; choose a region supported by both Application Insights and Log Analytics. `CONNECTOR_NAMESPACE_LOCATION` defaults independently to West Central US.

Provision prompts for the real `organization` and `project` if `AZURE_DEVOPS_ORGANIZATION` and `AZURE_DEVOPS_PROJECT` are unset. By default only work-item create/update/close triggers are enabled. The parameter file maps `AZURE_DEVOPS_REPOSITORY`, `AZURE_DEVOPS_ENABLE_BUILD_TRIGGER`, `AZURE_DEVOPS_ENABLE_TFVC_TRIGGER`, `AZURE_DEVOPS_TEAM`, `AZURE_DEVOPS_ASSIGNED_TO` and `AZURE_DEVOPS_WORK_ITEM_TYPE` to the corresponding optional Bicep inputs, preserving their empty/false defaults. Set them with `azd env set` only after confirming the target and permissions. Provisioning configures source polling but does not authorize the connection. azd supplies the actual developer/deployer type through `AZURE_PRINCIPAL_TYPE`; direct ARM deployments must supply `userPrincipalType` explicitly. Function App SAMI grants remain explicitly `ServicePrincipal`.

`AZURE_DEVOPS_WORK_ITEM_TRIGGER_SELECTION` maps to `workItemTriggerSelection`: `All` (default) retains create/update/close; `CreatedOnly` disables update/close without removing any of the nine handlers or changing the other opt-ins. The emitted trigger definitions drive both cloud settings and the postdeploy hook's local disabled flags. A `Task` type filter alone does not select creation only.

After separate deployment approval, select a creation-only test explicitly:

```pwsh
azd env set AZURE_DEVOPS_WORK_ITEM_TRIGGER_SELECTION CreatedOnly
azd env set AZURE_DEVOPS_WORK_ITEM_TYPE Task
```

Separately authorize the new `visualstudioteamservices` connection in Connector Namespace with the approved current authentication type. The postdeploy hook deliberately does **not** perform consent. Application identity/secret/certificate/FIC setup must follow the connector's authentication documentation rather than being embedded in settings.

The hook creates **missing-only**, ignored `local.settings.json` with Azurite storage, named Poll endpoint/configuration settings, and enabled/disabled flags. It preserves an existing file byte-for-byte and rejects directories and links. Create-only writes do not overwrite a competing creator; they fail instead. Writes are not atomic, so an interrupted write can leave a partial file: inspect it and deliberately remove it before regenerating. No force-overwrite or automatic repair exists. The hook does not copy cloud credential selectors, cloud host-storage identity settings, telemetry secrets, or callback credentials. Local credentials fall back to the signed-in developer through the Azure SDK factory; deployed worker telemetry uses `ConnectorNamespace`'s system-assigned managed identity configuration.

Start Azurite separately, then:

```pwsh
az login
func start
```

Only after approval, generate a safe event in the chosen target. Typed handlers log only their name and actual SDK collection count; raw V2 handlers log only their name. Poll invocation cardinality is single (one connector envelope per invocation), not a count inferred from the delivery batch.

## Stopping and conditional triggers

Stopping the local host does **not** stop namespace polling. Change the relevant opt-in parameters and run `azd up` to apply the selected lifecycle.

Provisioning creates selected configurations explicitly in the **Enabled** state with **Poll** delivery and re-enables reselected configurations at the same deterministic resource IDs. The postdeploy hook disables existing opt-out configurations through ARM REST while preserving their Poll delivery mode and original writable settings.

Never-created opt-out configurations are skipped. Existing configurations are retained, not deleted and recreated; ordinary opt-out needs no manual cloud cleanup.

An existing local settings file is intentionally preserved; manually reconcile its disabled flags after changing selections, or archive it deliberately before regenerating. Never run simultaneous local and deployed receivers against the same configuration when testing a single consumer.

Offline commands:

```pwsh
dotnet build --warnaserror
az bicep build --file infra/main.bicep --stdout
```

These commands do not prove live delivery or source authorization. Preview Connector Namespace Bicep type-schema warnings are expected; no cloud validation/deployment is performed by compilation.
