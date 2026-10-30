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
    public void OnNewChatMessage(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%WebhookChatMessageTriggerTriggerConfigName%")]
        string payload)
    {
        _logger.LogInformation("Received WebhookChatMessageTrigger event");
    }

    [Function("WebhookNewMessageTrigger")]
    public void OnNewChatOrChannelMessage(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%WebhookNewMessageTriggerTriggerConfigName%")]
        string payload)
    {
        _logger.LogInformation("Received WebhookNewMessageTrigger event");
    }

    [Function("WebhookAtMentionTrigger")]
    public void OnMention(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%WebhookAtMentionTriggerTriggerConfigName%")]
        string payload)
    {
        _logger.LogInformation("Received WebhookAtMentionTrigger event");
    }

    [Function("WebhookKeywordTrigger")]
    public void OnKeywords(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%WebhookKeywordTriggerTriggerConfigName%")]
        string payload)
    {
        _logger.LogInformation("Received WebhookKeywordTrigger event");
    }

    [Function("WebhookMessageReactionTrigger")]
    public void OnReaction(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%WebhookMessageReactionTriggerTriggerConfigName%")]
        string payload)
    {
        _logger.LogInformation("Received WebhookMessageReactionTrigger event");
    }

    [Function("RecordingTrigger")]
    public void OnRecordingAvailable(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%RecordingTriggerTriggerConfigName%")]
        string payload)
    {
        _logger.LogInformation("Received RecordingTrigger event");
    }

    [Function("TranscriptTrigger")]
    public void OnTranscriptAvailable(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%TranscriptTriggerTriggerConfigName%")]
        string payload)
    {
        _logger.LogInformation("Received TranscriptTrigger event");
    }
}
