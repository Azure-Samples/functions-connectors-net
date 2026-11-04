# Planner polling quickstart

The Functions host receives and acknowledges queued Connector Namespace events using its system-assigned identity. No tunnel is needed. See the [overview](../README.md) for supported events, identity separation, and live-test prerequisites.

## Prerequisites

Use .NET 10 SDK, Azure CLI >= 2.75.0, `azd`, PowerShell >= 7.3 (.NET 7 or later for private staging streams), and the `connector-namespace` CLI extension from the [root prerequisites](../../README.md#prerequisites). Poll state updates use core Azure CLI `az rest`; the extension remains required for trigger listing and connection/consent operations. The signed-in identity needs read/write access to the namespace's trigger configurations.

Local execution also needs Functions Core Tools v4 and Azurite. Bash hooks support Bash 3.2 syntax and require `jq` 1.7+, `mktemp`, POSIX `link`, and permission to create private temporary files beside the scripts; on Windows, use Git Bash. To use Bash hooks, change `azure.yaml`'s postdeploy shell/run to `sh` / `./infra/scripts/postdeploy.sh`.

Have an explicitly approved Azure target and existing basic plan, group ID, and Planner-enabled connection user who belongs to that group. Premium plans are unsupported. Review the [prerequisite matrix](../README.md#testability-and-prerequisites) before deployment.

## Deploy

Run from this directory, using an environment name different from the webhook app:

```powershell
az login
azd auth login
azd env new planner-poll
azd env set PLANNER_GROUP_ID "<approved-group-id>"
azd env set PLANNER_PLAN_ID "<approved-basic-plan-id>"
azd up
```

Select the approved subscription/region when prompted. `CONNECTOR_NAMESPACE_LOCATION` defaults to `westcentralus`. Bicep provisions Poll trigger configurations and derives the polling endpoint from the service response; it does not guess namespace runtime URLs. Postdeploy creates ignored `local.settings.json` only when missing and prompts for Planner source OAuth consent. Existing settings are preserved byte-for-byte; review them manually when changing environments.

## Optional

Assignment events cover the **connection user's tasks across plans**, not only `PLANNER_PLAN_ID`. With explicit scope approval, set `PLANNER_ENABLE_ASSIGNED_TO_ME` to `true` and rerun `azd up`. Returning it to `false` disables the Function and any existing assignment trigger during postdeploy. The hook reads that trigger's exact resource ID and disables it with a REST GET/PUT, preserving its Poll configuration.

## Local

For an already provisioned approved environment, regenerate missing settings without authorization or trigger changes:

```powershell
azd env select planner-poll
pwsh ./infra/scripts/postdeploy.ps1 -LocalSettingsOnly
```

The Bash equivalent is `bash ./infra/scripts/postdeploy.sh --local-settings-only`. Generated settings contain only Azurite/runtime configuration, Poll endpoint, trigger names, and enabled/disabled switches. The example file documents that shape; do not copy deployed managed-identity selectors into local settings.

**If the deployed app is running, stop it before local Poll testing** (`az functionapp stop -g <approved-resource-group> -n <approved-function-app>`). Cloud and local listeners otherwise compete for the same queue. Start Azurite separately, sign in with the developer identity granted connection access, then run:

```powershell
dotnet build
func start
```

Stop the local listener and restart the deployed app afterward with `az functionapp start` using the same approved resource group/app.

## Verify

On an approved basic plan, establish a trigger baseline, then create a test task and complete it. If assignment is enabled, assign an approved task to the OAuth connection user. Allow at least **six minutes** for source polling; a host queue poll is not a Planner source poll.

Observe one `Received OnNewTask trigger ({Count} tasks)` or `Received OnCompleteTask trigger ({Count} tasks)` receipt per invocation (and `OnTaskAssignedToMe` when enabled). Count is the actual SDK collection size, not a delivery count or metadata estimate. Build success alone does not prove source OAuth or end-to-end delivery.

## More

[Overview and testability](../README.md) · [Webhook quickstart](../webhook/README.md) · [Connector extension configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md)
