// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Azure.Connectors.Sdk.Salesforce.Models;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;

namespace SalesforceApp.Webhook;

public class SalesforceFunctions(ILogger<SalesforceFunctions> logger)
{
    [Function("OnNewRecord")]
    public void OnNewRecord([ConnectorTrigger] SalesforceOnNewItemsTriggerPayload payload)
    {
        var records = payload.Body?.Value
            ?? throw new InvalidOperationException("OnNewRecord requires a record collection.");
        logger.LogInformation("Received OnNewRecord trigger ({Count} records)", records.Count);
    }

    [Function("OnUpdatedRecord")]
    public void OnUpdatedRecord([ConnectorTrigger] SalesforceOnUpdatedItemsTriggerPayload payload)
    {
        var records = payload.Body?.Value
            ?? throw new InvalidOperationException("OnUpdatedRecord requires a record collection.");
        logger.LogInformation("Received OnUpdatedRecord trigger ({Count} records)", records.Count);
    }
}
