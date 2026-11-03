// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Azure.Monitor.OpenTelemetry.Exporter;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.OpenTelemetry;
using Microsoft.Extensions.Azure;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using OpenTelemetry;

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .ConfigureServices((context, services) =>
    {
        var connectionString = context.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"];
        if (!string.IsNullOrEmpty(connectionString))
        {
            services.AddAzureClientsCore();
            services.AddOpenTelemetry()
                .UseFunctionsWorkerDefaults()
                .UseAzureMonitorExporter();
            services.AddOptions<AzureMonitorExporterOptions>()
                .Configure<AzureComponentFactory>((options, factory) =>
                {
                    options.ConnectionString = connectionString;
                    options.Credential = factory.CreateTokenCredential(context.Configuration.GetSection("ConnectorNamespace"));
                });
        }
    })
    .Build();

host.Run();
