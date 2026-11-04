param(
    [string] $CallbackBaseUrl,
    [string] $ConnectorExtensionKey,
    [switch] $ConsentLinkOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-settings.ps1')
$localCallback = -not [string]::IsNullOrWhiteSpace($CallbackBaseUrl)

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

# Outputs from azd
$outputs = azd env get-values --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected azd environment.' }

$resourceGroupName = $outputs.resourceGroupName
$connectorNamespaceName = $outputs.connectorNamespaceName
$connectorNamespaceConnectionName = $outputs.connectorNamespaceConnectionName
$functionAppName = $outputs.functionAppName
$functionAppHostname = $outputs.functionAppDefaultHostname
$subscriptionId = $outputs.AZURE_SUBSCRIPTION_ID
$mailFolder = $outputs.office365MailFolder
$calendarId = $outputs.office365CalendarId
foreach ($name in @('resourceGroupName', 'connectorNamespaceName', 'connectorNamespaceConnectionName',
    'functionAppName', 'functionAppDefaultHostname', 'AZURE_SUBSCRIPTION_ID',
    'office365MailFolder', 'office365CalendarId', 'office365TriggerState')) {
    if ([string]::IsNullOrWhiteSpace([string]$outputs.$name)) {
        throw "Missing azd output $name. Run azd provision first."
    }
}

Write-LocalSettings @{
    AzureWebJobsStorage = 'UseDevelopmentStorage=true'
    FUNCTIONS_WORKER_RUNTIME = 'dotnet-isolated'
    'AzureWebJobs.OnSharedMailboxNewEmail.Disabled' =
        ([string]::IsNullOrWhiteSpace($outputs.office365SharedMailboxAddress)).ToString().ToLowerInvariant()
}

$mailParameters = @(@{ name = 'folderPath'; value = $mailFolder })
$calendarParameters = @(@{ name = 'table'; value = $calendarId })
$triggers = @(
    @{ functionName='OnNewEmail'; operationName='OnNewEmailV3'; parameters=$mailParameters; description='When a new email arrives' },
    @{ functionName='OnFlaggedEmail'; operationName='OnFlaggedEmailV4'; parameters=$mailParameters; description='When an email is flagged' },
    @{ functionName='OnNewMentionMeEmail'; operationName='OnNewMentionMeEmailV3'; parameters=$mailParameters; description='When a new email mentioning me arrives' },
    @{ functionName='OnNewCalendarEvent'; operationName='CalendarGetOnNewItemsV3'; parameters=$calendarParameters; description='When a new calendar event is created' },
    @{ functionName='OnUpcomingEvent'; operationName='OnUpcomingEventsV3'; parameters=$calendarParameters; description='When an upcoming event is starting soon' },
    @{ functionName='OnCalendarUpdatedItems'; operationName='CalendarGetOnUpdatedItemsV3'; parameters=$calendarParameters; description='When an event is modified (V3)' }
)
if (-not [string]::IsNullOrWhiteSpace($outputs.office365SharedMailboxAddress)) {
    $triggers += @{ functionName='OnSharedMailboxNewEmail'; operationName='SharedMailboxOnNewEmailV2'
        description='When a new email arrives in a shared mailbox (V2)'
        parameters=@(@{name='mailboxAddress';value=$outputs.office365SharedMailboxAddress}, @{name='folderId';value=$outputs.office365SharedMailboxFolderId}) }
}
$raw = az connector-namespace trigger list -g $resourceGroupName --namespace $connectorNamespaceName --query '[].name' -o json
if ($LASTEXITCODE -ne 0) { throw 'Could not list existing Office 365 trigger configurations.' }
$existingNames = ($raw -join "`n") | ConvertFrom-Json

# Fetch the connector extension system key
if (-not $CallbackBaseUrl) {
    Write-Host "Fetching connector extension key for $functionAppName..." -ForegroundColor Cyan
    $ConnectorExtensionKey = az functionapp keys list -g $resourceGroupName -n $functionAppName --query "systemKeys.connector_extension" -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ConnectorExtensionKey)) {
        throw 'Could not retrieve the connector_extension system key. Deploy the function first.'
    }
    $CallbackBaseUrl = "https://$functionAppHostname"
}
$CallbackBaseUrl = $CallbackBaseUrl.TrimEnd('/')

