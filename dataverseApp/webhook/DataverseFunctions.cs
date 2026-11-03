// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using System.Text.Json;
using Azure.Connectors.Sdk.Commondataservice.Models;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;

namespace DataverseApp;

public class DataverseFunctions(ILogger<DataverseFunctions> logger)
{
    [Function("OnDataverseRowAdded")]
    public void OnDataverseRowAdded([ConnectorTrigger] CommondataserviceOnNewItemsTriggerPayload payload)
    {
        logger.LogInformation("Received OnDataverseRowAdded trigger");
    }

    [Function("OnDataverseRowModified")]
    public void OnDataverseRowModified([ConnectorTrigger] CommondataserviceOnUpdatedItemsTriggerPayload payload)
    {
        logger.LogInformation("Received OnDataverseRowModified trigger");
    }

    [Function("OnDataverseRowDeleted")]
    public void OnDataverseRowDeleted([ConnectorTrigger] CommondataserviceOnDeletedItemsTriggerPayload payload)
    {
        logger.LogInformation("Received OnDataverseRowDeleted trigger");
    }

    // Explicit raw-JSON exceptions: the SDK has no models for these current operations.
    [Function("OnDataverseRowChanged")]
    public void OnDataverseRowChanged([ConnectorTrigger] JsonElement payload)
    {
        logger.LogInformation("Received OnDataverseRowChanged trigger");
    }

    [Function("OnDataverseActionPerformed")]
    public void OnDataverseActionPerformed([ConnectorTrigger] JsonElement payload)
    {
        logger.LogInformation("Received OnDataverseActionPerformed trigger");
    }
}
