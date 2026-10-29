# Microsoft Dataverse connector samples (.NET)

Choose a standalone app; each folder has its own project, `azure.yaml`, infrastructure,
settings template, and deployment instructions.

| Sample | Delivery | Functions |
| --- | --- | --- |
| [Polling](polling/README.md) | The Functions host pulls and acknowledges events from Connector Namespace. No inbound callback or connector system key is needed. | New-row trigger and List rows HTTP action |
| [Webhook](webhook/README.md) | Connector Namespace pushes events to the Functions connector webhook. | New-row trigger and List rows HTTP action |

Both use `commondataservice` operation `GetOnNewItems_V2` for new rows and the typed
`CommondataserviceClient.GetItemsAsync` action for on-demand reads. Poll describes event
**delivery to Functions**, not a different Dataverse operation or a timer-triggered SDK call.
Triggers log row counts only; neither app writes payloads to Blob Storage. Storage remains
necessary for Functions host state and Flex Consumption deployment packages.

The existing new-row webhook path was previously validated end-to-end. The new Poll sample
follows the Office 365 Poll contract; deploying it and authorizing a Dataverse account is
required to verify service-side availability in your region. Neither sample enables the
broader `SubscribeWebhookTrigger` operation, whose trigger configuration is subject to the
service limitation documented in the webhook sample.
