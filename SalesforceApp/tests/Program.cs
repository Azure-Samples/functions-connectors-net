using System.Reflection;
using System.Text.Json;
using Azure.Identity;
using Azure.Monitor.OpenTelemetry.Exporter;
using Azure.Connectors.Sdk.Salesforce.Models;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Connector;
using Microsoft.Extensions.Azure;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using PollFunctions = SalesforceApp.Polling.SalesforceFunctions;
using WebhookFunctions = SalesforceApp.Webhook.SalesforceFunctions;

CheckFunctions<PollFunctions>(ConnectorTriggerDeliveryMode.Poll);
CheckFunctions<WebhookFunctions>(ConnectorTriggerDeliveryMode.Webhook);
CheckCredentials();
Console.WriteLine("Passed: both modes, both SDK payload types, empty/multi-record counts, privacy, binding contracts and named credential selection.");

static void CheckFunctions<T>(ConnectorTriggerDeliveryMode mode)
{
    var logger = new ReceiptLogger<T>();
    var instance = Activator.CreateInstance(typeof(T), logger)
        ?? throw new InvalidOperationException("Could not construct handler.");
    var methods = typeof(T).GetMethods().Where(m => m.GetCustomAttribute<FunctionAttribute>() != null).ToArray();
    Require(methods.Length == 2, "Expected exactly both Salesforce handlers.");
    foreach (var method in methods)
    {
        var function = method.GetCustomAttribute<FunctionAttribute>()!.Name;
        var parameter = method.GetParameters().Single();
        var binding = parameter.GetCustomAttribute<ConnectorTriggerAttribute>()!;
        Require(binding.DeliveryMode == mode, $"{function}: wrong mode.");
        if (mode == ConnectorTriggerDeliveryMode.Poll)
        {
            Require(binding.Connection == "ConnectorNamespace", "Wrong credential configuration prefix.");
            Require(binding.TriggerConfigName == $"%{function}TriggerConfigName%", "Wrong trigger config setting.");
        }
        else
        {
            Require(string.IsNullOrEmpty(binding.Connection), "Webhook unexpectedly needs a Poll connection.");
        }
        Require(parameter.ParameterType == (function == "OnNewRecord"
            ? typeof(SalesforceOnNewItemsTriggerPayload)
            : typeof(SalesforceOnUpdatedItemsTriggerPayload)), "Wrong typed trigger model.");
        foreach (var count in new[] { 0, 1, 3 })
        {
            var records = Enumerable.Range(0, count).Select(i => new
            {
                Id = $"private-id-{i}",
                Name = "private-record-name",
                CreatedDate = "2026-10-30T00:00:00Z",
                LastModifiedDate = "2026-10-30T01:00:00Z"
            });
            // The host normalizes Poll outputs into this same callback envelope.
            var json = JsonSerializer.Serialize(new { body = new { value = records } });
            var payload = JsonSerializer.Deserialize(json, parameter.ParameterType)!;
            logger.Receipts.Clear();
            method.Invoke(instance, [payload]);
            Require(logger.Receipts.Count == 1, $"{function}: expected exactly one direct receipt.");
            var receipt = logger.Receipts.Single();
            Require(receipt.Level == LogLevel.Information, "Unexpected receipt level.");
            Require(receipt.Message == $"Received {function} trigger ({count} records)", "Unexpected log content.");
            Require(receipt.State.Count == 2 && (int)receipt.State["Count"]! == count
                && receipt.State.ContainsKey("{OriginalFormat}"), "Only actual Count and template may be logged.");
            Require(!receipt.Message.Contains("private", StringComparison.Ordinal), "Payload data leaked.");
        }
        logger.Receipts.Clear();
        var missingBody = JsonSerializer.Deserialize("{}", parameter.ParameterType)!;
        try
        {
            method.Invoke(instance, [missingBody]);
            throw new Exception("Missing collection was accepted.");
        }
        catch (TargetInvocationException error) when (error.InnerException is InvalidOperationException)
        {
            Require(logger.Receipts.Count == 0, "Malformed payload emitted a success-shaped receipt.");
        }
    }
}

static void CheckCredentials()
{
    foreach (var deployed in new[] { false, true })
    {
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(deployed
            ? new Dictionary<string, string?> { ["ConnectorNamespace:credential"] = "managedidentity" }
            : new Dictionary<string, string?>()).Build();
        var services = new ServiceCollection();
        services.AddAzureClientsCore();
        services.AddOptions<AzureMonitorExporterOptions>()
            .Configure<AzureComponentFactory>((options, factory) =>
                options.Credential = factory.CreateTokenCredential(configuration.GetSection("ConnectorNamespace")));
        using var provider = services.BuildServiceProvider();
        var credential = provider.GetRequiredService<IOptions<AzureMonitorExporterOptions>>().Value.Credential;
        Require(deployed ? credential is ManagedIdentityCredential : credential is DefaultAzureCredential,
            "Named ConnectorNamespace credential did not select app MI/developer fallback.");
    }
}

static void Require(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}

sealed class ReceiptLogger<T> : ILogger<T>
{
    public List<(LogLevel Level, string Message, Dictionary<string, object?> State)> Receipts { get; } = [];
    public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
    public bool IsEnabled(LogLevel logLevel) => true;
    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state,
        Exception? exception, Func<TState, Exception?, string> formatter)
    {
        var values = ((IEnumerable<KeyValuePair<string, object?>>)(object)state!)
            .ToDictionary(pair => pair.Key, pair => pair.Value);
        Receipts.Add((logLevel, formatter(state, exception), values));
    }
}
