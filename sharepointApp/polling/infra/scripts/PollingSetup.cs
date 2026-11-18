// Copyright (c) .NET Foundation. All rights reserved.
// Licensed under the MIT License.

#:property PublishAot=false
#nullable enable
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace ConnectorPolling;

public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        try
        {
            if (args.Length != 1 || args[0] is not ("prepare" or "verify" or "finish"))
                throw new InvalidOperationException("Specify the prepare, verify, or finish polling setup phase.");
            var scripts = Path.GetDirectoryName(SourcePath())!;
            var project = Path.GetFullPath(Path.Combine(scripts, "../.."));
            var config = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(scripts, "polling-config.json")))!;
            var example = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(project, "local.settings.example.json")))!;
            var host = new SetupHost();
            var outputs = JsonNode.Parse(await host.RunAsync("azd", ["env", "get-values", "--output", "json"]))!;
            var settings = await new PollingSetup(config, example, outputs, host).ExecuteAsync(args[0]);
            if (args[0] == "finish")
                host.Log(LocalSettings.Create(project, example, settings!)
                    ? "Created local.settings.json for local developer authentication."
                    : "Existing local.settings.json was preserved. Update it manually if its settings have changed.");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"Polling setup failed: {error.Message}");
            return 1;
        }
    }

    static string SourcePath([CallerFilePath] string file = "") => file;
}

public record Choice(string Label, JsonNode? Value);

public class SetupHost
{
    public virtual void Log(string message) => Console.WriteLine(message);
    public virtual Task WaitAsync(int milliseconds) => Task.Delay(milliseconds);
    public virtual Task<string> RunAsync(string command, IReadOnlyList<string> args, Func<Task<bool>>? checkConnected = null)
        => Commands.RunAsync(command, args, checkConnected);

    public virtual Task<JsonNode?> ChooseAsync(string label, IReadOnlyList<Choice> choices)
    {
        if (choices.Count == 0) throw new InvalidOperationException($"No choices are available for {label}.");
        Log($"\n{label}");
        for (var i = 0; i < choices.Count; i++) Log($"  [{i + 1}] {choices[i].Label}");
        while (true)
        {
            var answer = Question($"Enter number (1-{choices.Count}): ");
            if (int.TryParse(answer, out var index) && index >= 1 && index <= choices.Count)
                return Task.FromResult(choices[index - 1].Value.Copy());
        }
    }

    public virtual Task<JsonNode?> PromptAsync(string label, JsonNode schema, bool allowEmpty = false)
    {
        while (true)
        {
            var description = schema.Text("description");
            var answer = Question($"{label}{(description.Length > 0 ? $" ({description})" : "")}: ");
            if (allowEmpty && answer.Length == 0) return Task.FromResult<JsonNode?>(null);
            if (schema.Text("type") == "string" && answer.Length >= Math.Max(1, schema.Number("minLength") ?? 0)
                && answer.Length <= (schema.Number("maxLength") ?? double.PositiveInfinity)
                && (schema.Text("pattern").Length == 0 || Regex.IsMatch(answer, schema.Text("pattern"), RegexOptions.None, TimeSpan.FromSeconds(1))))
                return Task.FromResult<JsonNode?>(JsonValue.Create(answer));
            if (schema.Text("type") is "number" or "integer"
                && double.TryParse(answer, NumberStyles.Float, CultureInfo.InvariantCulture, out var number)
                && double.IsFinite(number) && (schema.Text("type") != "integer" || Math.Truncate(number) == number)
                && number >= (schema.Number("minimum") ?? double.NegativeInfinity)
                && number <= (schema.Number("maximum") ?? double.PositiveInfinity))
                return Task.FromResult<JsonNode?>(JsonValue.Create(number));
            Log("Enter a non-empty value matching the requested type and constraints.");
        }
    }

    static string Question(string label)
    {
        if (Console.IsInputRedirected)
            throw new InvalidOperationException("Source selection requires a terminal. Run azd provision triggers interactively.");
        Console.Write(label);
        return Console.ReadLine()?.Trim() ?? throw new OperationCanceledException("Source selection was cancelled.");
    }

    public async Task<bool> ConfirmAsync(string label) =>
        (await ChooseAsync(label, [new("Skip", JsonValue.Create(false)), new("Configure", JsonValue.Create(true))])).Flag();
}

public static class Json
{
    public static JsonNode? Copy(this JsonNode? value) => value?.DeepClone();
    public static JsonNode? Get(this JsonNode? value, string? path)
    {
        if (string.IsNullOrEmpty(path)) return value;
        if (value is JsonObject obj && obj.TryGetPropertyValue(path, out var exact)) return exact;
        foreach (var part in path.Split(['/', '.'], StringSplitOptions.RemoveEmptyEntries))
        {
            if (value is JsonObject item) value = item[part];
            else if (value is JsonArray array && int.TryParse(part, out var i) && i >= 0 && i < array.Count) value = array[i];
            else return null;
        }
        return value;
    }
    public static string Text(this JsonNode? value, string? path = null)
    {
        value = value.Get(path);
        return value is JsonValue scalar && scalar.TryGetValue<string>(out var text) ? text : value?.ToJsonString() ?? "";
    }
    public static bool Flag(this JsonNode? value, string? path = null) =>
        value.Get(path) is JsonValue scalar && scalar.TryGetValue<bool>(out var result) && result;
    public static double? Number(this JsonNode? value, string path) =>
        double.TryParse(value.Text(path), NumberStyles.Float, CultureInfo.InvariantCulture, out var result) ? result : null;
    public static IEnumerable<KeyValuePair<string, JsonNode?>> Fields(this JsonNode? value) =>
        value is JsonObject obj ? obj : [];
    public static IEnumerable<JsonNode> Items(this JsonNode? value) =>
        value is JsonArray array ? array.OfType<JsonNode>() : [];
    public static JsonObject Merge(params JsonNode?[] objects)
    {
        var result = new JsonObject();
        foreach (var obj in objects)
            foreach (var (key, value) in obj.Fields()) result[key] = value.Copy();
        return result;
    }
    public static string Encode(JsonNode node) => Convert.ToBase64String(Encoding.UTF8.GetBytes(node.ToJsonString()));
    public static JsonNode Decode(string text) => JsonNode.Parse(Encoding.UTF8.GetString(Convert.FromBase64String(text)))!;
    public static JsonArray Array(IEnumerable<JsonNode> items) => new(items.Select(x => x.Copy()).ToArray());
    public static string Escape(string value) => Uri.EscapeDataString(value)
        .Replace("%21", "!").Replace("%27", "'").Replace("%28", "(").Replace("%29", ")").Replace("%2A", "*");
}

