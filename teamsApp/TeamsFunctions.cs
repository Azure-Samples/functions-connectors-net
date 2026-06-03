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
    [BlobOutput("connector-messages/{rand-guid}.json", Connection = "AzureWebJobsStorage")]
    public string OnNewChannelMessage(
        [ConnectorTrigger] TeamsOnNewChannelMessageTriggerPayload payload)
    {
        var count = payload.Body?.Value?.Count ?? 0;
        _logger.LogInformation("Received OnNewChannelMessage trigger ({Count} messages)", count);
        return System.Text.Json.JsonSerializer.Serialize(payload);
    }

    [Function("OnNewChannelMessageMentioningMe")]
    [BlobOutput("connector-messages/{rand-guid}.json", Connection = "AzureWebJobsStorage")]
    public string OnNewChannelMessageMentioningMe(
        [ConnectorTrigger] TeamsOnNewChannelMessageMentioningMeTriggerPayload payload)
    {
        var count = payload.Body?.Value?.Count ?? 0;
        _logger.LogInformation("Received OnNewChannelMessageMentioningMe trigger ({Count} messages)", count);
        return System.Text.Json.JsonSerializer.Serialize(payload);
    }

    [Function("OnGroupMembershipAdd")]
    [BlobOutput("connector-messages/{rand-guid}.json", Connection = "AzureWebJobsStorage")]
    public string OnGroupMembershipAdd(
        [ConnectorTrigger] TeamsOnTeamMemberAddedTriggerPayload payload)
    {
        var count = payload.Body?.Value?.Count ?? 0;
        _logger.LogInformation("Received OnGroupMembershipAdd trigger ({Count} members)", count);
        return System.Text.Json.JsonSerializer.Serialize(payload);
    }

    [Function("OnGroupMembershipRemoval")]
    [BlobOutput("connector-messages/{rand-guid}.json", Connection = "AzureWebJobsStorage")]
    public string OnGroupMembershipRemoval(
        [ConnectorTrigger] TeamsOnTeamMemberRemovedTriggerPayload payload)
    {
        var count = payload.Body?.Value?.Count ?? 0;
        _logger.LogInformation("Received OnGroupMembershipRemoval trigger ({Count} members)", count);
        return System.Text.Json.JsonSerializer.Serialize(payload);
    }
}
