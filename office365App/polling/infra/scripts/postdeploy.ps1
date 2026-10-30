param(
    [switch] $ForceLocalSettings,
    [switch] $ConsentLinkOnly
)

$ErrorActionPreference = 'Stop'

if (-not (az extension show --name connector-namespace --query name -o tsv 2>$null)) {
    throw "Install the connector-namespace Azure CLI extension before running this script."
}

$raw = azd env get-values --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected azd environment.' }
$outputs = ($raw -join "`n") | ConvertFrom-Json

foreach ($name in @(
    'resourceGroupName', 'connectorNamespaceName', 'connectorNamespaceConnectionName',
    'connectorPollingEndpoint', 'triggerConfigSettings')) {
    if ([string]::IsNullOrWhiteSpace([string]$outputs.$name)) {
        throw "Missing azd output $name. Run azd provision first."
    }
}

# azd serializes object-valued deployment outputs as JSON environment values.
$triggerSettings = if ($outputs.triggerConfigSettings -is [string]) {
    $outputs.triggerConfigSettings | ConvertFrom-Json
} else {
    $outputs.triggerConfigSettings
}

$localValues = @{
    AzureWebJobsStorage = 'UseDevelopmentStorage=true'
    FUNCTIONS_WORKER_RUNTIME = 'dotnet-isolated'
    ConnectorNamespace__pollingEndpoint = $outputs.connectorPollingEndpoint
}
foreach ($functionName in @(
    'OnNewEmail', 'OnFlaggedEmail', 'OnNewMentionMeEmail', 'OnNewCalendarEvent', 'OnUpcomingEvent',
    'OnCalendarUpdatedItems', 'OnSharedMailboxNewEmail')) {
    $setting = "${functionName}TriggerConfigName"
    if ([string]::IsNullOrWhiteSpace($triggerSettings.$setting)) {
        throw "Missing trigger configuration setting $setting."
    }
    $localValues[$setting] = $triggerSettings.$setting
}
$localValues['AzureWebJobs.OnSharedMailboxNewEmail.Disabled'] =
    ([string]::IsNullOrWhiteSpace($outputs.office365SharedMailboxAddress)).ToString().ToLowerInvariant()

$localSettingsPath = Join-Path $PSScriptRoot '../../local.settings.json'
if ((Test-Path -LiteralPath $localSettingsPath) -and -not $ForceLocalSettings) {
    Write-Host 'Existing local.settings.json preserved. Use -ForceLocalSettings to regenerate it.'
}
else {
    $localSettings = @{ IsEncrypted = $false; Values = $localValues }
    [IO.File]::WriteAllText(
        $localSettingsPath,
        ($localSettings | ConvertTo-Json -Depth 4),
        [Text.UTF8Encoding]::new($false))
    Write-Host 'Created ignored local.settings.json using developer credentials and Azurite.'
}

function Get-ConnectionStatus {
    $status = az connector-namespace connection show `
        -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName `
        -n $outputs.connectorNamespaceConnectionName `
        --query 'properties.overallStatus' -o tsv
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the Office 365 connection status.' }
    return $status
}

if ((Get-ConnectionStatus) -eq 'Connected') {
    Write-Host 'Office 365 connection is already authorized.'
    return
}

Write-Host 'Authorize the Office 365 connection with the mailbox account to monitor.'
$consentLink = $null
for ($attempt = 1; $attempt -le 5; $attempt++) {
    $consentLink = az connector-namespace connection list-consent-links `
        -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName `
        --connection-name $outputs.connectorNamespaceConnectionName `
        --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" `
        --query 'value[0].link' -o tsv 2>$null

    if (-not $consentLink -or $consentLink -eq 'null') {
        $consentLink = az connector-namespace connection list-consent-links `
            -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName `
            --connection-name $outputs.connectorNamespaceConnectionName `
            --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" `
            --query 'link' -o tsv 2>$null
    }
    if ($consentLink -and $consentLink -ne 'null') { break }
    if ($attempt -lt 5) { Start-Sleep -Seconds 5 }
}

if (-not $consentLink -or $consentLink -eq 'null') {
    throw 'Could not obtain an Office 365 consent link.'
}

Write-Host "Consent URL: $consentLink"
if ($ConsentLinkOnly -or $outputs.office365TriggerState -eq 'Disabled') { return }
try {
    Start-Process $consentLink | Out-Null
} catch {
    Write-Host 'Open the consent URL in your browser.'
}

$deadline = (Get-Date).AddMinutes(5)
do {
    Start-Sleep -Seconds 3
    if ((Get-ConnectionStatus) -eq 'Connected') {
        Write-Host 'Office 365 connection authorized. Poll trigger configurations are provisioned (shared mailbox is opt-in).'
        return
    }
} while ((Get-Date) -lt $deadline)

throw 'Timed out waiting for the Office 365 connection to become Connected.'
