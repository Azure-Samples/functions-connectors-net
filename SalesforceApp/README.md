# Salesforce connector samples

Receive Salesforce record-created and record-modified events in two independent .NET 10 isolated Functions apps: [polling](polling/) uses outbound host-pull delivery; [webhook](webhook/) receives authenticated callbacks from Connector Namespace. Both monitor Salesforce through **polling-backed connector operations**. Webhook here means Azure delivery, not Salesforce native outbound messages, Change Data Capture, Streaming API or Platform Events.

| Function | Current operation | Released SDK payload |
| --- | --- | --- |
| `OnNewRecord` | `GetOnNewItems` | `SalesforceOnNewItemsTriggerPayload` |
| `OnUpdatedRecord` | `GetOnUpdatedItems` | `SalesforceOnUpdatedItemsTriggerPayload` |

See the [Salesforce connector reference](https://learn.microsoft.com/connectors/salesforce/#triggers) for trigger details. Required parameter: `table` (exact object API name returned by `GetTables`). Optional parameters: `$filter`, `$orderby`, `$select`; these are OData queries, not SOQL. The connector resolves its internal `connectionId` from the connection resource; it is not a trigger parameter. Avoid nullable sort fields. Keep `Id`, `CreatedDate` and `LastModifiedDate` readable; the connector documentation warns that updated-item tracking can include newly created records and needs the date fields. Modification detection does not detect attachment changes.

The configured NuGet feed was checked on 2026-10-30: SDK `0.15.0-preview.1`, Connector `1.0.0`, Worker `2.52.0`, Worker SDK `2.1.0`, and Microsoft.Extensions.Azure `1.14.1`. Both handlers bind released SDK collections (`payload.Body.Value`) and log only the actual collection count and trigger name. Missing collections fail explicitly rather than inventing a zero count. Dynamic object fields remain in SDK `Item` models; no raw binding workaround is needed.

## Salesforce account and testability

An **API-enabled Developer Edition org or isolated sandbox** is the preferred test target. [Salesforce API access](https://developer.salesforce.com/docs/platform/api-rest/guide/intro-rest-compatible-editions.html) is included with Enterprise, Performance, Unlimited and Developer editions; Professional needs the API add-on. The connector specifically excludes trial accounts. A sandbox still needs its org entitlement and user permissions verified.

Manually authorize the provisioned `salesforce` connection for the approved org before live tests. The catalog exposes `BasicAuthentication` ("Login with Salesforce Account": interactive Salesforce OAuth, not Azure MI) and `EntraIDAuth` (Salesforce token-exchange SSO). For ordinary OAuth, choose the approved production login URI (`https://login.salesforce.com`) or sandbox URI (`https://test.salesforce.com`) and supported API version (connector default `v58.0`). Confirm the connection's environment before signing in. Custom Domain sign-in is not supported by the ordinary connector authentication path. SSO instead requires an administrator-configured Salesforce external client app for token exchange, its consumer key and Salesforce instance URL; an Azure login alone is insufficient. These samples do not configure SSO or change org administration.

The consenting user needs **API Enabled**, read access to the chosen object and fields, record visibility, and permission to authorize the connector under the org's OAuth policy. Creating/updating test records needs separate object write permissions and explicit target approval. No Salesforce CDC/Platform Event subscription permission is required for these two polling-backed operations. Review API quotas (connector: 900 calls/connection/minute), Salesforce session/IP restrictions and OAuth expiration in the connector reference; do not loosen org policies without administrator approval.

| Check | Can run without a Salesforce org? |
| --- | --- |
| Build both apps; deserialize synthetic SDK payloads; verify receipt privacy; compile Bicep; check hook safety | Yes |
| Local direct Webhook callback with synthetic JSON | Yes, with Core Tools v4 and Azurite; does not prove source delivery |
| Live record-created/modified delivery in either mode | No: requires approved Azure subscription/region and Salesforce org/object, authorized connection and enabled trigger configs |
| Native Salesforce CDC/Platform Events/outbound messages | Not implemented by these connector operations |

No accessible Salesforce org was established during implementation: no org was supplied, no `sf` CLI was installed, and no Salesforce environment configuration names were present. A read-only inventory of all 24 accessible Connector Namespaces in the current Azure subscription found no Salesforce connections; other subscriptions and browser sessions were not inspected. A signed-in Azure CLI account is not evidence of a Salesforce connection. No Azure deployment, Salesforce consent, record creation/update, or org administration was performed.

## Azure identity

Each standalone app has a system-assigned managed identity, used for Flex deployment storage, identity-based host storage and AAD-only Application Insights. Worker telemetry obtains its credential through DI `AzureComponentFactory` from the named `ConnectorNamespace` configuration: deployed `managedidentity` without client/resource selectors, standard developer fallback locally. The namespace retains its **own distinct** system identity. Post-app access policies and storage/monitoring roles use the actual app principal, independently of the namespace and Poll trigger modules. These Azure policies never replace Salesforce OAuth. The selected developer receives connection access and storage/monitoring roles for local development; its default principal type is `User`.

Use separate azd environments for the two modes. Commands in each quickstart provision resources or change trigger delivery; run them only after explicit Azure and Salesforce target approval. License: repository root [LICENSE](../LICENSE).

## Offline checks

From the repository root:

```powershell
dotnet run --project .\SalesforceApp\tests\SalesforceChecks.csproj
az bicep build --file .\SalesforceApp\polling\infra\main.bicep
az bicep build --file .\SalesforceApp\webhook\infra\main.bicep
```

PowerShell hooks require PowerShell 7.3+ (.NET 7+) for private callback staging with Unix file permissions. Bash hooks support Bash 3.2+ and require `jq` and standard shell utilities; webhook registration also requires `mktemp` and Azure CLI support for `az rest`. Hook checks use isolated test copies, real `jq` and mocked Azure commands, never live trigger registration. Bicep compiles the templates but the preview `Microsoft.Web/connectorGateways@2026-05-01-preview` types are not available to the local compiler; its BCP081 warnings mean provider properties still need live validation on an approved target.

Delivery contracts: [Poll configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md#poll-delivery), [polling-backed Webhook registration](https://github.com/Azure/azure-functions-connector-extension/blob/main/.github/skills/webhook-trigger-registration/SKILL.md), [SDK signature mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md#salesforce-connector).