# --- Helper: create a trigger config on the Connector Namespace ---
function New-TriggerConfig {
    param(
        [Parameter(Mandatory)] [string] $FunctionName,
        [Parameter(Mandatory)] [string] $OperationName,
        [Parameter(Mandatory)] [string] $Description,
        [object[]] $Parameters = @()
    )

    $triggerName = "$connectorNamespaceConnectionName-$($FunctionName.ToLower())"
    $callbackUrl = "$CallbackBaseUrl/runtime/webhooks/connector?functionName=$FunctionName"
    $connectionDetails = "{connectionName:$connectorNamespaceConnectionName,connectorName:office365}"
    $notifFile = Join-Path $PSScriptRoot ".notification-details-$([System.Guid]::NewGuid().ToString('N')).json"
    $parametersFile = Join-Path $PSScriptRoot ".trigger-parameters-$([System.Guid]::NewGuid().ToString('N')).json"
    $ownedFiles = [Collections.Generic.List[string]]::new()
    $failure = $null
    try {
        Write-PrivateJsonFile $parametersFile @($Parameters) $ownedFiles
        Write-PrivateJsonFile $notifFile @{
            callbackUrl = $callbackUrl
            authentication = @{
                type = "QueryString"
                name = "code"
                value = $ConnectorExtensionKey
            }
        } $ownedFiles

        Write-Host "  Creating trigger: $FunctionName -> $OperationName" -ForegroundColor Cyan

        $metadata = "recurrenceFrequency:Minute,recurrenceInterval:'5'"
        if (-not $localCallback) { $metadata += ",destinationType:functionApp,functionAppName:$functionAppName,functionAppResourceGroup:$resourceGroupName,functionAppSubscriptionId:$subscriptionId,functionName:$FunctionName" }
        $verb = if ($triggerName -in $existingNames) { 'update' } else { 'create' }
        az connector-namespace trigger $verb `
            -g $resourceGroupName --namespace $connectorNamespaceName `
            -n $triggerName `
            --connection-details $connectionDetails `
            --operation-name $OperationName `
            --state $outputs.office365TriggerState `
            --parameters "@$parametersFile" `
            --notification-details "@$notifFile" `
            --description $Description `
            --metadata "{$metadata}" `
            -o none 2>$null | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create trigger config for $FunctionName."
        }
    } catch {
        $failure = $_
        throw
    } finally {
        Remove-OwnedStaging $ownedFiles $failure
    }
}

# Polling source operations can also deliver through a namespace webhook callback.
Write-Host "Creating Connector Namespace trigger configs..." -ForegroundColor Yellow

foreach ($trigger in $triggers) {
    New-TriggerConfig -FunctionName $trigger.functionName -OperationName $trigger.operationName `
        -Description $trigger.description -Parameters $trigger.parameters
}
if ([string]::IsNullOrWhiteSpace($outputs.office365SharedMailboxAddress)) {
    Write-Host 'Shared mailbox trigger is disabled. Set OFFICE365_SHARED_MAILBOX_ADDRESS and re-run azd up to enable it.'
}

Write-Host "All trigger configs created." -ForegroundColor Green

Write-Host ""
Write-Host "Authorizing office365 connection..." -ForegroundColor Yellow

$currentStatus = az connector-namespace connection show `
    -g $resourceGroupName --namespace $connectorNamespaceName `
    -n $connectorNamespaceConnectionName `
    --query "properties.overallStatus" -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Could not read the Office 365 connection status.' }

if ($currentStatus -eq "Connected") {
    Write-Host "Connection is already authorized." -ForegroundColor Green
} else {
    $consentLink = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $consentLink = az connector-namespace connection list-consent-links `
            -g $resourceGroupName --namespace $connectorNamespaceName `
            --connection-name $connectorNamespaceConnectionName `
            --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" `
            --query "value[0].link" -o tsv 2>$null

        if (-not $consentLink -or $consentLink -eq "null") {
            $consentLink = az connector-namespace connection list-consent-links `
                -g $resourceGroupName --namespace $connectorNamespaceName `
                --connection-name $connectorNamespaceConnectionName `
                --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" `
                --query "link" -o tsv 2>$null
        }

        if ($consentLink -and $consentLink -ne "null") {
            break
        }

        if ($attempt -lt 5) {
            Write-Host "listConsentLinks attempt $attempt failed. Retrying in 5 seconds..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }

    if (-not $consentLink -or $consentLink -eq "null") {
        Write-Host "Failed to create consent link." -ForegroundColor Red
        exit 1
    }

    Write-Host "Consent URL: $consentLink" -ForegroundColor Cyan
    if ($ConsentLinkOnly -or $outputs.office365TriggerState -eq 'Disabled') { return }

    Write-Host "Sign in with the mailbox account to monitor." -ForegroundColor Cyan
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
            --query "properties.overallStatus" -o tsv
        if ($LASTEXITCODE -ne 0) { throw 'Could not read the Office 365 connection status.' }

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
Write-Host "Done. Office 365 triggers are configured (shared mailbox is opt-in)." -ForegroundColor Green
Write-Host "Tail logs: az functionapp log tail -g $resourceGroupName -n $functionAppName" -ForegroundColor Green
Write-Host ""
