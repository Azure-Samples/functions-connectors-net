// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using System.Text.Json;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;

namespace DataverseApp;

public class DataverseFunctions(ILogger<DataverseFunctions> logger)
{
    [Function("OnDataverseRowAdded")]
    public void OnDataverseRowAdded([ConnectorTrigger] JsonElement payload)
    {
        logger.LogInformation("Received OnDataverseRowAdded trigger");
    }

    [Function("OnDataverseRowModified")]
    public void OnDataverseRowModified([ConnectorTrigger] JsonElement payload)
    {
        logger.LogInformation("Received OnDataverseRowModified trigger");
    }

    [Function("OnDataverseRowDeleted")]
    public void OnDataverseRowDeleted([ConnectorTrigger] JsonElement payload)
    {
        logger.LogInformation("Received OnDataverseRowDeleted trigger");
    }

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
