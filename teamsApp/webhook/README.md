# Microsoft Teams Webhook Triggers (.NET)

This standalone sample preserves the four Teams trigger operations:
`OnNewChannelMessage`, `OnNewChannelMessageMentioningMe`,
`OnGroupMembershipAdd`, and `OnGroupMembershipRemoval`. Each receives a typed
Teams payload and logs only the trigger name and message/member count.
Payloads are not written to Blob Storage or application logs.

Webhook is the default when `DeliveryMode` is omitted from `[ConnectorTrigger]`.
The Connector Namespace delivers callbacks to
`https://<function-host>/runtime/webhooks/connector?functionName=<function-name>`
using the connector extension system key in the `code` query parameter.
The namespace identity has connection access to detect Teams changes;
webhook-only reception needs no Function/developer connection access policy.
For outbound-only local development, use the separate Poll sample.

## Prerequisites

- .NET 10 SDK.
- Azure Developer CLI (`azd`), Azure CLI (`az`) 2.75.0 or later, and PowerShell 7.
- A Teams account and permission to authorize the Teams connector.
- [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli):

  ```powershell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

The included `NuGet.config` provides the public Azure Functions package feed.
Copy this entire folder to use it independently of the sample collection.

## Deploy

Run from this folder (`teamsApp\webhook` in the sample collection):

```powershell
az login
azd auth login
azd env new teams-webhook
azd env set TEAMS_GROUP_ID "<team / Microsoft 365 group object ID>"
azd env set TEAMS_CHANNEL_ID "<channel ID>"
azd up
```

Use the identifiers from a Teams channel link (`groupId` and URL-decoded channel
ID), or Microsoft Graph. Message triggers require both IDs; membership triggers
require only the group ID. If unset, the post-deploy hook offers interactive
team/channel selection via Microsoft Graph with the permissions of your CLI
identity. Set them explicitly for noninteractive runs.
The Connector Namespace defaults to `westcentralus`; change it via
`CONNECTOR_NAMESPACE_LOCATION` if needed.

Deployment includes a Flex Consumption .NET 10 Function App, managed identity,
Functions host/deployment storage, Application Insights/Log Analytics, Connector
Namespace, and Teams OAuth connection. The post-deploy hook registers four
callback trigger configurations and opens connection consent. Re-run using
`azd hooks run postdeploy`.

There is no application output container or Blob binding. The storage account
and its identity roles are retained for Functions host state and deployment.
Existing `connector-messages` blobs from an earlier deployment are not deleted;
remove those separately if appropriate.

## Local development

Prefer the Poll sample when a public endpoint is unavailable. Webhook delivery
requires Azure Functions Core Tools v4, Azurite, and a public HTTPS tunnel to the
local host. Copy `local.settings.example.json` to ignored `local.settings.json`,
start Azurite, then run `dotnet build` and `func start`.

Register separate webhook trigger configurations on an authorized Teams connection
using your tunnel callback URL, matching function names, and the local host's
connector extension system key. The deployment hook targets the **deployed**
Function App, not a local tunnel. Never expose an unauthenticated callback or
commit function keys/local settings.
See [webhook registration](https://github.com/Azure/azure-functions-connector-extension/blob/main/.github/skills/webhook-trigger-registration/SKILL.md).

## Verify and clean up

Confirm the Teams connection is `Connected` and all four trigger configs are
enabled in the [Connector Namespaces portal](https://connectors.azure.com/).
Post a new root channel message (not a reply), mention the authorized account,
and add/remove a test member with the appropriate permissions. Check local
function logs or Application Insights for the corresponding trigger name/count.
Allow for upstream detection delays; retries can produce duplicate logs.

Run `azd down --purge` from this folder when finished. Do not reuse the polling
environment. To continue an existing pre-split Teams deployment, preserve its azd
environment values under this folder and retain the same environment name.

See [Teams connector operations and limitations](https://learn.microsoft.com/connectors/teams/)
and [connector delivery configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md).
