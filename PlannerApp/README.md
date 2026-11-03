# Planner connector samples (.NET)

Standalone [polling](polling/) and [webhook](webhook/) Azure Functions isolated apps. Both use `Azure.Connectors.Sdk` **0.15.0-preview.1** typed Planner collections and Connector extension **1.0.0**. Each successful handler logs exactly one receipt with its trigger name and actual task collection count.

| Function | Current operation | Parameters | Event scope |
| --- | --- | --- | --- |
| `OnNewTask` | `OnNewTask_V3` | `groupId`, `id` (plan ID) | Tasks created in the selected basic plan |
| `OnCompleteTask` | `OnCompleteTask_V3` | `groupId`, `id` (plan ID) | Tasks completed in that plan |
| `OnTaskAssignedToMe` | `OnTaskAssignedToMe_V2` | None | Tasks assigned to the OAuth connection user, across their plans; opt-in |

Planner's source triggers are **batch GET polling operations**. Connector Namespace can deliver their results through a host-pulled **Poll** queue or a **Webhook** callback to Functions; webhook delivery does not mean Planner supplies a native webhook. The connector documents a minimum source polling frequency of **360 seconds**. Arbitrary title, description, due-date, or progress updates are not supported trigger events.

## Testability and prerequisites

| Prerequisite | Verified contract | Live status |
| --- | --- | --- |
| Source availability | Planner connector exposes all three operations in the westcentralus catalog and an existing Connector Namespace (checked 2026-10-30) | Metadata discovery only; no Planner connection authorized |
| License | Account needs Planner enabled in an eligible Microsoft 365 subscription; a premium Planner license does not make premium plans supported | Current user's license not verified |
| Plan/group | Connector and Graph Planner API support **basic plans only**. For this sample, use an existing Microsoft 365 group-owned plan and a connection user who is a group member with task access | No approved plan, group, or test account supplied |
| Source OAuth | Sign in/consent with that Planner user; tenant consent and conditional-access policies must permit the connector | Not exercised |
| Azure | Subscription permissions to deploy Flex Functions, Connector Namespace, and role assignments; supported regions | No new resources deployed |
| Poll delivery | Function SAMI (or local developer) has a connection access policy to receive/acknowledge | Offline contracts only; no live receive/acknowledge |
| Webhook delivery | Public HTTPS Functions connector endpoint and `connector_extension` system key; source polling still occurs | Offline contracts only; no live callbacks |

**What can be tested:** builds, generated binding metadata, typed payload decoding and actual handler logging, Bicep compilation, and missing-only local-settings hooks can be checked offline. Live end-to-end creation/completion testing requires explicit approval of an Azure target, basic plan/group, and OAuth account. Assignment additionally requires opting into its account-wide scope. No deployment, source changes, or consent should be performed without that approval. A live source test must establish the trigger baseline first, then create/complete/assign an approved test task and wait at least a source poll interval.

## Identity and source permissions

Function App **system-assigned managed identity** authenticates host storage, Azure Monitor, and Poll receive/acknowledge. Storage/monitor roles and the Poll connection access policy are assigned after the app exists. Connector Namespace retains a **different** system identity. Neither identity substitutes for the user's Planner OAuth connection.

The SDK worker uses `AddAzureClientsCore` and DI `AzureComponentFactory` to configure the Azure Monitor credential from `ConnectorNamespace`. Deployed configuration selects managed identity without an identity selector; generated local settings omit cloud identity selectors and use standard developer credentials.

Manual Microsoft Graph discovery or task setup is a **separate source permission flow**, not Azure RBAC or connector consent: read plans/tasks with the endpoint's documented delegated permissions (for example `Tasks.Read` for [listing plan tasks](https://learn.microsoft.com/graph/api/plannerplan-list-tasks?view=graph-rest-1.0)); task creation/update needs `Tasks.ReadWrite` and source access. Obtain consent for the specific manual tool if using one. The connector swagger instead advertises its own delegated operation scopes `Task.Create.TriggerV3`, `Task.Complete.TriggerV3`, and `Task.AssignedToMe.TriggerV2`; do not replace those with guessed Graph scopes in deployment parameters.

## References

[Planner connector operations, throttling, and basic-plan limitation](https://learn.microsoft.com/connectors/planner/) · [Planner licensing](https://learn.microsoft.com/office365/planner/planner-for-admins) · [Planner API and group authorization](https://learn.microsoft.com/graph/api/resources/planner-overview?view=graph-rest-1.0) · [Functions signature mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md#planner-connector) · [Poll registration contract](https://github.com/Azure/azure-functions-connector-extension/blob/main/.github/skills/poll-trigger-registration/SKILL.md) · [Webhook registration contract](https://github.com/Azure/azure-functions-connector-extension/blob/main/.github/skills/webhook-trigger-registration/SKILL.md)

Uses the repository's [MIT license](../LICENSE).
