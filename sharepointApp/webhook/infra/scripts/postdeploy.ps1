param(
    [string] $CallbackBaseUrl,
    [string] $ConnectorExtensionKey
)

$ErrorActionPreference = 'Stop'

if ($CallbackBaseUrl -and (
    -not $CallbackBaseUrl.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase) -or
    [string]::IsNullOrWhiteSpace($ConnectorExtensionKey))) {
    throw 'Local callbacks require a public HTTPS CallbackBaseUrl and the local ConnectorExtensionKey.'
}
if ($ConnectorExtensionKey -and -not $CallbackBaseUrl) {
    throw 'CallbackBaseUrl is required when supplying ConnectorExtensionKey.'
}

Write-Host "Post-deployment configuration..." -ForegroundColor Yellow

if (-not (az extension show --name connector-namespace --query name -o tsv 2>$null)) {
    Write-Host "ERROR: The 'connector-namespace' Azure CLI extension is required." -ForegroundColor Red
    Write-Host "Install: irm https://aka.ms/connector-namespace-cli-install-ps | iex" -ForegroundColor Red
    exit 1
}

$outputs = azd env get-values --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected azd environment.' }

$resourceGroupName = $outputs.resourceGroupName
$connectorNamespaceName = $outputs.connectorNamespaceName
$connectorNamespaceConnectionName = $outputs.connectorNamespaceConnectionName
$functionAppName = $outputs.functionAppName
$functionAppHostname = $outputs.functionAppDefaultHostname
$subscriptionId = $outputs.AZURE_SUBSCRIPTION_ID
$sharepointSiteUrl = $outputs.sharepointSiteUrl
$sharepointLibraryName = $outputs.sharepointLibraryName

if (-not $resourceGroupName -or -not $connectorNamespaceName -or -not $connectorNamespaceConnectionName -or -not $functionAppName -or -not $sharepointSiteUrl -or -not $sharepointLibraryName) {
    Write-Host "ERROR: required azd outputs missing. Run 'azd provision' first." -ForegroundColor Red
    exit 1
}

$triggerConfigs = if ($outputs.triggerDefinitions -is [string]) {
    $outputs.triggerDefinitions | ConvertFrom-Json
} else {
    $outputs.triggerDefinitions
}
if (-not $triggerConfigs -or $triggerConfigs.Count -ne 10) {
    throw 'Missing or incomplete triggerDefinitions output. Run azd provision first.'
}
$existingTriggers = az connector-namespace trigger list `
    -g $resourceGroupName --namespace $connectorNamespaceName --query '[].name' -o json
if ($LASTEXITCODE -ne 0) { throw 'Could not list existing SharePoint trigger configurations.' }
$existingNames = ($existingTriggers -join "`n") | ConvertFrom-Json

if (-not $CallbackBaseUrl) {
    Write-Host "Fetching connector extension key for $functionAppName..." -ForegroundColor Cyan
    $ConnectorExtensionKey = az functionapp keys list -g $resourceGroupName -n $functionAppName --query "systemKeys.connector_extension" -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ConnectorExtensionKey)) {
        throw 'Could not retrieve the connector_extension system key. Deploy the function first.'
    }
    $CallbackBaseUrl = "https://$functionAppHostname"
}
$CallbackBaseUrl = $CallbackBaseUrl.TrimEnd('/')

Write-Host "Creating Connector Namespace trigger configs..." -ForegroundColor Yellow
Write-Host "  SharePoint site: $sharepointSiteUrl" -ForegroundColor Cyan
Write-Host "  Library: $sharepointLibraryName" -ForegroundColor Cyan

