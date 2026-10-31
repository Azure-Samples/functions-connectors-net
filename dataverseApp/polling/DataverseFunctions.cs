// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using System.Text.Json;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;

namespace DataverseApp;

public class DataverseFunctions(ILogger<DataverseFunctions> logger)
{
    // Explicit raw-JSON exceptions: the SDK has no models for these current operations.
    [Function("OnDataverseRowChanged")]
    public void OnDataverseRowChanged(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnDataverseRowChangedTriggerConfigName%")]
        JsonElement payload)
    {
        logger.LogInformation("Received OnDataverseRowChanged trigger");
    }

    [Function("OnDataverseActionPerformed")]
    public void OnDataverseActionPerformed(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnDataverseActionPerformedTriggerConfigName%")]
        JsonElement payload)
    {
        logger.LogInformation("Received OnDataverseActionPerformed trigger");
    }
}
