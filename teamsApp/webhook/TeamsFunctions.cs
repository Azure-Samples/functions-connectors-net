// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;
using Azure.Connectors.Sdk.Teams.Models;

namespace TeamsApp;

/// <summary>
/// Microsoft Teams connector trigger functions.
/// Channel-message triggers use <see cref="TeamsOnNewChannelMessageTriggerPayload"/>;
/// membership triggers use <see cref="TeamsOnTeamMemberAddedTriggerPayload"/> / <see cref="TeamsOnTeamMemberRemovedTriggerPayload"/>.
/// </summary>
public class TeamsFunctions
{
    private readonly ILogger<TeamsFunctions> _logger;

    public TeamsFunctions(ILogger<TeamsFunctions> logger)
    {
        _logger = logger;
    }

    [Function("OnNewChannelMessage")]
    public void OnNewChannelMessage(
        [ConnectorTrigger] TeamsOnNewChannelMessageTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewChannelMessage trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnNewChannelMessageMentioningMe")]
    public void OnNewChannelMessageMentioningMe(
        [ConnectorTrigger] TeamsOnNewChannelMessageMentioningMeTriggerPayload payload)
    {
        _logger.LogInformation("Received OnNewChannelMessageMentioningMe trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnGroupMembershipAdd")]
    public void OnGroupMembershipAdd(
        [ConnectorTrigger] TeamsOnTeamMemberAddedTriggerPayload payload)
    {
        _logger.LogInformation("Received OnGroupMembershipAdd trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("OnGroupMembershipRemoval")]
    public void OnGroupMembershipRemoval(
        [ConnectorTrigger] TeamsOnTeamMemberRemovedTriggerPayload payload)
    {
        _logger.LogInformation("Received OnGroupMembershipRemoval trigger ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }
}
