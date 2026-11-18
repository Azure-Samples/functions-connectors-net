using Azure.Connectors.Sdk.VisualStudioTeamServices.Models;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;

namespace AzureDevOpsApp;

public class AzureDevOpsFunctions(ILogger<AzureDevOpsFunctions> logger)
{
    [Function("OnBuildCompleted")]
    public void OnBuildCompleted([ConnectorTrigger] VisualStudioTeamServicesOnBuildCompletedTriggerPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload.Body?.Value);
        logger.LogInformation("Received OnBuildCompleted trigger ({Count} items)", payload.Body.Value.Count);
    }

    [Function("OnGitPullClosed")]
    public void OnGitPullClosed([ConnectorTrigger] VisualStudioTeamServicesOnGitPullClosedTriggerPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload.Body?.Value);
        logger.LogInformation("Received OnGitPullClosed trigger ({Count} items)", payload.Body.Value.Count);
    }

    [Function("OnGitPullCreated")]
    public void OnGitPullCreated([ConnectorTrigger] VisualStudioTeamServicesOnGitPullCreatedTriggerPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload.Body?.Value);
        logger.LogInformation("Received OnGitPullCreated trigger ({Count} items)", payload.Body.Value.Count);
    }

    [Function("OnGitPush")]
    public void OnGitPush([ConnectorTrigger] VisualStudioTeamServicesOnGitPushTriggerPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload.Body?.Value);
        logger.LogInformation("Received OnGitPush trigger ({Count} items)", payload.Body.Value.Count);
    }

    [Function("OnTfvcCheckIn")]
    public void OnTfvcCheckIn([ConnectorTrigger] VisualStudioTeamServicesOnTfvcCheckInTriggerPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload.Body?.Value);
        logger.LogInformation("Received OnTfvcCheckIn trigger ({Count} items)", payload.Body.Value.Count);
    }

    [Function("OnWorkItemCreated")]
    public void OnWorkItemCreated([ConnectorTrigger] string payload)
    {
        logger.LogInformation("Received OnWorkItemCreated trigger");
    }

    [Function("OnWorkItemUpdated")]
    public void OnWorkItemUpdated([ConnectorTrigger] string payload)
    {
        logger.LogInformation("Received OnWorkItemUpdated trigger");
    }

    [Function("OnWorkItemClosed")]
    public void OnWorkItemClosed([ConnectorTrigger] string payload)
    {
        logger.LogInformation("Received OnWorkItemClosed trigger");
    }

    [Function("OnWorkItemAssigned")]
    public void OnWorkItemAssigned([ConnectorTrigger] string payload)
    {
        logger.LogInformation("Received OnWorkItemAssigned trigger");
    }
}
