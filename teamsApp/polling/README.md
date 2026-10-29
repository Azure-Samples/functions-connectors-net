# Microsoft Teams Polling Triggers (.NET)

This standalone sample uses `ConnectorTriggerDeliveryMode.Poll` for all four
Teams triggers. The Function host connects outbound to an Azure Connector
Namespace to receive and acknowledge events. No public callback, function system
key, or development tunnel is required. Each function receives a typed Teams
payload and logs only the trigger name and message/member count, not message
content or member identities. There is no Blob output.

| Function / Teams operation | Required parameters |
| --- | --- |
| `OnNewChannelMessage` | `groupId`, `channelId` |
| `OnNewChannelMessageMentioningMe` | `groupId`, `channelId` |
| `OnGroupMembershipAdd` | `groupId` |
| `OnGroupMembershipRemoval` | `groupId` |

These are the existing Teams connector operations, not the separate `Webhook*`
operations. Poll describes event delivery from the namespace to Functions,
independently of how the connector detects changes in Teams. A payload may contain
multiple messages/members; Functions invocation batching is not enabled.
Delivery is at least once, so duplicate log entries are possible; production
processing should be idempotent.

## Prerequisites

- .NET 10 SDK and Azure Functions Core Tools v4.
- Azure Developer CLI (`azd`), Azure CLI (`az`) 2.75.0 or later, and PowerShell 7.
- Azurite for local Functions host storage (not application output).
- A Teams account with access to the team/channel and permission to authorize
  the connector connection. Membership verification requires permission to
  add/remove a test member.
- The [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli):

  ```powershell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

`NuGet.config` supplies the public Azure Functions package feed. Connector worker
extension 1.0.0 supports Poll delivery; no local extension checkout is required.

## Deploy to Azure

Run from this folder (`teamsApp\polling` in the sample collection):

```powershell
az login
azd auth login
azd env new teams-polling
azd env set TEAMS_GROUP_ID "<team / Microsoft 365 group object ID>"
azd env set TEAMS_CHANNEL_ID "<channel ID>"
azd up
```

Set both identifiers **before provisioning**. In Teams, copy a channel link and
use its `groupId` and URL-decoded channel ID. Alternatively retrieve IDs using
Microsoft Graph with the appropriate permissions. Trigger parameters are defined
in `infra\poll-triggers.bicep`; do not use team/channel display names as IDs.

The Connector Namespace defaults to `westcentralus`; override it with
`azd env set CONNECTOR_NAMESPACE_LOCATION "<supported-region>"`.
Use an environment name different from any webhook deployment.

Bicep provisions a resource group, .NET 10 Flex Consumption Function App,
managed identity, host/deployment storage, Application Insights/Log Analytics,
Connector Namespace, Teams OAuth connection, and four enabled Poll trigger
configurations without webhook notification details. Separate connection access
policies authorize the namespace, Function App, and provisioning developer.

The post-deploy hook opens OAuth consent and creates ignored `local.settings.json`
from deployment outputs if it does not exist. Re-run using
`azd hooks run postdeploy`. Existing local settings are preserved.

## Run locally

There is no local Teams/Connector Namespace emulator. Use real Azure resources
and Azurite for Functions host storage. To provision without a competing deployed
listener, use the login, environment, and team/channel commands above, then:

```powershell
azd provision
pwsh -File .\infra\scripts\postdeploy.ps1
```

To deliberately regenerate existing local settings:

```powershell
pwsh -File .\infra\scripts\postdeploy.ps1 -ForceLocalSettings
```

Start Azurite separately, then:

```powershell
dotnet build
func start
```

Local listeners use the signed-in developer credentials. Do not copy Azure's
`ConnectorNamespace__credential=managedidentity` or `__clientId` into local
settings. If a different developer runs locally, grant that identity its own
connection-level access policy. Local and deployed listeners sharing a trigger
configuration compete for events; use separate environments for isolated tests.

### Existing namespace

Copy `local.settings.example.json` to ignored `local.settings.json` and fill in the
endpoint and all four trigger-config names for existing enabled Poll configurations
on an authorized Teams connection. `Connection = "ConnectorNamespace"` in the
binding is the settings prefix, not the Teams connection resource name.
Grant both namespace and developer identities connection access.

Derive `ConnectorNamespace__pollingEndpoint` from service-generated
`pollingEndpoints.receiveUri`:

| Receive URI | Setting |
| --- | --- |
| `https://<host>/api/triggerconfigs/<name>/receive` | `https://<host>` |
| `https://<host>/api/connectorGateways/<id>/triggerconfigs/<name>/receive` | `https://<host>/api/connectorGateways/<id>` |

Exclude operation paths and query strings. Never commit real endpoints,
credentials, or `local.settings.json`.

## Verify and clean up

After consent, post a new root message in the configured channel (replies do not
fire `OnNewChannelMessage`), mention the authorized user in a message, and add or
remove a test team member. Allow for the connector's upstream detection interval.
Inspect local function logs or Application Insights for the corresponding
function name and count. There is no output container to inspect.

Run `azd down --purge` from this folder when finished.

## References

- [Teams connector operations and limitations](https://learn.microsoft.com/connectors/teams/)
- [Connector trigger configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md)
- [Connector Poll samples](https://github.com/Azure/azure-functions-connector-extension/tree/main/test/poll)
