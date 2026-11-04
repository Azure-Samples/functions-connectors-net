# Azure DevOps - Poll delivery

An independent .NET isolated Function App receiving Connector Namespace Poll events, without a public callback or tunnel. See the [overview](../README.md) for exact operation IDs, entity parameters, source permissions and live-test boundaries.

## Quickstart

Install the root README prerequisites, including Azure CLI with `az rest` and the `connector-namespace` extension, which is still used to list configurations and manage source connections.

Windows hooks use PowerShell 7; Bash hooks need Bash and `jq` 1.7+ to preserve unmodified large numeric literals, plus the bundled `cygpath` when using Git Bash on Windows. Hooks need a writable private temporary directory.

The signed-in Azure identity must be allowed to list, read and update trigger configurations in the selected namespace. Azure permissions do not replace the source permissions described in the overview.

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

Provisioning creates or re-enables selected configurations at the same deterministic resource IDs. The postdeploy hook disables existing opt-out configurations through ARM REST while preserving their Poll delivery mode and original writable settings.

Never-created opt-out configurations are skipped. Existing configurations are retained, not deleted and recreated; ordinary opt-out needs no manual cloud cleanup.

An existing local settings file is intentionally preserved; manually reconcile its disabled flags after changing selections, or archive it deliberately before regenerating. Never run simultaneous local and deployed receivers against the same configuration when testing a single consumer.

Offline commands:

```pwsh
dotnet build --warnaserror
az bicep build --file infra/main.bicep --stdout
```

These commands do not prove live delivery or source authorization. Preview Connector Namespace Bicep type-schema warnings are expected; no cloud validation/deployment is performed by compilation.
