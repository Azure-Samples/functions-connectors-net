// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Azure.Core;
using Azure.Identity;
using Azure.Monitor.OpenTelemetry.Exporter;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.OpenTelemetry;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using OpenTelemetry;

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .ConfigureServices(services =>
    {
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("APPLICATIONINSIGHTS_CONNECTION_STRING")))
        {
            services.AddOpenTelemetry()
                .UseFunctionsWorkerDefaults()
                .UseAzureMonitorExporter();
        }

        // Register a TokenCredential for the Dataverse SDK action.
        //
        // The Azure Connectors SDK does not (yet) ship an AddCommondataserviceClient
        // dependency-injection extension, so DataverseFunctions constructs the
        // CommondataserviceClient itself using this credential and the connection's
        // runtime URL (DATAVERSE_CONNECTION_RUNTIME_URL).
        //
        // DefaultAzureCredential honours AZURE_CLIENT_ID, so in Azure it authenticates
        // as the function app's user-assigned managed identity; locally it falls back
        // to the Azure CLI / Visual Studio / environment credentials.
        services.AddSingleton<TokenCredential>(new DefaultAzureCredential());
    })
    .Build();

host.Run();
