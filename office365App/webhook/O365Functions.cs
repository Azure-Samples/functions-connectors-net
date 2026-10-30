// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;
using Azure.Connectors.Sdk.Office365.Models;

namespace Office365App;

/// <summary>
/// Office 365 Outlook connector webhook trigger functions.
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
    public void OnNewEmail(
        [ConnectorTrigger] Office365OnNewEmailTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewEmail trigger");
    }

    [Function("OnFlaggedEmail")]
    public void OnFlaggedEmail(
        [ConnectorTrigger] Office365OnFlaggedEmailTriggerPayload payload)
    {
        _logger.LogInformation("Received OnFlaggedEmail trigger");
    }

    [Function("OnNewMentionMeEmail")]
    public void OnNewMentionMeEmail(
        [ConnectorTrigger] Office365OnNewEmailMentioningMeTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewMentionMeEmail trigger");
    }

    [Function("OnNewCalendarEvent")]
    public void OnNewCalendarEvent(
        [ConnectorTrigger] Office365OnCalendarNewItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewCalendarEvent trigger");
    }

    [Function("OnUpcomingEvent")]
    public void OnUpcomingEvent(
        [ConnectorTrigger] Office365OnUpcomingEventsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnUpcomingEvent trigger");
    }

    [Function("OnSharedMailboxNewEmail")]
    public void OnSharedMailboxNewEmail(
        [ConnectorTrigger] Office365OnSharedMailboxNewEmailTriggerPayload payload)
    {
        _logger.LogInformation("Received OnSharedMailboxNewEmail trigger");
    }

    [Function("OnCalendarChangedItems")]
    public void OnCalendarChangedItems(
        [ConnectorTrigger] Office365OnCalendarChangedItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnCalendarChangedItems trigger");
    }

    [Function("OnCalendarUpdatedItems")]
    public void OnCalendarUpdatedItems(
        [ConnectorTrigger] Office365OnCalendarUpdatedItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnCalendarUpdatedItems trigger");
    }
}
