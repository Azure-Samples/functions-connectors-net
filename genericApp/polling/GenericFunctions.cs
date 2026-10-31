// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;

namespace GenericApp;

public class GenericFunctions
{
    private readonly ILogger<GenericFunctions> _logger;

    public GenericFunctions(ILogger<GenericFunctions> logger)
    {
        _logger = logger;
    }

    [Function("OnGenericConnectorEvent")]
    public void OnGenericConnectorEvent(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%GenericTriggerConfigName%")]
        string payload)
    {
        _logger.LogInformation("OnGenericConnectorEvent (generic API) trigger received.");
    }
}
