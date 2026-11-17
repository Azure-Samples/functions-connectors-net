// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Azure.Connectors.Sdk.Planner.Models;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;

namespace PlannerApp;

public class PlannerFunctions(ILogger<PlannerFunctions> logger)
{
    [Function("OnNewTask")]
    public void OnNewTask([ConnectorTrigger] PlannerOnNewTaskTriggerPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload.Body);
        ArgumentNullException.ThrowIfNull(payload.Body.Value);
        logger.LogInformation("Received OnNewTask trigger ({Count} tasks)", payload.Body.Value.Count);
    }

    [Function("OnCompleteTask")]
    public void OnCompleteTask([ConnectorTrigger] PlannerOnCompleteTaskTriggerPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload.Body);
        ArgumentNullException.ThrowIfNull(payload.Body.Value);
        logger.LogInformation("Received OnCompleteTask trigger ({Count} tasks)", payload.Body.Value.Count);
    }

    [Function("OnTaskAssignedToMe")]
    public void OnTaskAssignedToMe([ConnectorTrigger] PlannerOnTaskAssignedToMeTriggerPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload.Body);
        ArgumentNullException.ThrowIfNull(payload.Body.Value);
        logger.LogInformation("Received OnTaskAssignedToMe trigger ({Count} tasks)", payload.Body.Value.Count);
    }
}