public static class LocalSettings
{
    public static bool Create(string project, JsonNode example, JsonNode settings)
    {
        var path = Path.Combine(project, "local.settings.json");
        FileStream stream;
        try { stream = PrivateFiles.Create(path); }
        catch (IOException) when (File.Exists(path) || Directory.Exists(path)) { return false; }
        using (stream)
        using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
        {
            var result = Json.Merge(example);
            result["Values"] = Json.Merge(example["Values"], settings);
            writer.Write(result.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) + "\n");
        }
        return true;
    }
}

public static class PrivateFiles
{
    public static FileStream Create(string path)
    {
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        return new FileStream(path, options);
    }
}

public static class Commands
{
    public static async Task<string> RunAsync(string command, IReadOnlyList<string> args, Func<Task<bool>>? checkConnected = null)
    {
        var interactive = checkConnected != null;
        var start = new ProcessStartInfo
        {
            FileName = OperatingSystem.IsWindows() ? "powershell.exe" : command,
            UseShellExecute = false,
            RedirectStandardOutput = !interactive,
            RedirectStandardError = !interactive
        };
        if (OperatingSystem.IsWindows())
        {
            foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-Command",
                "$ErrorActionPreference = 'Stop'; [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); " +
                "$setupArgs = @($env:POLLING_SETUP_ARGS | ConvertFrom-Json); & $env:POLLING_SETUP_COMMAND @setupArgs; exit $LASTEXITCODE" })
                start.ArgumentList.Add(argument);
            start.Environment["POLLING_SETUP_COMMAND"] = command;
            start.Environment["POLLING_SETUP_ARGS"] = JsonSerializer.Serialize(args);
        }
        else foreach (var argument in args) start.ArgumentList.Add(argument);
        if (!interactive)
        {
            start.StandardOutputEncoding = Encoding.UTF8;
            start.StandardErrorEncoding = Encoding.UTF8;
        }
        using var child = Process.Start(start) ?? throw new InvalidOperationException($"Could not start {command}.");
        var output = interactive ? Task.FromResult("") : child.StandardOutput.ReadToEndAsync();
        var error = interactive ? Task.FromResult("") : child.StandardError.ReadToEndAsync();
        var exit = child.WaitForExitAsync();
        var timeout = Task.Delay(TimeSpan.FromSeconds(interactive ? 660 : 120));
        try
        {
            while (!exit.IsCompleted)
            {
                if (checkConnected != null)
                {
                    var confirmed = false;
                    try { confirmed = await checkConnected(); } catch { }
                    if (confirmed)
                    {
                        // Only stop this child: Azure may confirm consent before the browser callback returns.
                        if (!child.HasExited) child.Kill(entireProcessTree: true);
                        await exit.WaitAsync(TimeSpan.FromSeconds(10));
                        return "";
                    }
                }
                var next = await Task.WhenAny(exit, timeout, Task.Delay(10_000));
                if (next == timeout) throw new TimeoutException($"{command} timed out.");
            }
            await exit;
            var stdout = await output;
            var stderr = await error;
            if (child.ExitCode != 0) throw new InvalidOperationException($"{command} failed: {(interactive ? $"exit code {child.ExitCode}" : stderr.Trim())}");
            return stdout.Trim();
        }
        finally
        {
            if (!child.HasExited) child.Kill(entireProcessTree: true);
        }
    }
}

public sealed class PollingSetup(JsonNode config, JsonNode example, JsonNode outputs, SetupHost host)
{
    const string ApiVersion = "2026-05-01-preview";
    readonly JsonArray definitions = config["triggers"]!.AsArray();
    string temporary = "";
    string subscription = "";
    int requestNumber;

    public static string PollingEndpoint(string receiveUri)
    {
        if (!Uri.TryCreate(receiveUri, UriKind.Absolute, out var uri) || uri.Scheme != "https"
            || uri.UserInfo.Length > 0 || uri.Fragment.Length > 0)
            throw new InvalidOperationException("The service returned an unsafe polling endpoint.");
        var match = Regex.Match(uri.AbsolutePath, @"^(.*?)/triggerconfigs/[^/]+/receive/?$", RegexOptions.IgnoreCase);
        if (!match.Success) throw new InvalidOperationException("The service did not return a Poll receive URI.");
        var prefix = match.Groups[1].Value;
        if (prefix != "" && !prefix.Equals("/api", StringComparison.OrdinalIgnoreCase)
            && !Regex.IsMatch(prefix, "^/api/connectorGateways/[^/]+$", RegexOptions.IgnoreCase))
            throw new InvalidOperationException("The service returned an unsupported polling endpoint path.");
        return uri.GetLeftPart(UriPartial.Authority) + (prefix.Equals("/api", StringComparison.OrdinalIgnoreCase) ? "" : prefix);
    }