foreach ($trigger in $triggerConfigs) {
    $functionName = $trigger.FunctionName
    $triggerName = "$connectorNamespaceConnectionName-$($functionName.ToLowerInvariant())"
    if (-not $trigger.enabled) {
        if ($triggerName -in $existingNames) {
            az connector-namespace trigger update `
                -g $resourceGroupName --namespace $connectorNamespaceName `
                -n $triggerName --state Disabled -o none
            if ($LASTEXITCODE -ne 0) { throw "Could not disable trigger $triggerName." }
        }
        Write-Host "  Skipping opt-in trigger: $functionName"
        continue
    }
    $callbackUrl = "$CallbackBaseUrl/runtime/webhooks/connector?functionName=$functionName"
    $notifFile = Join-Path $PSScriptRoot ".notification-details-$([System.Guid]::NewGuid().ToString('N')).json"
    $paramsFile = Join-Path $PSScriptRoot ".trigger-parameters-$([System.Guid]::NewGuid().ToString('N')).json"
    Write-Host "  Creating trigger: $($trigger.FunctionName) -> $($trigger.OperationName)" -ForegroundColor Cyan

    try {
        @{
            callbackUrl = $callbackUrl
            authentication = @{
                type = "QueryString"
                name = "code"
                value = $connectorExtensionKey
            }
        } | ConvertTo-Json -Depth 3 -Compress | Set-Content -LiteralPath $notifFile -NoNewline
        ConvertTo-Json -InputObject @($trigger.parameters) -Depth 4 -Compress |
            Set-Content -LiteralPath $paramsFile -NoNewline

        if ($triggerName -in $existingNames) {
            az connector-namespace trigger delete `
                -g $resourceGroupName --namespace $connectorNamespaceName `
                -n $triggerName --yes -o none
            if ($LASTEXITCODE -ne 0) { throw "Could not replace trigger $triggerName." }
        }

        az connector-namespace trigger create `
            -g $resourceGroupName --namespace $connectorNamespaceName `
            -n $triggerName `
            --connection-details "{connectionName:$connectorNamespaceConnectionName,connectorName:sharepointonline}" `
            --operation-name $trigger.OperationName `
            --parameters "@$paramsFile" `
            --notification-details "@$notifFile" `
            --description $trigger.Description `
            --metadata "{destinationType:functionApp,functionAppName:$functionAppName,functionAppResourceGroup:$resourceGroupName,functionAppSubscriptionId:$subscriptionId,functionName:$functionName,recurrenceFrequency:Minute,recurrenceInterval:'5'}" `
            -o none

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create trigger config for $functionName."
        }
    }
    finally {
        Remove-Item -LiteralPath $notifFile, $paramsFile -ErrorAction SilentlyContinue
    }
}

Write-Host "All trigger configs created." -ForegroundColor Green
Write-Host ""
Write-Host "Authorizing sharepointonline connection..." -ForegroundColor Yellow

$currentStatus = az connector-namespace connection show `
    -g $resourceGroupName --namespace $connectorNamespaceName `
    -n $connectorNamespaceConnectionName `
    --query "properties.overallStatus" -o tsv 2>$null

if ($currentStatus -eq "Connected") {
    Write-Host "Connection is already authorized." -ForegroundColor Green
} else {
    Write-Host "-> A browser tab will open. Sign in with the account that has access to the SharePoint site." -ForegroundColor Cyan

    $consentLink = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $consentLink = az connector-namespace connection list-consent-links `
            -g $resourceGroupName --namespace $connectorNamespaceName `
            --connection-name $connectorNamespaceConnectionName `
            --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" `
            --query "value[0].link" -o tsv 2>$null

        if (-not $consentLink) {
            $consentLink = az connector-namespace connection list-consent-links `
                -g $resourceGroupName --namespace $connectorNamespaceName `
                --connection-name $connectorNamespaceConnectionName `
                --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" `
                --query "link" -o tsv 2>$null
        }

        if ($consentLink) {
            break
        }

        if ($attempt -lt 5) {
            Write-Host "list-consent-links attempt $attempt failed. Retrying in 5 seconds..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }

    if (-not $consentLink) {
        Write-Host "Failed to create consent link." -ForegroundColor Red
        exit 1
    }

    Write-Host "Consent URL: $consentLink" -ForegroundColor Cyan

    try {
        Start-Process $consentLink | Out-Null
    } catch {
        Write-Host "Unable to open a browser automatically. Paste the consent URL into your browser." -ForegroundColor Yellow
    }

    $deadline = (Get-Date).AddMinutes(5)
    $lastPrintedStatus = $currentStatus
    Write-Host "Connection status: $currentStatus" -ForegroundColor Cyan

    do {
        Start-Sleep -Seconds 3
        $currentStatus = az connector-namespace connection show `
            -g $resourceGroupName --namespace $connectorNamespaceName `
            -n $connectorNamespaceConnectionName `
            --query "properties.overallStatus" -o tsv 2>$null

        if ($currentStatus -ne $lastPrintedStatus) {
            Write-Host "Connection status: $currentStatus" -ForegroundColor Cyan
            $lastPrintedStatus = $currentStatus
        }

        if ($currentStatus -eq "Connected") {
            break
        }
    } while ((Get-Date) -lt $deadline)

    if ($currentStatus -ne "Connected") {
        Write-Host "Timed out waiting for the connection to reach Connected status." -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "Done. Selected SharePoint triggers are configured; prerequisite-dependent triggers remain opt-in." -ForegroundColor Green
Write-Host "Tail logs: az functionapp log tail -g $resourceGroupName -n $functionAppName" -ForegroundColor Green
Write-Host ""
