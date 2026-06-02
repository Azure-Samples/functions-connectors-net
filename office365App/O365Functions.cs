// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;
using Azure.Connectors.Sdk.Office365.Models;

namespace Office365App;

/// <summary>
/// Sample Azure Function using the Connector trigger extension.
/// Receives trigger callbacks from Connector Namespace managed connectors.
/// </summary>
public class O365Functions
{
    private readonly ILogger<O365Functions> _logger;

    public O365Functions(ILogger<O365Functions> logger)
    {
        _logger = logger;
    }

    /// <summary>
    /// Receives Office 365 email trigger callbacks and saves to blob storage.
    /// </summary>
    [Function("OnNewEmail")]
    [BlobOutput("connector-messages/{rand-guid}.json", Connection = "AzureWebJobsStorage")]
    public string OnNewEmail(
        [ConnectorTrigger]
        Office365OnNewEmailTriggerPayload payload)
    {
        _logger.LogInformation("Received connector trigger payload");

        return System.Text.Json.JsonSerializer.Serialize(payload);
    }
}
