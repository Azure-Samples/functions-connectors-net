// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Azure.Connectors.Sdk.SharePointOnline.Models;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;

namespace SharePointApp;

public class SharePointFunctions
{
    private readonly ILogger<SharePointFunctions> _logger;

    public SharePointFunctions(ILogger<SharePointFunctions> logger)
    {
        _logger = logger;
    }

    [Function("OnNewFile")]
    public void OnNewFile(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnNewFileTriggerConfigName%")]
        SharePointOnlineOnNewFileItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewFile trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnUpdatedFile")]
    public void OnUpdatedFile(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnUpdatedFileTriggerConfigName%")]
        SharePointOnlineOnUpdatedFileItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnUpdatedFile trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnNewItem")]
    public void OnNewItem(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnNewItemTriggerConfigName%")]
        SharePointOnlineOnNewItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewItem trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnUpdatedItem")]
    public void OnUpdatedItem(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnUpdatedItemTriggerConfigName%")]
        SharePointOnlineOnUpdatedItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnUpdatedItem trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnChangedItem")]
    public void OnChangedItem(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnChangedItemTriggerConfigName%")]
        SharePointOnlineOnChangedItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnChangedItem trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnDeletedItem")]
    public void OnDeletedItem(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnDeletedItemTriggerConfigName%")]
        SharePointOnlineOnDeletedItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnDeletedItem trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnDeletedFile")]
    public void OnDeletedFile(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnDeletedFileTriggerConfigName%")]
        SharePointOnlineOnDeletedFileItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnDeletedFile trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnFormSubmitted")]
    public void OnFormSubmitted(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnFormSubmittedTriggerConfigName%")]
        SharePointOnlineOnNewItemsFromFormTriggerPayload payload)
    {
        _logger.LogInformation("Received OnFormSubmitted trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnFileClassified")]
    public void OnFileClassified(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnFileClassifiedTriggerConfigName%")]
        SharePointOnlineOnUpdatedFileClassifiedTimesTriggerPayload payload)
    {
        _logger.LogInformation("Received OnFileClassified trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnRecurringDigest")]
    public void OnRecurringDigest(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnRecurringDigestTriggerConfigName%")]
        SharePointOnlineOnRecurrenceDigestTriggerPayload payload)
    {
        _logger.LogInformation("Received OnRecurringDigest trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }
}
