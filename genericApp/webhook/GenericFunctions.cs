// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Logging;

namespace GenericApp;

/// <summary>
/// Demonstrates the generic (untyped) connector trigger binding.
/// Each function receives the raw JSON payload as a string instead of a
/// strongly-typed SDK model. Use this approach when:
///   - The connector does not have a first-class wrapper in Azure.Connectors.Sdk.
///   - You need access to the payload without deserializing it.
///   - You need a minimal dependency footprint without the generated SDK package.
/// </summary>
public class GenericFunctions
{
    private readonly ILogger<GenericFunctions> _logger;

    public GenericFunctions(ILogger<GenericFunctions> logger)
    {
        _logger = logger;
    }

    [Function("OnGenericOffice365NewEmail")]
    public void OnGenericOffice365NewEmail(
        [ConnectorTrigger] string payload)
    {
        _logger.LogInformation("OnGenericOffice365NewEmail (generic API) trigger received.");
    }

    [Function("OnGenericAzureBlobUpdated")]
    public void OnGenericAzureBlobUpdated(
        [ConnectorTrigger] string payload)
    {
        _logger.LogInformation("OnGenericAzureBlobUpdated (generic API) trigger received.");
    }

    [Function("OnGenericSharepointNewFile")]
    public void OnGenericSharepointNewFile(
        [ConnectorTrigger] string payload)
    {
        _logger.LogInformation("OnGenericSharepointNewFile (generic API) trigger received.");
    }

    [Function("OnGenericTeamsChannelMessage")]
    public void OnGenericTeamsChannelMessage(
        [ConnectorTrigger] string payload)
    {
        _logger.LogInformation("OnGenericTeamsChannelMessage (generic API) trigger received.");
    }

    [Function("OnGenericCustomConnectorEvent")]
    public void OnGenericCustomConnectorEvent(
        [ConnectorTrigger] string payload)
    {
        _logger.LogInformation("OnGenericCustomConnectorEvent (generic API) trigger received.");
    }
}
