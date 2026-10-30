// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using System.Net;
using Azure.Connectors.Sdk;
using Azure.Connectors.Sdk.Commondataservice;
using Azure.Connectors.Sdk.Commondataservice.Models;
using Azure.Core;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;

namespace DataverseApp;

/// <summary>
/// Microsoft Dataverse (Common Data Service) connector functions.
///
/// <para><b>OnDataverseRowChanged</b> is a <see cref="ConnectorTriggerAttribute"/> binding: the
/// Connector Namespace checks Dataverse for new rows (operation <c>GetOnNewItems_V2</c>).
/// The Functions host receives and acknowledges queued events using Poll delivery.</para>
///
/// <para><b>ListDataverseRows</b> is an HTTP-triggered action that calls Dataverse through the generated
/// <see cref="CommondataserviceClient"/> (operation <c>GetItems_V2</c>) to read rows on demand.</para>
/// </summary>
public class DataverseFunctions
{
    private readonly ILogger<DataverseFunctions> _logger;
    private readonly TokenCredential _credential;

    public DataverseFunctions(ILogger<DataverseFunctions> logger, TokenCredential credential)
    {
        _logger = logger;
        _credential = credential;
    }

    /// <summary>
    /// Fires when a new row is added to the configured Dataverse table.
    /// Logs the number of received rows without storing their contents.
    /// </summary>
    [Function("OnDataverseRowChanged")]
    public void OnDataverseRowChanged(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnDataverseRowChangedTriggerConfigName%")]
        CommondataserviceOnNewItemsTriggerPayload payload)
    {
        var rowCount = payload?.Body?.Value?.Count ?? 0;
        _logger.LogInformation("Received OnDataverseRowChanged trigger with {RowCount} row(s).", rowCount);
    }

    [Function("OnDataverseRowModified")]
    public void OnDataverseRowModified(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnDataverseRowModifiedTriggerConfigName%")]
        CommondataserviceOnUpdatedItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnDataverseRowModified trigger with {RowCount} row(s).",
            payload?.Body?.Value?.Count ?? 0);
    }

    [Function("OnDataverseRowDeleted")]
    public void OnDataverseRowDeleted(
        [ConnectorTrigger(
            DeliveryMode = ConnectorTriggerDeliveryMode.Poll,
            Connection = "ConnectorNamespace",
            TriggerConfigName = "%OnDataverseRowDeletedTriggerConfigName%")]
        CommondataserviceOnDeletedItemsTriggerPayload payload)
    {
        _logger.LogInformation("Received OnDataverseRowDeleted trigger with {RowCount} row(s).",
            payload?.Body?.Value?.Count ?? 0);
    }

    /// <summary>
    /// Reads rows from a Dataverse table on demand using the generated <see cref="CommondataserviceClient"/>.
    /// GET /api/rows?table=accounts&amp;top=10
    /// </summary>
    [Function("ListDataverseRows")]
    public async Task<HttpResponseData> ListDataverseRowsAsync(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "rows")] HttpRequestData request,
        CancellationToken cancellationToken)
    {
        _logger.LogInformation("ListDataverseRows: reading rows via CommondataserviceClient.");

        // The dataset for the Dataverse dataset APIs is the environment (org) URL, e.g.
        // https://contoso.crm.dynamics.com. The same URL is configured for the Poll trigger.
        var environmentUrl = Environment.GetEnvironmentVariable("DATAVERSE_ENVIRONMENT_URL");
        var runtimeUrl = Environment.GetEnvironmentVariable("DATAVERSE_CONNECTION_RUNTIME_URL");

        var table = request.Query["table"];
        if (string.IsNullOrWhiteSpace(table))
        {
            table = Environment.GetEnvironmentVariable("DATAVERSE_TABLE_NAME");
        }

        var top = 10;
        if (int.TryParse(request.Query["top"], out var parsedTop) && parsedTop > 0)
        {
            top = parsedTop;
        }

        if (string.IsNullOrWhiteSpace(environmentUrl) || string.IsNullOrWhiteSpace(runtimeUrl))
        {
            var badRequest = request.CreateResponse(HttpStatusCode.BadRequest);
            await badRequest
                .WriteAsJsonAsync(new
                {
                    success = false,
                    error = "DATAVERSE_ENVIRONMENT_URL and DATAVERSE_CONNECTION_RUNTIME_URL must be configured.",
                })
                .ConfigureAwait(false);
            return badRequest;
        }

        if (string.IsNullOrWhiteSpace(table))
        {
            var badRequest = request.CreateResponse(HttpStatusCode.BadRequest);
            await badRequest
                .WriteAsJsonAsync(new
                {
                    success = false,
                    error = "Provide a table via ?table=<plural logical name> or set DATAVERSE_TABLE_NAME.",
                })
                .ConfigureAwait(false);
            return badRequest;
        }

        try
        {
            var client = new CommondataserviceClient(new Uri(runtimeUrl), _credential);

            var items = await client
                .GetItemsAsync(
                    environment: environmentUrl.TrimEnd('/'),
                    tableName: table,
                    topCount: top,
                    cancellationToken: cancellationToken)
                .ConfigureAwait(false);

            var rowCount = items?.Value?.Count ?? 0;
            _logger.LogInformation("Retrieved {RowCount} row(s) from table '{Table}'.", rowCount, table);

            var response = request.CreateResponse(HttpStatusCode.OK);
            await response.WriteAsJsonAsync(items).ConfigureAwait(false);
            return response;
        }
        catch (ConnectorException ex)
        {
            _logger.LogError(ex, "Dataverse connector error: '{StatusCode}'.", ex.Status);

            var errorResponse = request.CreateResponse(HttpStatusCode.BadGateway);
            await errorResponse
                .WriteAsJsonAsync(new { success = false, error = ex.Message, statusCode = ex.Status, details = ex.ResponseBody })
                .ConfigureAwait(false);
            return errorResponse;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error in ListDataverseRows.");

            var errorResponse = request.CreateResponse(HttpStatusCode.InternalServerError);
            await errorResponse
                .WriteAsJsonAsync(new { success = false, error = ex.Message })
                .ConfigureAwait(false);
            return errorResponse;
        }
    }
}