    public async Task<JsonObject?> ExecuteAsync(string phase)
    {
        if (phase is not ("prepare" or "verify" or "finish")) throw new InvalidOperationException("Specify the prepare, verify, or finish polling setup phase.");
        foreach (var key in new[] { "resourceGroupName", "functionAppName", "connectorNamespaceName",
            "connectorNamespaceResourceId", "connectorNamespaceConnectionName", "CONNECTOR_NAMESPACE_LOCATION" })
            if (outputs.Text(key).Length == 0) throw new InvalidOperationException($"Missing azd output {key}. Run azd provision first.");
        var match = Regex.Match(outputs.Text("connectorNamespaceResourceId"),
            @"^/subscriptions/([^/]+)/resourceGroups/[^/]+/providers/Microsoft\.Web/connectorGateways/[^/]+$", RegexOptions.IgnoreCase);
        if (!match.Success) throw new InvalidOperationException("Invalid Connector Namespace resource ID.");
        subscription = match.Groups[1].Value;
        temporary = Directory.CreateTempSubdirectory("connector-poll-").FullName;
        if (!OperatingSystem.IsWindows())
            File.SetUnixFileMode(temporary, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        try { return await ExecuteCoreAsync(phase); }
        finally { Directory.Delete(temporary, recursive: true); }
    }

    async Task<JsonObject?> ExecuteCoreAsync(string phase)
    {
        var root = $"https://management.azure.com{outputs.Text("connectorNamespaceResourceId")}";
        await AuthenticateAsync(phase, $"{root}/connections/{Json.Escape(outputs.Text("connectorNamespaceConnectionName"))}");
        JsonArray triggers;
        if (outputs.Text("POLLING_TRIGGER_INPUTS").Length > 0)
            triggers = Json.Decode(outputs.Text("POLLING_TRIGGER_INPUTS")) as JsonArray
                ?? throw new InvalidOperationException("Polling setup requires distinct selected triggers.");
        else
        {
            if (phase != "prepare") throw new InvalidOperationException("Missing selected Poll inputs. Rerun azd provision triggers.");
            triggers = await SelectInputsAsync();
        }
        if (triggers.Count == 0 || triggers.Items().Select(t => t.Text("functionName")).Distinct().Count() != triggers.Count)
            throw new InvalidOperationException("Polling setup requires distinct selected triggers.");
        foreach (var trigger in triggers.Items())
        {
            var definition = definitions.Items().FirstOrDefault(d => d.Text("functionName") == trigger.Text("functionName"));
            if (definition == null || definition.Text("operationName") != trigger.Text("operationName")
                || trigger["parameters"] is not JsonArray parameters
                || parameters.Count != parameters.Items().Count()
                || parameters.Items().Any(p => p.Text("name").Length == 0 || p is not JsonObject obj || !obj.ContainsKey("value")))
                throw new InvalidOperationException("Saved Poll inputs do not match this project. Clear POLLING_TRIGGER_INPUTS and rerun setup.");
        }
        var existing = new Dictionary<string, JsonNode>(StringComparer.Ordinal);
        var page = $"{root}/triggerConfigs";
        while (page.Length > 0)
        {
            var result = await RestAsync("GET", page);
            foreach (var item in result["value"].Items()) existing[item.Text("name")] = item;
            page = result.Text("nextLink");
            if (page.Length > 0 && !page.StartsWith($"{root}/triggerConfigs?", StringComparison.Ordinal))
                throw new InvalidOperationException("Unsafe trigger-list continuation URL.");
        }
        var plan = new List<PlanItem>();
        var listenerSettings = new JsonObject();
        foreach (var definition in definitions.Items())
        {
            var trigger = triggers.Items().FirstOrDefault(t => t.Text("functionName") == definition.Text("functionName"));
            var setting = definition.Text("setting");
            if (setting.Length == 0) setting = $"{definition.Text("functionName")}TriggerConfigName";
            var name = example["Values"].Text(setting);
            if (!Regex.IsMatch(name, "^[a-z0-9-]+$")) throw new InvalidOperationException($"Missing safe trigger name for {setting}.");
            var properties = PropertiesFor(trigger ?? definition);
            existing.TryGetValue(name, out var resource);
            if (resource != null) AssertOwned(resource, properties);
            plan.Add(new(definition, trigger, name, properties, resource));
            listenerSettings[setting] = name;
            listenerSettings[$"AzureWebJobs.{definition.Text("functionName")}.Disabled"] = trigger == null ? "true" : "false";
        }
        if (plan.Select(p => p.Name).Distinct().Count() != plan.Count)
            throw new InvalidOperationException("Each Poll listener must use a distinct trigger config name.");
        if (phase == "prepare")
        {
            foreach (var item in plan.Where(p => p.Trigger == null && p.Resource != null && p.Resource["properties"].Text("state") != "Disabled"))
            {
                var url = $"{root}/triggerConfigs/{Json.Escape(item.Name)}";
                var current = await RestAsync("GET", url);
                AssertOwned(current, item.Properties);
                if (current["properties"].Text("state") == "Disabled") continue;
                var preserved = Json.Merge(current["properties"]);
                preserved.Remove("pollingEndpoints");
                preserved.Remove("provisioningState");
                preserved["state"] = "Disabled";
                await RestAsync("PUT", url, new JsonObject { ["properties"] = preserved });
                if ((await RestAsync("GET", url))["properties"].Text("state") != "Disabled")
                    throw new InvalidOperationException($"Could not disable skipped Poll config {item.Name}.");
                host.Log($"Disabled skipped Poll config {item.Name}.");
            }
            var changed = plan.Where(p => p.Trigger != null && !MatchesSelection(p.Resource, p.Properties)).ToList();
            var deploymentPlan = new JsonObject
            {
                ["selected"] = Json.Array(changed.Select(p => Json.Merge(new JsonObject { ["name"] = p.Name }, p.Trigger))),
                ["endpointConfigName"] = plan.First(p => p.Trigger != null).Name
            };
            if (changed.Count > 0) deploymentPlan["revision"] = Guid.NewGuid().ToString();
            await SaveAsync("POLLING_TRIGGER_INPUTS", Json.Encode(triggers));
            await SaveAsync("POLLING_TRIGGER_PLAN", Json.Encode(deploymentPlan));
            await SaveAsync("POLLING_TRIGGER_APP_SETTINGS", Json.Encode(listenerSettings));
            host.Log("Connection authorized. Preparing selected Poll triggers for provisioning.");
            return null;
        }
        if (outputs.Text("POLLING_TRIGGER_APP_SETTINGS").Length == 0
            || !JsonNode.DeepEquals(Json.Decode(outputs.Text("POLLING_TRIGGER_APP_SETTINGS")), listenerSettings))
            throw new InvalidOperationException("Poll listener settings are missing or stale. Rerun azd provision triggers.");
        string? endpoint = null;
        foreach (var item in plan)
        {
            if (item.Trigger == null)
            {
                if (item.Resource != null && item.Resource["properties"].Text("state") != "Disabled")
                    throw new InvalidOperationException($"Skipped Poll config {item.Name} is still enabled. Rerun azd provision triggers.");
                continue;
            }
            var created = item.Resource;
            for (var attempt = 0; !MatchesSelection(created, item.Properties) && !Failed(created) && attempt < 30; attempt++)
            {
                await host.WaitAsync(2000);
                created = await RestAsync("GET", $"{root}/triggerConfigs/{Json.Escape(item.Name)}");
                AssertOwned(created, item.Properties);
            }
            if (!MatchesSelection(created, item.Properties))
                throw new InvalidOperationException($"Poll source {item.Name} is not enabled with a usable receive URI. Check its source-registration status and permissions.");
            var actualEndpoint = PollingEndpoint(created.Get("properties/pollingEndpoints/receiveUri").Text());
            if (endpoint != null && endpoint != actualEndpoint)
                throw new InvalidOperationException("Selected Poll configs returned inconsistent namespace endpoints.");
            endpoint = actualEndpoint;
            host.Log($"Verified {item.Definition.Text("functionName")} is enabled for Poll delivery.");
        }
        if (outputs.Text("pollingEndpoint").Length == 0 || outputs.Text("pollingEndpoint") != endpoint)
            throw new InvalidOperationException("The trigger deployment returned an invalid polling endpoint. Rerun azd provision triggers.");
        if (phase == "verify")
        {
            var apps = JsonNode.Parse(await host.RunAsync("az", ["functionapp", "list", "-g", outputs.Text("resourceGroupName"),
                "--subscription", subscription, "--query", "[].name", "-o", "json"])) as JsonArray
                ?? throw new InvalidOperationException("Azure returned an invalid Function App listing.");
            await SaveAsync("POLLING_FUNCTION_APP_EXISTS", apps.Items().Any(a => a.Text() == outputs.Text("functionAppName")) ? "true" : "false");
        }
        listenerSettings["ConnectorNamespace__pollingEndpoint"] = endpoint;
        return listenerSettings;
    }

    async Task AuthenticateAsync(string phase, string url)
    {
        var connection = await RestAsync("GET", url);
        var display = config.Text("displayName");
        if (display.Length == 0) display = config.Text("connectorName");
        if (config.Text("authenticationType").Length > 0 && connection.Get("properties/parameterValueSet/name").Text() != config.Text("authenticationType"))
            throw new InvalidOperationException($"{display} requires a {config.Text("authenticationType")} connection. Recreate the connection with this project's template.");
        var managed = config.Text("authenticationType") == "managedIdentityAuth";
        bool Ready() => connection.Get("properties/overallStatus").Text().ToLowerInvariant() is "connected"
            || managed && connection.Get("properties/overallStatus").Text().Equals("ready", StringComparison.OrdinalIgnoreCase);
        if (!Ready() && phase != "prepare")
            throw new InvalidOperationException("The connection is no longer authorized. Complete consent and rerun azd provision triggers.");
        if (!Ready() && !managed)
        {
            host.Log($"Base resources are deployed. Completing {display} OAuth in your normal browser.");
            host.Log("Click Continue on the local sign-in page and complete consent. This terminal checks Azure every 10 seconds, even if the browser window does not update.");
            try
            {
                await host.RunAsync("az", ["connector-namespace", "connection", "authenticate", "-g", outputs.Text("resourceGroupName"),
                    "--namespace", outputs.Text("connectorNamespaceName"), "--connection-name", outputs.Text("connectorNamespaceConnectionName"),
                    "--subscription", subscription, "--timeout", "300", "--no-access-policy"], async () =>
                    {
                        try
                        {
                            connection = await RestAsync("GET", url);
                            if (Ready()) return true;
                            host.Log($"{display} OAuth: waiting for authorization (Azure status: {connection.Get("properties/overallStatus").Text()}). Complete consent in the browser.");
                        }
                        catch { host.Log($"{display} OAuth: unable to read Azure connection status; still waiting for the CLI. No success has been confirmed."); }
                        return false;
                    });
            }
            catch (Exception error)
            {
                throw new InvalidOperationException($"{display} authentication failed; base resources are already deployed. Resolve the browser or CLI error, then rerun azd provision triggers. This requires a connector-namespace extension with connection authenticate support.", error);
            }
            connection = await RestAsync("GET", url);
            if (!Ready()) throw new InvalidOperationException($"{display} connection is not Connected after authentication. Rerun azd provision triggers after resolving consent.");
        }
        if (managed && !Ready())
        {
            for (var attempt = 0; !Ready() && attempt < 100; attempt++)
            {
                await host.WaitAsync(3000);
                connection = await RestAsync("GET", url);
            }
            if (!Ready()) throw new InvalidOperationException("The managed-identity connection is not ready. Check namespace identity and source storage role assignments, then rerun azd provision triggers.");
        }
        if (phase == "prepare") host.Log(managed
            ? $"{display} managed-identity connection is ready. No browser consent is required."
            : $"{display} authentication confirmed: Azure connection is Connected. You can close the sign-in windows.");
    }

    async Task<JsonArray> SelectInputsAsync()
    {
        var selected = new List<JsonNode>();
        foreach (var definition in definitions.Items())
            if (await host.ConfirmAsync($"Configure {definition.Text("functionName")}?")) selected.Add(definition);
        if (selected.Count == 0) throw new InvalidOperationException("Select at least one polling trigger.");
        async Task<JsonNode> Request(JsonObject request)
        {
            var result = JsonNode.Parse(await host.RunAsync("az", ["connector-namespace", "connection", "invoke", "-g",
                outputs.Text("resourceGroupName"), "--namespace", outputs.Text("connectorNamespaceName"), "--connection-name",
                outputs.Text("connectorNamespaceConnectionName"), "--subscription", subscription, "--request", JsonFile(request), "-o", "json"]))!;
            var response = result["response"];
            if (response == null || response.Text("statusCode") is not ("200" or "201" or "OK" or "Created"))
                throw new InvalidOperationException("Connector picker failed. Check connection access and source permissions.");
            var body = response["body"];
            return body is JsonValue scalar && scalar.TryGetValue<string>(out var text)
                ? JsonNode.Parse(text)! : body.Copy()!;
        }
        var connector = config.Text("connectorName");
        var folder = connector == "onedriveforbusiness" ? await SelectOneDriveFolderAsync(Request, host) : null;
        JsonNode? swagger = null;
        TriggerInputs? collector = null;
        var result = new JsonArray();
        foreach (var definition in selected)
        {
            JsonNode? parameters = definition["parameters"];
            if (folder != null) parameters = new JsonArray(new JsonObject { ["name"] = "folderId", ["value"] = folder });
            if (connector == "azureblob")
            {
                if (outputs.Text("monitoredStorageAccountName").Length == 0 || outputs.Text("monitoredContainerName").Length == 0)
                    throw new InvalidOperationException("Missing provisioned Blob source outputs.");
                parameters = new JsonArray(
                    new JsonObject { ["name"] = "dataset", ["value"] = outputs.Text("monitoredStorageAccountName") },
                    new JsonObject { ["name"] = "folderId", ["value"] = Convert.ToBase64String(Encoding.UTF8.GetBytes(Json.Escape("/" + outputs.Text("monitoredContainerName")))) });
            }
            if (parameters != null)
            {
                result.Add(new JsonObject { ["functionName"] = definition.Text("functionName"), ["operationName"] = definition.Text("operationName"), ["parameters"] = parameters.Copy() });
                continue;
            }
            if (swagger == null)
            {
                var exported = JsonNode.Parse(await host.RunAsync("az", ["rest", "--method", "GET", "--url",
                    $"https://management.azure.com/subscriptions/{subscription}/providers/Microsoft.Web/locations/{Json.Escape(outputs.Text("CONNECTOR_NAMESPACE_LOCATION"))}/managedApis/{connector}",
                    "--url-parameters", $"api-version={(connector == "commondataservice" ? "2022-09-01-preview" : "2016-06-01")}", "export=true",
                    "--subscription", subscription, "-o", "json"]))!;
                swagger = exported.Get("properties/apiDefinitions/value") ?? exported;
                if (swagger is JsonValue value && value.TryGetValue<string>(out var text)) swagger = JsonNode.Parse(text)!;
                if (swagger["paths"] is not JsonObject) throw new InvalidOperationException("The connector exported no operation metadata.");
                var cache = new Dictionary<string, JsonNode>();
                collector = new TriggerInputs(swagger, async (id, values) =>
                {
                    var key = id + values.ToJsonString();
                    if (!cache.TryGetValue(key, out var body))
                    {
                        body = await Request(TriggerInputs.OperationRequest(swagger, id, values, connector == "commondataservice"));
                        cache[key] = body;
                    }
                    return body;
                }, host, connector);
            }
            var trigger = await collector!.CollectAsync(definition);
            if (trigger != null) result.Add(trigger);
        }
        return result;
    }

    public static async Task<string> SelectOneDriveFolderAsync(Func<JsonObject, Task<JsonNode>> request, SetupHost host)
    {
        var stack = new List<JsonNode>();
        while (true)
        {
            var current = stack.LastOrDefault();
            var response = await request(new JsonObject
            {
                ["method"] = "GET",
                ["path"] = current == null
                ? "/datasets/default/folders" : $"/datasets/default/foldersV2/{Json.Escape(Json.Escape(current.Text("Id")))}"
            });
            var items = response as JsonArray ?? response["value"] as JsonArray
                ?? throw new InvalidOperationException("The OneDrive connector returned an invalid folder listing.");
            var choices = new List<Choice>();
            if (current != null) { choices.Add(new($"Use {current.Text("Name")}", JsonValue.Create("select"))); choices.Add(new("Parent folder", JsonValue.Create("up"))); }
            choices.AddRange(items.Items().Where(i => i.Flag("IsFolder") && i["Id"] is JsonValue id && id.TryGetValue<string>(out var text) && text.Length > 0 && text != "root")
                .Select(i => new Choice(i.Text("Name"), i)));
            if (choices.Count == 0) throw new InvalidOperationException("No OneDrive folders are available. Create a test folder and rerun setup.");
            var selected = await host.ChooseAsync("Select the OneDrive folder to monitor", choices);
            if (selected.Text() == "select") return current!.Text("Id");
            if (selected.Text() == "up") stack.RemoveAt(stack.Count - 1);
            else stack.Add(selected!);
        }
    }

    JsonObject PropertiesFor(JsonNode trigger) => new()
    {
        ["connectionDetails"] = new JsonObject { ["connectorName"] = config.Text("connectorName"), ["connectionName"] = outputs.Text("connectorNamespaceConnectionName") },
        ["deliveryMode"] = "Poll",
        ["operationName"] = trigger.Text("operationName"),
        ["parameters"] = trigger["parameters"].Copy() ?? new JsonArray(),
        ["metadata"] = new JsonObject
        {
            ["destinationType"] = "functionApp",
            ["functionAppSubscriptionId"] = subscription,
            ["functionAppResourceGroup"] = outputs.Text("resourceGroupName"),
            ["functionAppName"] = outputs.Text("functionAppName"),
            ["functionName"] = trigger.Text("functionName")
        }
    };
    static void AssertOwned(JsonNode resource, JsonObject expected)
    {
        var actual = resource["properties"];
        if (actual.Text("deliveryMode") != "Poll" || actual.Text("operationName") != expected.Text("operationName")
            || actual.Get("connectionDetails/connectorName").Text() != expected.Get("connectionDetails/connectorName").Text()
            || actual.Get("connectionDetails/connectionName").Text() != expected.Get("connectionDetails/connectionName").Text()
            || expected["metadata"].Fields().Any(pair => actual.Get("metadata").Text(pair.Key) != pair.Value.Text()))
            throw new InvalidOperationException($"Refusing to overwrite an unowned or webhook trigger: {resource.Text("name")}.");
    }
    static bool Failed(JsonNode? resource) => resource.Get("properties/provisioningState").Text() is "Failed" or "Canceled" or "Cancelled";
    static bool MatchesSelection(JsonNode? resource, JsonNode expected) =>
        resource.Get("properties/state").Text() == "Enabled" && !Failed(resource)
        && resource.Get("properties/pollingEndpoints/receiveUri").Text().Length > 0
        && JsonNode.DeepEquals(Json.Array(resource.Get("properties/parameters").Items().OrderBy(p => p.Text("name"), StringComparer.Ordinal)),
            Json.Array(expected["parameters"].Items().OrderBy(p => p.Text("name"), StringComparer.Ordinal)));
    string JsonFile(JsonNode value)
    {
        var path = Path.Combine(temporary, $"{requestNumber++}.json");
        using var stream = PrivateFiles.Create(path);
        using var writer = new StreamWriter(stream, new UTF8Encoding(false));
        writer.Write(value.ToJsonString());
        return "@" + path;
    }
    async Task<JsonNode> RestAsync(string method, string url, JsonNode? body = null)
    {
        if (!url.Contains("api-version=", StringComparison.Ordinal))
            url += (url.Contains('?') ? "&" : "?") + $"api-version={ApiVersion}";
        var args = new List<string> { "rest", "--method", method, "--url", url };
        if (body != null) { args.Add("--body"); args.Add(JsonFile(body)); }
        args.AddRange(["--subscription", subscription, "-o", "json"]);
        var text = await host.RunAsync("az", args);
        return text.Length == 0 ? new JsonObject() : JsonNode.Parse(text)!;
    }
    Task<string> SaveAsync(string key, string value) => host.RunAsync("azd", ["env", "set", key, value]);
    record PlanItem(JsonNode Definition, JsonNode? Trigger, string Name, JsonObject Properties, JsonNode? Resource);
}

public sealed class TriggerInputs(JsonNode swagger, Func<string, JsonObject, Task<JsonNode>> invoke, SetupHost host, string connector = "")
{
    readonly bool dataverse = connector == "commondataservice";
    readonly bool sharepoint = connector == "sharepointonline";
    string bodyName = "body";
    sealed class SkipTrigger(string label) : Exception(label);
    record Operation(string Route, string Method, List<JsonNode> Parameters);

