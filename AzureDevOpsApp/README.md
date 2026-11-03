# Azure DevOps connector samples

Standalone .NET isolated apps: [polling](polling/) receives and acknowledges events from Connector Namespace; [webhook](webhook/) receives HTTPS callbacks from that namespace. Both use **polling-source connector operations**. Webhook delivery is not a native Azure DevOps service-hook subscription, and no service hook is created by these samples.

The actual managed connector identifier is `visualstudioteamservices`, confirmed against the current namespace Swagger. "VSTS" is historical branding; `vsts` is not a valid connector identifier in the checked catalog.

## Operations and prerequisites

| Operation ID | Default | Additional parameters / source permission |
| --- | --- | --- |
| `OnWorkItemCreatedV2` | Enabled | Read work items in the project/area |
| `OnWorkItemUpdatedV2` | Enabled | Read work items; link-only updates do not trigger |
| `OnWorkItemClosedV2` | Enabled | Read work items; process-specific closed states |
| `OnWorkItemAssignedV2` | Opt-in | `team`, `wiql__System_AssignedTo`; read work items and team membership |
| `OnBuildCompleted` | Opt-in | Existing build definition(s); view builds |
| `OnGitPush` | Opt-in | `repository`; repository Read |
| `OnGitPullCreated` | Opt-in | `repository`; repository Read |
| `OnGitPullClosed` | Opt-in | `repository`; repository Read |
| `OnTfvcCheckIn` | Opt-in | Existing TFVC project; source-control Read |

All operations require `account` (organization **name**, not URL) and `project` (existing project **name**). Bicep maps `organization` to `account`. `repository` is the existing repository name, not a GitHub repository. `team` and `assignedTo` must both be nonempty to enable assignment. `workItemType` optionally maps to `wiql__System_WorkItemType` for work-item triggers. Names and permissions must be checked against the real organization and project before deployment.

Both modes default `workItemTriggerSelection` to `All` (create/update/close). Set `AZURE_DEVOPS_WORK_ITEM_TRIGGER_SELECTION=CreatedOnly` to disable update/close while retaining all nine handlers and independent Git/build/TFVC/assignment opt-ins. This selection flows through emitted trigger configurations, disabled flags and hooks; it does not overwrite existing local settings.

The five build/Git/TFVC handlers use released `VisualStudioTeamServicesOn*TriggerPayload` SDK envelopes and log only trigger name and the actual `Body.Value.Count`. Missing collections throw instead of manufacturing a zero count. Work-item **V2** operations have dynamic output and no matching released V2 payload model; their handlers use raw `string` and log only the trigger name. Released similarly named work-item payloads describe the **deprecated V1** operations and are deliberately not used.

## Authentication and permissions

Cloud resource setup is separate from Azure DevOps authentication. Each Function App uses its system-assigned managed identity for package/host storage, AAD-only Application Insights, and Connector Namespace access. Storage/monitoring roles and the Function App connection access policy are deployed **after** the app, using its nonempty principal. Namespace creation and Poll configuration do not depend on the app. Developer access policies and storage/monitoring roles are retained.

`location` places the Function App, plan and storage; `telemetryLocation` places both Application Insights and its Log Analytics workspace. Telemetry defaults to the app region for compatibility. Override it with `AZURE_TELEMETRY_LOCATION` when necessary: Application Insights does not support West Central US, so a West Central US app needs a supported telemetry region such as East US 2. `CONNECTOR_NAMESPACE_LOCATION` independently defaults to West Central US. Both mode templates include `infra/main.parameters.json` bindings for these azd environment variables.

`userPrincipalId` defaults to the existing deployer's object ID, whether the deployer is a human, service principal or managed identity. ARM's `deployer()` does not expose a reliable principal-type property. The parameter files therefore bind `userPrincipalType` to azd's authenticated `AZURE_PRINCIPAL_TYPE`, which is `User` for interactive sign-in and `ServicePrincipal` for application/managed-identity sign-in. There is no guessed type default. Direct ARM callers must supply the actual `userPrincipalType` (`User`, `ServicePrincipal` or `Group`) for their selected ID. The newly created Function App identity remains explicitly `ServicePrincipal`. Role IDs, scopes and deterministic assignment names are unchanged; an empty `userPrincipalId` still omits developer grants.

