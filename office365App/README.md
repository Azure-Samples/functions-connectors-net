# Office 365 Outlook Connector Samples (.NET)

Choose how the Connector Namespace delivers events to Azure Functions:

| Sample | Delivery | Local development |
| --- | --- | --- |
| [Polling](polling/) | Functions polls the Connector Namespace | Outbound only; no tunnel |
| [Webhook](webhook/) | Namespace calls the HTTPS callback | Public HTTPS tunnel |

Samples for Office 365 email and calendar triggers. See each sample's README for setup and supported triggers.

[License](../LICENSE).

## Troubleshooting

### Deployment fails with `BlobUploadFailedException` and storage HTTP 403

During `azd up`, the `deploy-function-app` step may fail while publishing the ZIP file with an error like:

```text
BlobUploadFailedException: Failed to upload blob to storage account:
Response status code does not indicate success: 403
(This request is not authorized to perform this operation using this permission.).
```

This is likely caused by newly assigned storage permissions still propagating. Wait a few minutes, then redeploy from the same sample directory and azd environment:

```bash
azd deploy
```

If the error persists, check the Function App's managed identity permissions on its deployment storage account rather than continuing to retry.