    static JsonNode Resolve(JsonNode swagger, JsonNode schema, int depth = 0)
    {
        if (depth > 64) throw new InvalidOperationException("Cyclic or excessively deep schema reference.");
        var reference = schema.Text("$ref");
        if (reference.Length == 0) return schema;
        if (!reference.StartsWith("#/", StringComparison.Ordinal)) throw new InvalidOperationException($"Unsupported external schema reference: {reference}");
        JsonNode? target = swagger;
        foreach (var part in reference[2..].Split('/'))
            target = target is JsonObject obj ? obj[part.Replace("~1", "/").Replace("~0", "~")] : null;
        if (target == null) throw new InvalidOperationException($"Missing schema reference: {reference}");
        var overrides = Json.Merge(schema);
        overrides.Remove("$ref");
        return Json.Merge(Resolve(swagger, target, depth + 1), overrides);
    }
    static Operation FindOperation(JsonNode swagger, string id)
    {
        foreach (var (route, methods) in swagger["paths"].Fields())
            foreach (var (method, definition) in methods.Fields())
                if (definition is JsonObject && definition.Text("operationId") == id)
                    return new(route, method, methods.Get("parameters").Items().Concat(definition["parameters"].Items()).Select(p => Resolve(swagger, p)).ToList());
        throw new InvalidOperationException($"The connector does not expose {id} in this region.");
    }
    public static JsonObject OperationRequest(JsonNode swagger, string id, JsonObject values, bool useDefaults = false)
    {
        var op = FindOperation(swagger, id);
        var request = new JsonObject { ["method"] = op.Method.ToUpperInvariant(), ["path"] = Regex.Replace(op.Route, @"^/\{connectionId\}", "") };
        foreach (var parameter in op.Parameters)
        {
            var name = parameter.Text("name");
            if (name == "connectionId") continue;
            var supplied = values.ContainsKey(name);
            var value = supplied ? values[name] : useDefaults ? parameter["default"] : null;
            if (!supplied && value == null)
            {
                if (parameter.Flag("required")) throw new InvalidOperationException($"{id} requires {name}.");
                continue;
            }
            var location = parameter.Text("in");
            if (location == "path")
            {
                var encoded = Json.Escape(value.Text());
                if (parameter.Text("x-ms-url-encoding") == "double") encoded = Json.Escape(encoded);
                request["path"] = request.Text("path").Replace("{" + name + "}", encoded);
            }
            else if (location is "query" or "header")
            {
                var key = location == "query" ? "queries" : "headers";
                request[key] ??= new JsonObject();
                request[key]![name] = value.Copy();
            }
            else if (location == "body") request["body"] = value.Copy();
        }
        if (Regex.IsMatch(request.Text("path"), @"\{[^}]+\}")) throw new InvalidOperationException($"Unresolved path parameters for {id}.");
        return request;
    }
    static JsonNode DynamicSpec(JsonNode extension) => extension.Text("operationId").Length > 0 ? extension
        : Json.Merge(extension, extension.Get("dynamicState/extension") ?? extension["dynamicState"]);

