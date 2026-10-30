// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;
using Azure.Connectors.Sdk.SharePointOnline.Models;

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
        [ConnectorTrigger] SharePointOnlineOnNewFileItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewFile trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnUpdatedFile")]
    public void OnUpdatedFile(
        [ConnectorTrigger] SharePointOnlineOnUpdatedFileItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnUpdatedFile trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnNewItem")]
    public void OnNewItem(
        [ConnectorTrigger] SharePointOnlineOnNewItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewItem trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnUpdatedItem")]
    public void OnUpdatedItem(
        [ConnectorTrigger] SharePointOnlineOnUpdatedItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnUpdatedItem trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnChangedItem")]
    public void OnChangedItem(
        [ConnectorTrigger] SharePointOnlineOnChangedItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnChangedItem trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnDeletedItem")]
    public void OnDeletedItem(
        [ConnectorTrigger] SharePointOnlineOnDeletedItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnDeletedItem trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnDeletedFile")]
    public void OnDeletedFile(
        [ConnectorTrigger] SharePointOnlineOnDeletedFileItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnDeletedFile trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnFormSubmitted")]
    public void OnFormSubmitted(
        [ConnectorTrigger] SharePointOnlineOnNewItemsFromFormTriggerPayload payload)
    {
        _logger.LogInformation("Received OnFormSubmitted trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnFileClassified")]
    public void OnFileClassified(
        [ConnectorTrigger] SharePointOnlineOnUpdatedFileClassifiedTimesTriggerPayload payload)
    {
        _logger.LogInformation("Received OnFileClassified trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnRecurringDigest")]
    public void OnRecurringDigest(
        [ConnectorTrigger] SharePointOnlineOnRecurrenceDigestTriggerPayload payload)
    {
        _logger.LogInformation("Received OnRecurringDigest trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }
}
