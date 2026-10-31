// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Azure.Connectors.Sdk.Teams.Models;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;

namespace TeamsApp;

public class TeamsFunctions
{
    private readonly ILogger<TeamsFunctions> _logger;

    public TeamsFunctions(ILogger<TeamsFunctions> logger)
    {
        _logger = logger;
    }

    [Function("OnNewChannelMessage")]
    public void OnNewChannelMessage(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnNewChannelMessageTriggerConfigName%")]
        TeamsOnNewChannelMessageTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewChannelMessage trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnNewChannelMessageMentioningMe")]
    public void OnNewChannelMessageMentioningMe(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnNewChannelMessageMentioningMeTriggerConfigName%")]
        TeamsOnNewChannelMessageMentioningMeTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewChannelMessageMentioningMe trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnGroupMembershipAdd")]
    public void OnGroupMembershipAdd(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnGroupMembershipAddTriggerConfigName%")]
        TeamsOnTeamMemberAddedTriggerPayload payload)
    {
        _logger.LogInformation("Received OnGroupMembershipAdd trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnGroupMembershipRemoval")]
    public void OnGroupMembershipRemoval(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnGroupMembershipRemovalTriggerConfigName%")]
        TeamsOnTeamMemberRemovedTriggerPayload payload)
    {
        _logger.LogInformation("Received OnGroupMembershipRemoval trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }
}
