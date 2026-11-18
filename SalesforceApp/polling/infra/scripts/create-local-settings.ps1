param([string] $PollingEndpoint)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-settings.ps1')
$target = Join-Path $PSScriptRoot '..\..\local.settings.json'
if (Test-LocalSettingsFile $target) {
    Write-Host 'Existing local.settings.json preserved.'
    return
}
if ([string]::IsNullOrWhiteSpace($PollingEndpoint)) {
    $raw = azd env get-values --output json
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected azd environment.' }
    $PollingEndpoint = (($raw -join "`n") | ConvertFrom-Json).connectorPollingEndpoint
}
$uri = $null
if (-not [Uri]::TryCreate($PollingEndpoint, [UriKind]::Absolute, [ref] $uri) -or
    $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
    $uri.AbsolutePath -notmatch '^/(api/connectorGateways/[^/]+/?)?$') {
    throw 'Missing or invalid gateway-level connectorPollingEndpoint. Provision the Poll trigger configurations first.'
}
$settings = @{
    IsEncrypted = $false
    Values = @{
        AzureWebJobsStorage = 'UseDevelopmentStorage=true'
        FUNCTIONS_WORKER_RUNTIME = 'dotnet-isolated'
        ConnectorNamespace__pollingEndpoint = $PollingEndpoint
        OnNewRecordTriggerConfigName = 'salesforce-onnewrecord'
        OnUpdatedRecordTriggerConfigName = 'salesforce-onupdatedrecord'
    }
}
Write-LocalSettings $target $settings