    List<string> References(JsonNode input, int depth = 0)
    {
        if (depth > 64) throw new InvalidOperationException("Cyclic or excessively deep input schema.");
        var schema = Resolve(swagger, input);
        var result = new List<string>();
        foreach (var extension in new[] { schema["x-ms-dynamic-schema"], schema["x-ms-dynamic-values"], schema["x-ms-dynamic-list"],
            sharepoint ? schema.Get("x-ms-dynamic-tree/open") : null, sharepoint ? schema.Get("x-ms-dynamic-tree/browse") : null })
            if (extension != null)
                foreach (var binding in DynamicSpec(extension)["parameters"].Fields().Select(p => p.Value))
                {
                    var reference = binding.Get("parameter") ?? binding.Get("parameterReference");
                    if (reference != null) result.Add(reference.Text());
                }
        if (schema["items"] != null) result.AddRange(References(schema["items"]!, depth + 1));
        var properties = schema["properties"];
        var refs = properties.Fields().ToDictionary(p => p.Key, p => References(p.Value!, depth + 1));
        if (dataverse)
        {
            var dependencies = refs.ToDictionary(p => p.Key, p => p.Value.Select(r => r.Split(['/', '.']).FirstOrDefault(k => refs.ContainsKey(k)))
                .Where(k => k != null && k != p.Key).Select(k => k!).ToHashSet());
            foreach (var key in RequiredDependencies(dependencies, properties.Fields().Where(p => Required(schema, p.Key, p.Value!)).Select(p => p.Key)))
                result.AddRange(refs[key]);
        }
        else foreach (var value in refs.Values) result.AddRange(value);
        return result;
    }
    static HashSet<string> RequiredDependencies(Dictionary<string, HashSet<string>> dependencies, IEnumerable<string> names)
    {
        var required = names.ToHashSet();
        var queue = new Queue<string>(required);
        while (queue.TryDequeue(out var name))
            if (dependencies.TryGetValue(name, out var keys))
                foreach (var key in keys) if (required.Add(key)) queue.Enqueue(key);
        return required;
    }
    bool Required(JsonNode schema, string key, JsonNode field) =>
        schema["required"].Items().Any(k => k.Text() == key) || Resolve(swagger, field).Flag("required");
    JsonNode? Answer(JsonObject answers, string path)
    {
        var parts = path.Split(['/', '.'], StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length > 0 && parts[0] == bodyName && bodyName != "body") parts[0] = "body";
        return answers.Get(string.Join('/', parts));
    }
    async Task<JsonNode> DynamicAsync(JsonNode extension, JsonObject answers, JsonNode? selected = null)
    {
        extension = DynamicSpec(extension);
        var id = extension.Text("operationId");
        if (id.Length == 0) throw new InvalidOperationException("The connector picker has no operation ID.");
        var parameters = new JsonObject();
        foreach (var (key, binding) in extension["parameters"].Fields())
        {
            var reference = (binding.Get("parameter") ?? binding.Get("parameterReference")).Text();
            JsonNode? value;
            if (reference.Length > 0)
            {
                value = Answer(answers, reference) ?? answers["body"].Get(reference);
                if (value == null) throw new InvalidOperationException($"Select {reference} before resolving {id}.");
            }
            else if (binding.Get("selectedItemValuePath") != null)
                value = selected.Get(binding.Text("selectedItemValuePath"));
            else value = binding is JsonObject obj && obj.ContainsKey("value") ? obj["value"] : binding;
            if (value == null) throw new InvalidOperationException($"Missing picker parameter {key} for {id}.");
            parameters[key] = value.Copy();
        }
        return await invoke(id, parameters);
    }

