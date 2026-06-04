// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;
using Azure.Connectors.Sdk.AzureBlob.Models;

namespace AzureBlobApp;

public class BlobFunctions
{
    private readonly ILogger<BlobFunctions> _logger;

    public BlobFunctions(ILogger<BlobFunctions> logger)
    {
        _logger = logger;
    }

    [Function("OnUpdatedFile")]
    [BlobOutput("connector-messages/{rand-guid}.json", Connection = "AzureWebJobsStorage")]
    public string OnUpdatedFile(
        [ConnectorTrigger] AzureBlobOnUpdatedFilesTriggerPayload payload)
    {
        _logger.LogInformation("Received OnUpdatedFile trigger");
        return System.Text.Json.JsonSerializer.Serialize(payload);
    }
}
