// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Azure.Connectors.Sdk.Office365.Models;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;

namespace Office365App;

public class O365Functions
{
    private readonly ILogger<O365Functions> _logger;

    public O365Functions(ILogger<O365Functions> logger)
    {
        _logger = logger;
    }

    [Function("OnNewEmail")]
    public void OnNewEmail(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnNewEmailTriggerConfigName%")]
        Office365OnNewEmailTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewEmail trigger");
    }

    [Function("OnFlaggedEmail")]
    public void OnFlaggedEmail(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnFlaggedEmailTriggerConfigName%")]
        Office365OnFlaggedEmailTriggerPayload payload)
    {
        _logger.LogInformation("Received OnFlaggedEmail trigger");
    }

    [Function("OnNewMentionMeEmail")]
    public void OnNewMentionMeEmail(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnNewMentionMeEmailTriggerConfigName%")]
        Office365OnNewEmailMentioningMeTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewMentionMeEmail trigger");
    }

    [Function("OnNewCalendarEvent")]
    public void OnNewCalendarEvent(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnNewCalendarEventTriggerConfigName%")]
        Office365OnCalendarNewItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewCalendarEvent trigger");
    }

    [Function("OnUpcomingEvent")]
    public void OnUpcomingEvent(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnUpcomingEventTriggerConfigName%")]
        Office365OnUpcomingEventsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnUpcomingEvent trigger");
    }

    [Function("OnSharedMailboxNewEmail")]
    public void OnSharedMailboxNewEmail(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnSharedMailboxNewEmailTriggerConfigName%")]
        Office365OnSharedMailboxNewEmailTriggerPayload payload)
    {
        _logger.LogInformation("Received OnSharedMailboxNewEmail trigger");
    }

    [Function("OnCalendarChangedItems")]
    public void OnCalendarChangedItems(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnCalendarChangedItemsTriggerConfigName%")]
        Office365OnCalendarChangedItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnCalendarChangedItems trigger");
    }

    [Function("OnCalendarUpdatedItems")]
    public void OnCalendarUpdatedItems(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnCalendarUpdatedItemsTriggerConfigName%")]
        Office365OnCalendarUpdatedItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnCalendarUpdatedItems trigger");
    }
}
