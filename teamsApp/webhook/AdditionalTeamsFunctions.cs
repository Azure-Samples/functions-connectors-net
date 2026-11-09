// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;

namespace TeamsApp;

public class AdditionalTeamsFunctions
{
    private readonly ILogger<AdditionalTeamsFunctions> _logger;

    public AdditionalTeamsFunctions(ILogger<AdditionalTeamsFunctions> logger)
    {
        _logger = logger;
    }

    [Function("WebhookChatMessageTrigger")]
    public void OnNewChatMessage([ConnectorTrigger] string payload)
    {
        _logger.LogInformation("Received WebhookChatMessageTrigger event");
    }

    [Function("WebhookNewMessageTrigger")]
    public void OnNewChatOrChannelMessage([ConnectorTrigger] string payload)
    {
        _logger.LogInformation("Received WebhookNewMessageTrigger event");
    }

    [Function("WebhookAtMentionTrigger")]
    public void OnMention([ConnectorTrigger] string payload)
    {
        _logger.LogInformation("Received WebhookAtMentionTrigger event");
    }

    [Function("WebhookKeywordTrigger")]
    public void OnKeywords([ConnectorTrigger] string payload)
    {
        _logger.LogInformation("Received WebhookKeywordTrigger event");
    }

    [Function("WebhookMessageReactionTrigger")]
    public void OnReaction([ConnectorTrigger] string payload)
    {
        _logger.LogInformation("Received WebhookMessageReactionTrigger event");
    }

    [Function("RecordingTrigger")]
    public void OnRecordingAvailable([ConnectorTrigger] string payload)
    {
        _logger.LogInformation("Received RecordingTrigger event");
    }

    [Function("TranscriptTrigger")]
    public void OnTranscriptAvailable([ConnectorTrigger] string payload)
    {
        _logger.LogInformation("Received TranscriptTrigger event");
    }
}
