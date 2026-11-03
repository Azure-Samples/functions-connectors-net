# Azure DevOps - Webhook delivery

An independent .NET isolated Function App receiving Connector Namespace HTTPS callbacks. Source operations are polled by the namespace; this is **not** native Azure DevOps service-hook registration. See the [overview](../README.md) for operations, source permissions and live-test boundaries.

## Quickstart

Install the root README prerequisites, PowerShell 7 for Windows hooks, or Bash, `jq` and `mktemp` for Bash hooks. Use a unique environment name. Only after the exact Azure/source target has been approved, run from **this directory**:

```pwsh
azd init
azd env new azuredevops-hook-demo
azd env set AZURE_LOCATION westcentralus
azd env set AZURE_TELEMETRY_LOCATION eastus2
azd provision
azd deploy
```

The example places the app and storage in West Central US and both telemetry resources in East US 2. If `AZURE_TELEMETRY_LOCATION` is unset, telemetry retains the app region; choose a region supported by both Application Insights and Log Analytics. `CONNECTOR_NAMESPACE_LOCATION` defaults independently to West Central US.

Supply the real `organization` and `project`, either through the provision prompts or `AZURE_DEVOPS_ORGANIZATION`/`AZURE_DEVOPS_PROJECT`. The parameter file maps `AZURE_DEVOPS_REPOSITORY`, `AZURE_DEVOPS_ENABLE_BUILD_TRIGGER`, `AZURE_DEVOPS_ENABLE_TFVC_TRIGGER`, `AZURE_DEVOPS_TEAM`, `AZURE_DEVOPS_ASSIGNED_TO` and `AZURE_DEVOPS_WORK_ITEM_TYPE` to the corresponding optional Bicep inputs, preserving their empty/false defaults. azd supplies the actual developer/deployer type through `AZURE_PRINCIPAL_TYPE`; direct ARM deployments must supply `userPrincipalType` explicitly. Function App SAMI grants remain explicitly `ServicePrincipal`.

`AZURE_DEVOPS_WORK_ITEM_TRIGGER_SELECTION` maps to `workItemTriggerSelection`: `All` (default) retains create/update/close; `CreatedOnly` disables update/close without removing any of the nine handlers or changing Git/build/TFVC/assignment opt-ins. After approval, set it to `CreatedOnly` with `AZURE_DEVOPS_WORK_ITEM_TYPE=Task` for a creation-only receiver. The emitted settings and definitions drive both cloud disabled flags and the hook's callbacks/local settings; existing local settings are still preserved, not silently rewritten.

Provision creates the app and connection independently; the postdeploy hook registers enabled Webhook callbacks after the Functions extension has created its `connector_extension` system key. It uses only supported CLI create/update arguments, updates existing callbacks without delete/recreate, and disables existing opt-out configurations. No Azure DevOps service hooks are created.

Authorize the `visualstudioteamservices` source connection **separately** using the approved current authentication type. Hooks do not request consent or change organization policies. Function App system identity authenticates storage and telemetry; it does not authorize access to Azure DevOps.

## Local callbacks

Install Azure Functions Core Tools v4 and Azurite. The hook creates a missing-only ignored `local.settings.json` containing only Azurite storage, worker runtime and disabled flags, preserving existing bytes and rejecting directories and links. Create-only writes do not overwrite a competing creator; they fail instead. Writes are not atomic, so an interrupted write can leave a partial file: inspect it and deliberately remove it before regenerating. No force-overwrite or automatic repair exists. Cloud identity selectors, telemetry secrets, callback URLs and keys are never copied there. The worker's Azure credential factory uses named `ConnectorNamespace` configuration, falling back to developer credentials locally and system identity when deployed.

Run Azurite, then start the local host with `func start --enableAuth`. Core Tools bypasses local key authentication by default, so enable it **before opening a public tunnel**. Use an approved public HTTPS tunnel to localhost and the **local host's** `connector_extension` system key, not the deployed app key; keep it out of source control and logs. Reconfigure callbacks explicitly:

```pwsh
./infra/scripts/postdeploy.ps1 -CallbackBaseUrl $publicTunnelBase -ConnectorExtensionKey $localSystemKey
```

```bash
bash ./infra/scripts/postdeploy.sh "$publicTunnelBase" "$localSystemKey"
```

The hook adds `/runtime/webhooks/connector?functionName=...` and query-string key authentication using an ephemeral notification file, cleaned even on CLI failure. Do not log or share that file, key or authenticated URL. Existing local settings are preserved byte-for-byte; manually reconcile disabled flags if selections changed.

Generate an approved safe source event and observe receipt-only logs. Changing callbacks redirects that environment away from the deployed host. **Before stopping the tunnel**, rerun the hook with **no callback arguments** to restore the deployed HTTPS hostname and deployed system key, then verify the callback target. If the tunnel or local key changes, explicitly refresh callbacks; the namespace cannot discover those changes. Disable configurations when an experiment ends. Never point a shared environment at a temporary tunnel.

Offline commands:

```pwsh
dotnet build --warnaserror
az bicep build --file infra/main.bicep --stdout
```

Preview Connector Namespace resource schemas are unavailable to Bicep; compilation is not proof of server-side deployment or live receipt.
