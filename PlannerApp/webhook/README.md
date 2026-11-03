# Planner webhook quickstart

Connector Namespace polls Planner and sends the results to the Functions connector webhook endpoint. This is **namespace Webhook delivery**, not a native Planner subscription. See the [overview](../README.md) for exact events and live-test prerequisites.

## Prerequisites

Use .NET 10 SDK, Azure CLI >= 2.75.0, `azd`, PowerShell >= 7.3 (.NET 7 or later for private staging streams), and the `connector-namespace` CLI extension from the [root prerequisites](../../README.md#prerequisites). Local execution needs Functions Core Tools v4, Azurite, and a public HTTPS tunnel. Bash hooks support Bash 3.2 syntax and require `jq`, `mktemp`, and POSIX `link`. To use Bash hooks, change `azure.yaml`'s postdeploy shell/run to `sh` / `./infra/scripts/postdeploy.sh`.

Have an explicitly approved Azure target and existing basic plan, group ID, and Planner-enabled OAuth user who belongs to that group. Review the [prerequisite matrix](../README.md#testability-and-prerequisites); premium plans and arbitrary task-update events are unsupported.

## Deploy

Run from this directory with an environment name different from the polling app:

```powershell
az login
azd auth login
azd env new planner-hook
azd env set PLANNER_GROUP_ID "<approved-group-id>"
azd env set PLANNER_PLAN_ID "<approved-basic-plan-id>"
azd up
```

Select the approved subscription/region. `CONNECTOR_NAMESPACE_LOCATION` defaults to `westcentralus`. After deployment, the hook retrieves the `connector_extension` system key, registers namespace callbacks, creates ignored local settings only when missing, and prompts for Planner OAuth consent. Existing settings are preserved byte-for-byte. Callback keys are placed only in temporary notification configuration files, which the hook cleans up; they are not printed or written into local settings.

## Optional

With explicit approval for account-wide assignment monitoring, set `PLANNER_ENABLE_ASSIGNED_TO_ME` to `true` and rerun `azd up`. This observes tasks assigned to the **connection user across plans**. Returning it to `false` disables the Function and any existing assignment trigger during postdeploy.

## Local

From an already provisioned approved environment:

```powershell
azd env select planner-hook
pwsh ./infra/scripts/postdeploy.ps1 -LocalSettingsOnly
dotnet build
func start --enableAuth
```

Start Azurite separately first. The Bash settings-only equivalent is `bash ./infra/scripts/postdeploy.sh --local-settings-only`. Generated settings contain only Azurite/runtime and enabled/disabled switches; use the example to review the shape. No cloud identity selectors are needed locally.

Core Tools v4 bypasses local key authentication by default. Start the host with `func start --enableAuth` before exposing its port through an approved public HTTPS tunnel; otherwise its endpoint is unauthenticated on the public internet. Retrieve the **local host's** `connector_extension` system key from the matching host secret in Azurite's `azure-webjobs-secrets` container using the [documented local-key workflow](https://github.com/Azure/azure-functions-connector-extension/blob/main/.github/skills/webhook-trigger-registration/SKILL.md#local-development-with-dev-tunnel). Do not use the deployed key, a function key, or a master key. In another terminal:

```powershell
pwsh ./infra/scripts/postdeploy.ps1 `
  -CallbackBaseUrl "https://<approved-public-tunnel-host>" `
  -ConnectorExtensionKey "<local-connector_extension-key>"
```

Bash accepts `--callback-base-url` and `--connector-extension-key`. Hooks update existing named namespace registrations without deleting them first. Tunnel metadata does not identify it as the deployed destination. **Callback redirection is a live configuration change requiring target approval**. Never commit/share the local key or signed configuration. Keep the tunnel/host running during testing; a local URL is not a public callback.

**Restore deployed callbacks before closing the tunnel:** rerun `pwsh ./infra/scripts/postdeploy.ps1` (or `bash ./infra/scripts/postdeploy.sh`) without local callback arguments. This retrieves the deployed system key and recreates cloud callback configurations. Then stop the local host and tunnel.

## Verify

Establish the source baseline, create a test task in the approved basic plan, then complete it. Assignment requires its separate opt-in and an approved task assigned to the OAuth user. Allow at least **six minutes** for Planner source polling; webhook delivery does not make it instantaneous.

Observe one trigger-name/actual SDK task-count receipt per invocation. A local typed-payload test proves handler decoding, not real Planner OAuth, namespace source polling, callback authentication, or Azure deployment.

## More

[Overview and testability](../README.md) · [Polling quickstart](../polling/README.md) · [Webhook registration](https://github.com/Azure/azure-functions-connector-extension/blob/main/.github/skills/webhook-trigger-registration/SKILL.md)
