// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;
using Azure.Connectors.Sdk.Teams.Models;

namespace TeamsApp;

public class AdditionalTeamsFunctions
{
    private readonly ILogger<AdditionalTeamsFunctions> _logger;

    public AdditionalTeamsFunctions(ILogger<AdditionalTeamsFunctions> logger)
    {
        _logger = logger;
    }

    [Function("WebhookChatMessageTrigger")]
    public void OnNewChatMessage(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%WebhookChatMessageTriggerTriggerConfigName%")]
        TeamsOnWebhookChatMessageTriggerPayload payload)
    {
        _logger.LogInformation("Received WebhookChatMessageTrigger event ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("WebhookNewMessageTrigger")]
    public void OnNewChatOrChannelMessage(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%WebhookNewMessageTriggerTriggerConfigName%")]
        TeamsOnWebhookNewMessageTriggerPayload payload)
    {
        _logger.LogInformation("Received WebhookNewMessageTrigger event ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("WebhookAtMentionTrigger")]
    public void OnMention(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%WebhookAtMentionTriggerTriggerConfigName%")]
        TeamsOnWebhookAtMentionTriggerPayload payload)
    {
        _logger.LogInformation("Received WebhookAtMentionTrigger event ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("WebhookKeywordTrigger")]
    public void OnKeywords(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%WebhookKeywordTriggerTriggerConfigName%")]
        TeamsOnWebhookKeywordTriggerPayload payload)
    {
        _logger.LogInformation("Received WebhookKeywordTrigger event ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("WebhookMessageReactionTrigger")]
    public void OnReaction(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%WebhookMessageReactionTriggerTriggerConfigName%")]
        TeamsOnWebhookMessageReactionTriggerPayload payload)
    {
        _logger.LogInformation("Received WebhookMessageReactionTrigger event ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("RecordingTrigger")]
    public void OnRecordingAvailable(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%RecordingTriggerTriggerConfigName%")]
        TeamsOnRecordingTriggerPayload payload)
    {
        _logger.LogInformation("Received RecordingTrigger event ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }

    [Function("TranscriptTrigger")]
    public void OnTranscriptAvailable(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%TranscriptTriggerTriggerConfigName%")]
        TeamsOnTranscriptTriggerPayload payload)
    {
        _logger.LogInformation("Received TranscriptTrigger event ({Count} items)", payload.Body?.Value?.Count ?? 0);
    }
}
