# SharePoint Online Polling Triggers (.NET)

Azure Functions sample using [Azure.Connectors.Sdk](https://www.nuget.org/packages/Azure.Connectors.Sdk)
and the [Connector extension](https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Extensions.Connector)
with `DeliveryMode = Poll`. The host receives events outbound from the Connector
Namespace; no public callback or tunnel is required. All handlers use typed
payloads and log only the trigger name and item count

| Function | Connector operation | Description |
| --- | --- | --- |
| `OnNewFile` | [`GetOnNewFileItems`](https://learn.microsoft.com/connectors/sharepointonline/#when-a-file-is-created-(properties-only)) | File created (properties only) |
| `OnUpdatedFile` | [`GetOnUpdatedFileItems`](https://learn.microsoft.com/connectors/sharepointonline/#when-a-file-is-created-or-modified-(properties-only)) | File created or modified (properties only) |
| `OnNewItem` | [`GetOnNewItems`](https://learn.microsoft.com/connectors/sharepointonline/#when-an-item-is-created) | Item created |
| `OnUpdatedItem` | [`GetOnUpdatedItems`](https://learn.microsoft.com/connectors/sharepointonline/#when-an-item-is-created-or-modified) | Item created or modified |
| `OnChangedItem` | [`GetOnChangedItems`](https://learn.microsoft.com/connectors/sharepointonline/#when-an-item-or-a-file-is-modified) | Item or file modified, not created |
| `OnDeletedItem` | [`GetOnDeletedItems`](https://learn.microsoft.com/connectors/sharepointonline/#when-an-item-is-deleted) | Item deleted (opt-in) |
| `OnDeletedFile` | [`GetOnDeletedFileItems`](https://learn.microsoft.com/connectors/sharepointonline/#when-a-file-is-deleted) | File deleted (opt-in) |
| `OnFormSubmitted` | [`GetOnNewItemsFromForm`](https://learn.microsoft.com/connectors/sharepointonline/#when-a-form-is-submitted-(preview)) | Form submitted (preview, opt-in) |
| `OnFileClassified` | [`GetOnUpdatedFileClassifiedTimes`](https://learn.microsoft.com/connectors/sharepointonline/#when-a-file-is-classified-by-a-microsoft-syntex-model) | Microsoft Syntex classification (opt-in) |
| `OnRecurringDigest` | [`GetOnRecurrenceDigest`](https://learn.microsoft.com/connectors/sharepointonline/#recurring-digest-of-updates-(preview)) | Recurring digest (preview, opt-in) |

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later
- PowerShell 7 for the default hook, or Bash and `jq` for the alternative script
- A SharePoint site and library, and permission to authorize the connection
- [`connector-namespace` CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli):

  ```bash
  curl -fsSL https://aka.ms/connector-namespace-cli-install | sh
  ```

  Or in PowerShell:

  ```powershell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

## Deploy to Azure

```bash
cd sharepointApp/polling
az login
azd auth login
azd env new sharepoint-polling
azd env set SHAREPOINT_SITE_URL https://contoso.sharepoint.com/sites/mysite
azd up
```

`SHAREPOINT_LIBRARY_NAME` defaults to `Documents` (name or GUID).
`SHAREPOINT_FOLDER_PATH` optionally filters file/digest triggers.
Item/form triggers use `SHAREPOINT_LIST_NAME`, or the library if unset, and monitor
the whole list without the folder filter.

Deployment provisions a Flex Consumption app, managed identity, runtime/deployment
storage, monitoring, Connector Namespace, connection, and selected Poll triggers.
The hook opens OAuth consent and creates ignored local settings. Rerun with
`azd hooks run postdeploy`. Consent returns to https://connectors.azure.com.

The Bash equivalent is `bash ./infra/scripts/postdeploy.sh`; to use it as the
`azd` hook, set `shell: sh` and `run: ./infra/scripts/postdeploy.sh` in `azure.yaml`.
Existing local settings are preserved; use `--force-local-settings` in Bash or
`-ForceLocalSettings` in PowerShell to regenerate them.

Polling provisions **one always-ready 2,048-MB instance per enabled function**
(five by default), incurring idle charges. Local listeners using the same trigger
configurations compete with deployed listeners; use a separate environment.

## Optional triggers

Five create/update triggers are enabled by default. Set these before `azd up`:

| Setting | Enables / prerequisite |
| --- | --- |
| `SHAREPOINT_ENABLE_DELETION_TRIGGERS=true` | Item/file deletion; connection user must be a site collection administrator |
| `SHAREPOINT_ENABLE_SYNTEX_TRIGGER=true` | Classification; licensed Syntex model applied to the library |
| `SHAREPOINT_FORM_ID=<form-id>` | Form submissions; existing supported form on the configured list/library |
| `SHAREPOINT_DIGEST_SCHEDULE=*` | Digest including new/updated files; `*` is daily, or use `0` through `6` for a day of the week |

To disable them, reset flags to `false` or clear the form ID/schedule and rerun
`azd up`. Functions, existing trigger configurations, and polling instances follow
that selection. Regenerate local settings to apply it locally.

## Verify

Check the connection is **Connected** and selected triggers are **Enabled** in
[Connector Namespaces](https://connectors.azure.com/). Create then modify a file
or item and look for `Received <FunctionName> trigger` in function logs. Allow time
for source polling; delivery is at least once. Optional triggers require their
corresponding source action and prerequisites.

Run `azd down --purge` from this folder to clean up.

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [SharePoint Online connector reference](https://learn.microsoft.com/connectors/sharepointonline/)
