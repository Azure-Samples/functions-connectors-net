using Azure.Connectors.Sdk.VisualStudioTeamServices.Models;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;

namespace AzureDevOpsApp;

public class AzureDevOpsFunctions(ILogger<AzureDevOpsFunctions> logger)
{
    [Function("OnBuildCompleted")]
    public void OnBuildCompleted(
        [ConnectorTrigger(DeliveryMode = ConnectorTriggerDeliveryMode.Poll, Connection = "ConnectorNamespace", TriggerConfigName = "%OnBuildCompletedTriggerConfigName%")]
        VisualStudioTeamServicesOnBuildCompletedTriggerPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload.Body?.Value);
        logger.LogInformation("Received OnBuildCompleted trigger ({Count} items)", payload.Body.Value.Count);
    }

    [Function("OnGitPullClosed")]
    public void OnGitPullClosed(
        [ConnectorTrigger(DeliveryMode = ConnectorTriggerDeliveryMode.Poll, Connection = "ConnectorNamespace", TriggerConfigName = "%OnGitPullClosedTriggerConfigName%")]
        VisualStudioTeamServicesOnGitPullClosedTriggerPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload.Body?.Value);
        logger.LogInformation("Received OnGitPullClosed trigger ({Count} items)", payload.Body.Value.Count);
    }

    [Function("OnGitPullCreated")]
    public void OnGitPullCreated(
        [ConnectorTrigger(DeliveryMode = ConnectorTriggerDeliveryMode.Poll, Connection = "ConnectorNamespace", TriggerConfigName = "%OnGitPullCreatedTriggerConfigName%")]
        VisualStudioTeamServicesOnGitPullCreatedTriggerPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload.Body?.Value);
        logger.LogInformation("Received OnGitPullCreated trigger ({Count} items)", payload.Body.Value.Count);
    }

    [Function("OnGitPush")]
    public void OnGitPush(
        [ConnectorTrigger(DeliveryMode = ConnectorTriggerDeliveryMode.Poll, Connection = "ConnectorNamespace", TriggerConfigName = "%OnGitPushTriggerConfigName%")]
        VisualStudioTeamServicesOnGitPushTriggerPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload.Body?.Value);
        logger.LogInformation("Received OnGitPush trigger ({Count} items)", payload.Body.Value.Count);
    }

    [Function("OnTfvcCheckIn")]
    public void OnTfvcCheckIn(
        [ConnectorTrigger(DeliveryMode = ConnectorTriggerDeliveryMode.Poll, Connection = "ConnectorNamespace", TriggerConfigName = "%OnTfvcCheckInTriggerConfigName%")]
        VisualStudioTeamServicesOnTfvcCheckInTriggerPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload.Body?.Value);
        logger.LogInformation("Received OnTfvcCheckIn trigger ({Count} items)", payload.Body.Value.Count);
    }

    [Function("OnWorkItemCreated")]
    public void OnWorkItemCreated(
        [ConnectorTrigger(DeliveryMode = ConnectorTriggerDeliveryMode.Poll, Connection = "ConnectorNamespace", TriggerConfigName = "%OnWorkItemCreatedTriggerConfigName%")] string payload)
    {
        logger.LogInformation("Received OnWorkItemCreated trigger");
    }

    [Function("OnWorkItemUpdated")]
    public void OnWorkItemUpdated(
        [ConnectorTrigger(DeliveryMode = ConnectorTriggerDeliveryMode.Poll, Connection = "ConnectorNamespace", TriggerConfigName = "%OnWorkItemUpdatedTriggerConfigName%")] string payload)
    {
        logger.LogInformation("Received OnWorkItemUpdated trigger");
    }

    [Function("OnWorkItemClosed")]
    public void OnWorkItemClosed(
        [ConnectorTrigger(DeliveryMode = ConnectorTriggerDeliveryMode.Poll, Connection = "ConnectorNamespace", TriggerConfigName = "%OnWorkItemClosedTriggerConfigName%")] string payload)
    {
        logger.LogInformation("Received OnWorkItemClosed trigger");
    }

    [Function("OnWorkItemAssigned")]
    public void OnWorkItemAssigned(
        [ConnectorTrigger(DeliveryMode = ConnectorTriggerDeliveryMode.Poll, Connection = "ConnectorNamespace", TriggerConfigName = "%OnWorkItemAssignedTriggerConfigName%")] string payload)
    {
        logger.LogInformation("Received OnWorkItemAssigned trigger");
    }
}