    async Task<JsonNode?> CollectValueAsync(JsonNode input, string label, JsonObject answers, string[] path, bool required = true, bool manual = false)
    {
        var schema = Resolve(swagger, input);
        var supplied = Answer(answers, string.Join('/', path));
        if (supplied != null && (!dataverse || schema.Text("type") != "object" && schema["properties"] == null)) return supplied.Copy();
        if (!required)
        {
            if (dataverse) return (supplied ?? schema["default"]).Copy();
            if (!await host.ConfirmAsync($"Configure {label} (optional)?")) return null;
        }
        if (dataverse && supplied == null && schema["default"] != null) return schema["default"].Copy();
        if (schema["x-ms-dynamic-schema"] is JsonNode dynamicSchema)
        {
            var extension = DynamicSpec(dynamicSchema);
            var resolved = (await DynamicAsync(extension, answers)).Get((extension["value-path"] ?? extension["valuePath"]).Text());
            if (resolved is not JsonObject) throw new InvalidOperationException($"No schema returned for {label}.");
            schema = Json.Merge(schema, Resolve(swagger, resolved));
            schema.AsObject().Remove("x-ms-dynamic-schema");
        }
        if (schema.Text("type") == "array")
        {
            var items = new JsonArray();
            var itemSchema = Json.Merge(schema["items"]);
            foreach (var key in new[] { "x-ms-dynamic-values", "x-ms-dynamic-list" })
                if (schema[key] != null) itemSchema[key] = schema[key].Copy();
            var minimum = (int)(schema.Number("minItems") ?? 1);
            var maximum = schema.Number("maxItems") ?? double.PositiveInfinity;
            if (dataverse)
            {
                while (items.Count < minimum) items.Add(await CollectValueAsync(itemSchema, $"{label} ({items.Count + 1})", answers, [.. path, items.Count.ToString(CultureInfo.InvariantCulture)]));
            }
            else
            {
                do { items.Add(await CollectValueAsync(itemSchema, $"{label} ({items.Count + 1})", answers, [.. path, items.Count.ToString(CultureInfo.InvariantCulture)])); }
                while (items.Count < minimum || items.Count < maximum && (await host.ChooseAsync($"Add another {label}?",
                    [new("No", JsonValue.Create(false)), new("Yes", JsonValue.Create(true))])).Flag());
            }
            return items;
        }
        var values = schema["x-ms-dynamic-values"] ?? schema["x-ms-dynamic-list"];
        if (values != null)
        {
            var extension = DynamicSpec(values);
            if (sharepoint && schema["x-ms-dynamic-tree"] != null && extension.Text("capability") == "file-picker"
                && extension.Get("parameters/isFolder").Flag())
                return await SelectFolderAsync(schema["x-ms-dynamic-tree"]!, label, answers, required);
            var response = await DynamicAsync(extension, answers);
            var items = response.Get((extension["value-collection"] ?? extension["valueCollection"] ?? extension["itemsPath"]).Text()) as JsonArray
                ?? throw new InvalidOperationException($"Invalid picker response for {label}; expected an array of choices.");
            var choices = new List<Choice>();
            foreach (var item in items.Items())
            {
                var value = item.Get((extension["value-path"] ?? extension["valuePath"] ?? extension["itemValuePath"]).Text());
                var title = item.Get((extension["value-title"] ?? extension["valueTitle"] ?? extension["itemTitlePath"]).Text());
                if (dataverse)
                {
                    if (value is not JsonValue || value.Text().Length == 0 && string.IsNullOrWhiteSpace(title.Text())) continue;
                    choices.Add(new(string.IsNullOrWhiteSpace(title.Text()) ? value.Text() : title.Text(), value));
                }
                else
                {
                    if (value == null || title == null) throw new InvalidOperationException($"Invalid picker response for {label}.");
                    choices.Add(new(title.Text(), value));
                }
            }
            if (choices.Count == 0)
            {
                if (dataverse || sharepoint && manual)
                {
                    host.Log($"No usable choices returned for {label}. Enter the connector identifier manually, or leave blank to skip this trigger.");
                    var value = await host.PromptAsync(label, schema, allowEmpty: true);
                    if (value == null || string.IsNullOrWhiteSpace(value.Text())) throw new SkipTrigger(label);
                    return value.Copy();
                }
                if (sharepoint) return null;
                throw new InvalidOperationException($"No choices returned for {label}.");
            }
            return await host.ChooseAsync(label, choices);
        }
        if (schema["enum"] is JsonArray enums)
            return await host.ChooseAsync(label, enums.Items().Select(value =>
                new Choice(schema["x-ms-enum-values"].Items().FirstOrDefault(item => JsonNode.DeepEquals(item["value"], value))?.Text("displayName") ?? value.Text(), value)).ToList());
        if (schema.Text("type") == "object" || schema["properties"] != null)
        {
            var result = dataverse && supplied is JsonObject ? Json.Merge(supplied) : new JsonObject();
            SetObject(answers, path, result);
            var properties = schema["properties"];
            var names = properties.Fields().Select(p => p.Key).ToList();
            var dependencies = properties.Fields().ToDictionary(p => p.Key, p => References(p.Value!).Select(reference =>
            {
                var parts = reference.Split(['/', '.'], StringSplitOptions.RemoveEmptyEntries);
                for (var i = 0; i < parts.Length; i++)
                    if (names.Contains(parts[i]) && (i == 0 || ReferenceEquals(Answer(answers, string.Join('/', parts.Take(i))), result)))
                        return parts[i] != p.Key ? parts[i] : null;
                return null;
            }).Where(k => k != null).Select(k => k!).ToHashSet());
            var requiredNames = dataverse
                ? RequiredDependencies(dependencies, names.Where(k => Required(schema, k, properties![k]!)))
                : dependencies.Values.SelectMany(d => d).Concat(names.Where(k => Required(schema, k, properties![k]!))).ToHashSet();
            while (names.Count > 0)
            {
                var key = names.FirstOrDefault(k => dataverse && !requiredNames.Contains(k) || dependencies[k].All(d => !names.Contains(d)))
                    ?? throw new InvalidOperationException($"Cyclic picker dependencies for {label}.");
                names.Remove(key);
                var field = Resolve(swagger, properties![key]!);
                if (field.Flag("x-ms-notification-url") || field.Flag("readOnly")) continue;
                if (field.Text("x-ms-visibility") == "internal")
                {
                    if (field["default"] != null) result[key] = field["default"].Copy();
                    continue;
                }
                var value = await CollectValueAsync(field, (field["x-ms-summary"] ?? field["title"])?.Text() ?? key, answers, [.. path, key], requiredNames.Contains(key));
                if (value != null) result[key] = value.Copy();
            }
            return result.Copy();
        }
        if (schema.Text("type") == "boolean")
            return await host.ChooseAsync(label, [new("Yes", JsonValue.Create(true)), new("No", JsonValue.Create(false))]);
        if (schema.Text("type") is not ("string" or "integer" or "number"))
            throw new InvalidOperationException($"Unsupported input schema for {label}; no trigger will be created with guessed values.");
        return await host.PromptAsync(label, schema);
    }

