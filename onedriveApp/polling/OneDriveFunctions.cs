// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Azure.Connectors.Sdk.OneDriveForBusiness.Models;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;

namespace OneDriveApp;

public class OneDriveFunctions
{
    private readonly ILogger<OneDriveFunctions> _logger;

    public OneDriveFunctions(ILogger<OneDriveFunctions> logger)
    {
        _logger = logger;
    }

    [Function("OnNewFileContent")]
    public void OnNewFileContent(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnNewFileContentTriggerConfigName%")]
        string payload)
    {
        _logger.LogInformation("Received OnNewFileContent trigger");
    }

    [Function("OnUpdatedFileContent")]
    public void OnUpdatedFileContent(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnUpdatedFileContentTriggerConfigName%")]
        string payload)
    {
        _logger.LogInformation("Received OnUpdatedFileContent trigger");
    }

    [Function("OnNewFile")]
    public void OnNewFile(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnNewFileTriggerConfigName%")]
        OneDriveForBusinessOnNewFilesTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewFile trigger ({Count} items)", payload?.Body?.Value?.Count ?? 0);
    }

    [Function("OnUpdatedFile")]
    public void OnUpdatedFile(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnUpdatedFileTriggerConfigName%")]
        OneDriveForBusinessOnUpdatedFilesTriggerPayload payload)
    {
        _logger.LogInformation("Received OnUpdatedFile trigger ({Count} items)", payload?.Body?.Value?.Count ?? 0);
    }
}
