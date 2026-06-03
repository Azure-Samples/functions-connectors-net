# Microsoft Teams Triggers (.NET)

Fires Azure Functions on Teams channel messages and group membership changes.

| Function | Trigger operation |
| --- | --- |
| `OnNewChannelMessage` | `OnNewChannelMessage` |
| `OnNewChannelMessageMentioningMe` | `OnNewChannelMessageMentioningMe` |
| `OnGroupMembershipAdd` | `OnGroupMembershipAdd` |
| `OnGroupMembershipRemoval` | `OnGroupMembershipRemoval` |

## Prerequisites

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli)
- [.NET 10 SDK](https://dotnet.microsoft.com/download)

## Quickstart

```bash
cd teamsApp
azd auth login
az login
azd up
```

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