    static void SetObject(JsonObject answers, string[] path, JsonObject result)
    {
        JsonNode parent = answers;
        foreach (var key in path[..^1])
        {
            if (parent is JsonArray array)
            {
                var i = int.Parse(key, CultureInfo.InvariantCulture);
                while (array.Count <= i) array.Add(null);
                array[i] ??= new JsonObject();
                parent = array[i]!;
            }
            else { parent[key] ??= new JsonObject(); parent = parent[key]!; }
        }
        if (parent is JsonArray list)
        {
            var i = int.Parse(path[^1], CultureInfo.InvariantCulture);
            while (list.Count <= i) list.Add(null);
            list[i] = result;
        }
        else parent[path[^1]] = result;
    }
    async Task<JsonNode?> SelectFolderAsync(JsonNode tree, string label, JsonObject answers, bool required)
    {
        var stack = new List<(JsonNode Item, JsonNode Extension)>();
        while (true)
        {
            var extension = stack.Count > 0 ? tree["browse"]! : tree["open"]!;
            var response = await DynamicAsync(extension, answers, stack.Count > 0 ? stack[^1].Item : null);
            var items = response as JsonArray ?? response["value"] as JsonArray
                ?? throw new InvalidOperationException($"Invalid folder listing for {label}.");
            if (items.Items().Any(i => i["IsFolder"] is not JsonValue flag || !flag.TryGetValue<bool>(out _)))
                throw new InvalidOperationException($"Invalid folder listing for {label}.");
            var folders = items.Items().Where(i => i.Flag("IsFolder")).ToList();
            if (folders.Any(i => i.Text("Id").Length == 0 || i.Get(extension.Text("itemValuePath")).Text().Length == 0
                || i.Get(extension.Text("itemTitlePath")).Text().Length == 0))
                throw new InvalidOperationException($"Invalid folder picker response for {label}.");
            if (stack.Count == 0 && folders.Count == 0) return null;
            var choices = new List<Choice>();
            if (stack.Count > 0)
            {
                var current = stack[^1];
                choices.Add(new($"Use {current.Item.Get((current.Extension["itemFullTitlePath"] ?? current.Extension["itemTitlePath"]).Text()).Text()}", JsonValue.Create("select")));
                choices.Add(new("Parent folder", JsonValue.Create("up")));
            }
            if (!required) choices.Add(new("No folder filter (whole library)", JsonValue.Create("skip")));
            choices.AddRange(folders.Select(item => new Choice(item.Get(extension.Text("itemTitlePath")).Text(), item)));
            var selected = await host.ChooseAsync(label, choices);
            if (selected.Text() == "select") return stack[^1].Item.Get(stack[^1].Extension.Text("itemValuePath")).Copy();
            if (selected.Text() == "skip") return null;
            if (selected.Text() == "up") stack.RemoveAt(stack.Count - 1);
            else stack.Add((selected!, extension));
        }
    }

