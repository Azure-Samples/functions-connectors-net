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

    [Function("OnNewFile")]
    [BlobOutput("connector-messages/{rand-guid}.json", Connection = "AzureWebJobsStorage")]
    public string OnNewFile(
        [ConnectorTrigger] OneDriveForBusinessOnNewFilesTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewFile trigger");
        return System.Text.Json.JsonSerializer.Serialize(payload);
    }

    [Function("OnUpdatedFile")]
    [BlobOutput("connector-messages/{rand-guid}.json", Connection = "AzureWebJobsStorage")]
    public string OnUpdatedFile(
        [ConnectorTrigger] OneDriveForBusinessOnUpdatedFilesTriggerPayload payload)
    {
        _logger.LogInformation("Received OnUpdatedFile trigger");
        return System.Text.Json.JsonSerializer.Serialize(payload);
    }
}
