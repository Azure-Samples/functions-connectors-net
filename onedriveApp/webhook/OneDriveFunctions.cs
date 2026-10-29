// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;
using Azure.Connectors.Sdk.OneDriveForBusiness.Models;

namespace OneDriveApp;

public class OneDriveFunctions
{
    private readonly ILogger<OneDriveFunctions> _logger;

    public OneDriveFunctions(ILogger<OneDriveFunctions> logger)
    {
        _logger = logger;
    }

    [Function("OnNewFileContent")]
    public void OnNewFileContent([ConnectorTrigger] string payload)
    {
        _logger.LogInformation("Received OnNewFileContent trigger");
    }

    [Function("OnUpdatedFileContent")]
    public void OnUpdatedFileContent([ConnectorTrigger] string payload)
    {
        _logger.LogInformation("Received OnUpdatedFileContent trigger");
    }

    [Function("OnNewFile")]
    public void OnNewFile(
        [ConnectorTrigger] OneDriveForBusinessOnNewFilesTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewFile trigger");
    }

    [Function("OnUpdatedFile")]
    public void OnUpdatedFile(
        [ConnectorTrigger] OneDriveForBusinessOnUpdatedFilesTriggerPayload payload)
    {
        _logger.LogInformation("Received OnUpdatedFile trigger");
    }
}