    public async Task<JsonObject?> CollectAsync(JsonNode definition)
    {
        host.Log($"\n{definition.Text("functionName")} ({definition.Text("operationName")})");
        try
        {
            var parameters = FindOperation(swagger, definition.Text("operationName")).Parameters;
            var body = parameters.FirstOrDefault(p => p.Text("in") == "body");
            bodyName = body?.Text("name") ?? "body";
            var answers = Json.Merge(definition["values"]);
            var remaining = parameters.Where(p => p.Text("name") != "connectionId"
                && (p.Text("in") is "path" or "query" || dataverse && p.Text("in") == "header")
                && p.Text("x-ms-visibility") != "internal" && !p.Flag("readOnly")).ToList();
            var dependencies = remaining.ToDictionary(p => p.Text("name"), p => References(p).Select(r => r.Split(['/', '.'])[0])
                .Where(n => n != p.Text("name")).ToHashSet());
            var required = dataverse
                ? RequiredDependencies(dependencies, remaining.Where(p => p.Flag("required")).Select(p => p.Text("name"))
                    .Concat(body?.Flag("required") == true ? References(body["schema"]!).Select(r => r.Split(['/', '.'])[0]).Where(dependencies.ContainsKey) : []))
                : dependencies.Values.SelectMany(d => d).Concat(remaining.Where(p => p.Flag("required")).Select(p => p.Text("name"))).ToHashSet();
            var result = new JsonArray();
            while (remaining.Count > 0)
            {
                var parameter = remaining.FirstOrDefault(p => dataverse && !required.Contains(p.Text("name"))
                    || dependencies[p.Text("name")].All(d => remaining.All(other => other.Text("name") != d)))
                    ?? throw new InvalidOperationException($"Cyclic picker dependencies for {definition.Text("operationName")}.");
                remaining.Remove(parameter);
                var name = parameter.Text("name");
                var picker = parameter["x-ms-dynamic-values"] ?? parameter["x-ms-dynamic-list"];
                var manual = sharepoint && name == "table" && picker != null && DynamicSpec(picker).Text("operationId") == "GetTables";
                var value = await CollectValueAsync(parameter, parameter["x-ms-summary"]?.Text() ?? name, answers, [name], required.Contains(name), manual);
                if (sharepoint && value == null && required.Contains(name)) throw new SkipTrigger(name);
                if (value != null)
                {
                    answers[name] = value.Copy();
                    result.Add(new JsonObject { ["name"] = name, ["value"] = value.Copy() });
                }
            }
            if (body != null)
            {
                var value = await CollectValueAsync(body["schema"]!, "Subscription details", answers, ["body"], !dataverse || body.Flag("required"));
                var hasValues = value is JsonObject obj && obj.Count > 0
                    || value is JsonArray array && array.Count > 0
                    || value is JsonValue scalar && scalar.TryGetValue<string>(out var text) && text.Length > 0;
                if (value != null && (dataverse && body.Flag("required") || hasValues))
                    result.Add(new JsonObject { ["name"] = "body", ["value"] = value.Copy() });
            }
            return new JsonObject { ["functionName"] = definition.Text("functionName"), ["operationName"] = definition.Text("operationName"), ["parameters"] = result };
        }
        catch (SkipTrigger error)
        {
            host.Log($"Skipped {definition.Text("functionName")}: no value available for {error.Message}.");
            return null;
        }
    }
}
