// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;
using Azure.Connectors.Sdk.Office365.Models;

namespace Office365App;

/// <summary>
/// Office 365 Outlook connector trigger functions.
/// Each function receives a different event type from the Connector Namespace.
/// </summary>
public class O365Functions
{
    private readonly ILogger<O365Functions> _logger;

    public O365Functions(ILogger<O365Functions> logger)
    {
        _logger = logger;
    }

    [Function("OnNewEmail")]
    [BlobOutput("connector-messages/{rand-guid}.json", Connection = "AzureWebJobsStorage")]
    public string OnNewEmail(
        [ConnectorTrigger] Office365OnNewEmailTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewEmail trigger");
        return System.Text.Json.JsonSerializer.Serialize(payload);
    }

    [Function("OnFlaggedEmail")]
    [BlobOutput("connector-messages/{rand-guid}.json", Connection = "AzureWebJobsStorage")]
    public string OnFlaggedEmail(
        [ConnectorTrigger] Office365OnFlaggedEmailTriggerPayload payload)
    {
        _logger.LogInformation("Received OnFlaggedEmail trigger");
        return System.Text.Json.JsonSerializer.Serialize(payload);
    }

    [Function("OnNewMentionMeEmail")]
    [BlobOutput("connector-messages/{rand-guid}.json", Connection = "AzureWebJobsStorage")]
    public string OnNewMentionMeEmail(
        [ConnectorTrigger] Office365OnNewEmailMentioningMeTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewMentionMeEmail trigger");
        return System.Text.Json.JsonSerializer.Serialize(payload);
    }

    [Function("OnNewCalendarEvent")]
    [BlobOutput("connector-messages/{rand-guid}.json", Connection = "AzureWebJobsStorage")]
    public string OnNewCalendarEvent(
        [ConnectorTrigger] Office365OnCalendarNewItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewCalendarEvent trigger");
        return System.Text.Json.JsonSerializer.Serialize(payload);
    }

    [Function("OnUpcomingEvent")]
    [BlobOutput("connector-messages/{rand-guid}.json", Connection = "AzureWebJobsStorage")]
    public string OnUpcomingEvent(
        [ConnectorTrigger] Office365OnUpcomingEventsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnUpcomingEvent trigger");
        return System.Text.Json.JsonSerializer.Serialize(payload);
    }
}