Authorize the source connection manually using a supported current authentication type: `EntraOAuth` user sign-in, `OauthSP`, `CertOauth`, or `connectionfic` (FIC). PAT is **not supported**. Do not use the deprecated Default authentication option or register a new legacy Azure DevOps OAuth application. User connections use the signed-in user's organization permissions; application connections require adding that service principal to the organization and granting the required access level, project and resource permissions. Entra application permissions alone do not grant Azure DevOps access. FIC setup is connection-specific and must follow the connector's current documentation.

The currently installed namespace CLI exposes generic token consent but **no authentication-type selection flag** on connection create/update. The Bicep still creates an unauthenticated connection descriptor only; it does not select `EntraOAuth`. The namespace ARM API `2026-05-01-preview` was verified to accept `properties.parameterValueSet: { "name": "EntraOAuth", "values": {} }` for a `visualstudioteamservices` connection, and the Connector Namespace portal's user consent flow was verified to produce `Connected`. Configure the selected auth set separately with approval before consent; do not assume generic consent selects it. The other authentication types remain catalog-verified, not live-tested in these samples.

The connector parameter documentation requires the organization OAuth access policy where applicable; have the organization administrator confirm the selected authentication method and policy. Namespace/Function managed identities do **not** replace this source connection authentication. No consent, service-principal onboarding, or organization-policy changes are performed by the hooks.

## What can be tested?

Offline: restore/build each app, compile Bicep, exercise SDK collections and raw handlers with synthetic private-marker payloads, and mock the PowerShell/Bash hooks. Package versions were checked through the configured feed: .NET 10, Worker 2.52.0, Worker SDK 2.1.0, Connector extension 1.0.0, Azure.Connectors.Sdk **0.15.0-preview.1**, Microsoft.Extensions.Azure 1.14.1. No repository feed configuration is needed.

Live local Poll: with separately approved connection creation, EntraOAuth consent, access policies, one Task-created configuration and one unassigned Task creation in `azfunc/AzFunc-DevSessions`, the actual `OnWorkItemCreated` handler logged receipt and succeeded after about 187 seconds. A read-only source query correlated the receipt with the single fixture. The fixture was left New and unassigned; local services were stopped after bounded observation. This validates local `OnWorkItemCreatedV2` Poll delivery only, not cloud deployments, Webhook delivery or the other operations.

Before another live test, approve the **exact organization/project and action**: create/update/assign/close a disposable work item in a chosen area; push to a disposable branch or create/close a PR in a chosen repository; or queue a chosen safe build. TFVC requires a separately approved TFVC target. Native service-hook experiments, if desired outside these samples, additionally require approved subscription/event scopes and the appropriate service-hook permissions. Never assume GitHub access confers Azure DevOps access. Fixture cleanup and each additional write or deletion need their own approval.

Cloud Poll infrastructure provisioning has been verified, but no cloud application package was deployed. Cloud worker identity/storage/telemetry behavior and Webhook E2E delivery remain unverified. Bicep reports missing type schemas for the preview Connector Namespace resources, so compilation alone cannot validate their server-side properties or cloud RBAC behavior.

## References

- [Current connector operations, authentication, parameters and limitations](https://learn.microsoft.com/connectors/visualstudioteamservices/)
- [Connector Namespace CLI](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli) (`connector show --export-swagger` confirms the namespace's actual surface)
- [Released SDK trigger contracts](https://github.com/Azure/Connectors-NET-SDK/blob/main/docs/triggers.md)
- [Connector extension Poll sample](https://github.com/Azure/azure-functions-connector-extension/tree/main/test/poll)
- [Azure DevOps service principal and managed identity authorization](https://learn.microsoft.com/azure/devops/integrate/get-started/authentication/service-principal-managed-identity)

These are preview evaluation samples, not production deployments. The repository-root [LICENSE](../LICENSE) applies.
