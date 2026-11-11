#requires -Version 7.3
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-settings.ps1')
. (Join-Path $PSScriptRoot 'action-cleanup.ps1')
. (Join-Path $PSScriptRoot 'row-config.ps1')
if (-not (az extension show --name connector-namespace --query name -o tsv 2>$null)) {
    throw 'Install the connector-namespace Azure CLI extension before running this script.'
}
$raw = azd env get-values --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected azd environment.' }
$outputs = ($raw -join "`n") | ConvertFrom-Json
foreach ($name in @(
    'resourceGroupName', 'connectorNamespaceName', 'connectorNamespaceConnectionName',
    'functionAppName', 'AZURE_SUBSCRIPTION_ID', 'dataverseEnvironmentUrl', 'dataverseTableName')) {
    if ([string]::IsNullOrWhiteSpace([string]$outputs.$name)) { throw "Missing azd output $name." }
}
if ([string]$outputs.enableActionTrigger -notin @('true', 'false')) {
    throw 'Missing or invalid azd output enableActionTrigger. Run azd provision first.'
}
$actionEnabled = [string]$outputs.enableActionTrigger -eq 'true'
if ([string]$outputs.enableSeparateRowTriggers -notin @('true', 'false')) {
    throw 'Missing or invalid azd output enableSeparateRowTriggers. Run azd provision first.'
}
$separateEnabled = [string]$outputs.enableSeparateRowTriggers -eq 'true'
$rowParameters = if ($separateEnabled) { @(Get-DataverseRowParameters $outputs) }
if ($actionEnabled) {
    foreach ($name in @('eventCatalog', 'eventCategory', 'eventTable', 'eventAction')) {
        if ([string]::IsNullOrWhiteSpace([string]$outputs.$name)) { throw "Missing business-event value $name." }
    }
}

$localValues = @{
    AzureWebJobsStorage = 'UseDevelopmentStorage=true'
    FUNCTIONS_WORKER_RUNTIME = 'dotnet-isolated'
    'AzureWebJobs.OnDataverseActionPerformed.Disabled' = (-not $actionEnabled).ToString().ToLowerInvariant()
    'AzureWebJobs.OnDataverseRowAdded.Disabled' = (-not $separateEnabled).ToString().ToLowerInvariant()
    'AzureWebJobs.OnDataverseRowModified.Disabled' = (-not $separateEnabled).ToString().ToLowerInvariant()
    'AzureWebJobs.OnDataverseRowDeleted.Disabled' = (-not $separateEnabled).ToString().ToLowerInvariant()
}
$optionalTriggers = @(
    @{ functionName = 'OnDataverseActionPerformed'; operationName = 'BusinessEventsTrigger'; enabled = $actionEnabled }
    foreach ($trigger in Get-DataverseSeparateRowTriggers) {
        $trigger.enabled = $separateEnabled
        $trigger
    }
)
$disabledTriggers = @($optionalTriggers | Where-Object { -not $_.enabled })
$actionContext = Get-DataverseActionContext $outputs Webhook
$actionJournal = Get-DataverseActionJournal (Join-Path $PSScriptRoot '../..') $actionContext
$uri = "https://management.azure.com/subscriptions/$($outputs.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($outputs.resourceGroupName)/providers/Microsoft.Web/connectorGateways/$($outputs.connectorNamespaceName)/triggerConfigs"
$raw = az rest --method get --url "${uri}?api-version=2026-05-01-preview" `
    --query '{value:value[].{id:id,name:name,properties:{connectionDetails:properties.connectionDetails,operationName:properties.operationName,parameters:properties.parameters,metadata:properties.metadata,state:properties.state,deliveryMode:properties.deliveryMode,notificationDetails:{callbackUrl:properties.notificationDetails.callbackUrl}}}}' -o json
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect existing Dataverse subscriptions.' }
$configs = ($raw -join "`n") | ConvertFrom-Json
foreach ($trigger in Get-DataverseSeparateRowTriggers) {
    $name = "$($outputs.connectorNamespaceConnectionName)-$($trigger.functionName.ToLowerInvariant())"
    $existing = @($configs.value | Where-Object name -EQ $name)
    if ($existing.Count -gt 1) { throw "Ambiguous Dataverse configuration '$name'." }
    if ($existing.Count -eq 1) {
        Assert-DataverseRowConfig $existing[0] $trigger $outputs Webhook
        if ($separateEnabled -and $existing[0].properties.state -cne 'Enabled') {
            throw "Existing Dataverse row configuration '$name' is not Enabled. Inspect it in Connector Namespace; it was not recreated."
        }
    }
}
$actionConfigs = @($configs.value | Where-Object name -EQ $actionContext.triggerName)
if ($actionConfigs.Count -gt 1) { throw 'Ambiguous Dataverse action configuration.' }
if (-not $actionEnabled) {
    Protect-DataverseActionRegistration $actionContext $actionJournal $actionConfigs[0] $outputs
}
Write-LocalSettings $localValues
foreach ($trigger in $disabledTriggers) {
    $name = "$($outputs.connectorNamespaceConnectionName)-$($trigger.functionName.ToLowerInvariant())"
    $existing = @($configs.value | Where-Object name -eq $name)
    if ($existing.Count -gt 0) {
        az rest --method delete --url "$uri/${name}?api-version=2026-05-01-preview" -o none
        if ($LASTEXITCODE -ne 0) { throw "Could not remove disabled Dataverse subscription '$name'." }
        Write-Host "Removed Connector Namespace configuration '$name' because its function is disabled."
    }
}

function Get-ConnectionStatus {
    $status = az connector-namespace connection show `
        -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName `
        -n $outputs.connectorNamespaceConnectionName --query 'properties.overallStatus' -o tsv
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the Dataverse connection status.' }
    return $status
}
if ((Get-ConnectionStatus) -ne 'Connected') {
    $link = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $link = az connector-namespace connection list-consent-links `
            -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName `
            --connection-name $outputs.connectorNamespaceConnectionName `
            --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" `
            --query 'value[0].link' -o tsv 2>$null
        if (-not $link -or $link -eq 'null') {
            $link = az connector-namespace connection list-consent-links `
                -g $outputs.resourceGroupName --namespace $outputs.connectorNamespaceName `
                --connection-name $outputs.connectorNamespaceConnectionName `
                --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" `
                --query 'link' -o tsv 2>$null
        }
        if ($link -and $link -ne 'null') { break }
        if ($attempt -lt 5) { Start-Sleep -Seconds 5 }
    }
    if (-not $link -or $link -eq 'null') { throw 'Could not obtain a Dataverse consent link.' }
    Write-Host "Consent URL: $link"
    try { Start-Process $link | Out-Null } catch { Write-Host 'Open the consent URL in your browser.' }
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-ConnectionStatus) -ne 'Connected') {
        if ((Get-Date) -ge $deadline) { throw 'Timed out waiting for Dataverse OAuth consent.' }
        Start-Sleep -Seconds 5
    }
} else {
    Write-Host 'Dataverse connection is already authorized; preserving OAuth consent.'
}

$key = az functionapp keys list -g $outputs.resourceGroupName -n $outputs.functionAppName `
    --query systemKeys.connector_extension -o tsv
if ($LASTEXITCODE -ne 0 -or -not $key) { throw 'Connector extension system key unavailable.' }
$hostname = az resource show -g $outputs.resourceGroupName -n $outputs.functionAppName `
    --resource-type Microsoft.Web/sites --query properties.defaultHostName -o tsv
if ($LASTEXITCODE -ne 0 -or -not $hostname) { throw 'Function hostname unavailable.' }
$organization = $outputs.dataverseEnvironmentUrl.TrimEnd('/')
$triggers = @(
    @{
        functionName = 'OnDataverseRowChanged'
        operationName = 'SubscribeWebhookTrigger'
        parameters = @(
            @{ name = 'organization'; value = $organization }
            @{ name = 'entityname'; value = $outputs.dataverseTableName }
            @{ name = 'message'; value = '7' }
            @{ name = 'scope'; value = '4' }
        )
    }
)
if ($actionEnabled) {
    $triggers += @{
        functionName = 'OnDataverseActionPerformed'
        operationName = 'BusinessEventsTrigger'
        parameters = @(
            @{ name = 'organization'; value = $organization }
            @{ name = 'catalog'; value = $outputs.eventCatalog }
            @{ name = 'category'; value = $outputs.eventCategory }
            @{ name = 'entityname'; value = $outputs.eventTable }
            @{ name = 'sdkmessagename'; value = $outputs.eventAction }
        )
    }
}
if ($separateEnabled) {
    foreach ($trigger in $optionalTriggers | Where-Object operationName -ne 'BusinessEventsTrigger') {
        $triggers += @{
            functionName = $trigger.functionName
            operationName = $trigger.operationName
            parameters = $rowParameters
        }
    }
}
foreach ($trigger in $triggers) {
    $name = "$($outputs.connectorNamespaceConnectionName)-$($trigger.functionName.ToLowerInvariant())"
    if ($trigger.operationName -in @((Get-DataverseSeparateRowTriggers).operationName)) {
        $existing = @($configs.value | Where-Object name -CEQ $name)
        if ($existing.Count -eq 1) {
            Write-Host "Preserved existing Dataverse row configuration '$name'; no new source registration requested."
            continue
        }
    }
    if ($trigger.operationName -eq 'BusinessEventsTrigger') {
        Protect-DataverseActionRegistration $actionContext $actionJournal $actionConfigs[0] $outputs -BeforeCreate
        if ($actionConfigs.Count -eq 1) {
            if ($actionConfigs[0].properties.state -cne 'Enabled') {
                throw "Existing Dataverse action configuration '$name' is not Enabled. Inspect and enable that configuration in Connector Namespace; it was not recreated."
            }
            $expected = @{}
            foreach ($parameter in $trigger.parameters) { $expected[$parameter.name] = [string]$parameter.value }
            $current = @{}
            foreach ($parameter in $actionConfigs[0].properties.parameters) { $current[$parameter.name] = [string]$parameter.value }
            Assert-DataverseActionContext $expected $current
            Write-Host "Preserved existing Dataverse action configuration '$name'; no new source registration requested."
            continue
        }
    }
    $bodyFile = Join-Path ([IO.Path]::GetTempPath()) "dataverse-notification-$([Guid]::NewGuid().ToString('N')).json"
    $body = @{
        properties = @{
            connectionDetails = @{ connectionName = $outputs.connectorNamespaceConnectionName; connectorName = 'commondataservice' }
            operationName = $trigger.operationName
            parameters = $trigger.parameters
            metadata = @{
                destinationType = 'functionApp'
                functionAppName = $outputs.functionAppName
                functionAppResourceGroup = $outputs.resourceGroupName
                functionAppSubscriptionId = $outputs.AZURE_SUBSCRIPTION_ID
                functionName = $trigger.functionName
            }
            state = 'Enabled'
            type = 'NotSpecified'
            notificationDetails = @{
                callbackUrl = "https://$hostname/runtime/webhooks/connector?functionName=$($trigger.functionName)"
                authentication = @{ type = 'QueryString'; name = 'code'; value = $key }
            }
        }
    }
    $bodyOwned = $false
    $failure = $null
    try {
        $stream = New-PrivateStagingStream $bodyFile
        $bodyOwned = $true
        $writeFailure = $null
        try {
            $stream.Write([Text.UTF8Encoding]::new($false).GetBytes(($body | ConvertTo-Json -Depth 8)))
            $stream.Flush($true)
        } catch {
            $writeFailure = $_
            throw
        } finally {
            try { $stream.Dispose() } catch {
                if ($null -eq $writeFailure) { throw 'Could not close private callback staging stream.' }
                Write-Warning 'Could not close private callback staging stream; original failure preserved.'
            }
        }
        Write-Host "Configuring Dataverse trigger '$name' ($($trigger.operationName))..."
        $uri = "https://management.azure.com/subscriptions/$($outputs.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($outputs.resourceGroupName)/providers/Microsoft.Web/connectorGateways/$($outputs.connectorNamespaceName)/triggerConfigs/${name}?api-version=2026-05-01-preview"
        az rest --method put --url $uri --body "@$bodyFile" -o none 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not configure Dataverse trigger '$name' ($($trigger.operationName)). Inspect its Connector Namespace status; callback credentials were not logged."
        }
    } catch {
        $failure = $_
        throw
    } finally {
        try {
            if ($bodyOwned -and [IO.File]::Exists($bodyFile)) { [IO.File]::Delete($bodyFile) }
        } catch {
            if ($null -eq $failure) { throw 'Could not clean owned callback staging file.' }
            Write-Warning 'Could not clean owned callback staging file; original failure preserved.'
        }
    }
}
foreach ($trigger in $triggers) {
    $name = "$($outputs.connectorNamespaceConnectionName)-$($trigger.functionName.ToLowerInvariant())"
    $uri = "https://management.azure.com/subscriptions/$($outputs.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($outputs.resourceGroupName)/providers/Microsoft.Web/connectorGateways/$($outputs.connectorNamespaceName)/triggerConfigs/$name/triggerStatuses/latest?api-version=2026-05-01-preview"
    $raw = az rest --method get --url $uri `
        --query '{status:lastExecutionStatus,code:lastExecutionStatusCode,started:lastExecutionStartTime,error:lastExecutionError}' -o json 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Could not read source status for '$name'; inspect Connector Namespace before testing events." }
    $status = ($raw -join "`n") | ConvertFrom-Json -AsHashtable
    if ($status.status -eq 'Failed' -or $status.error.Count -gt 0) {
        throw "Dataverse source execution failed for '$name'. Inspect its Connector Namespace trigger status for source registration errors; details were not logged."
    }
    if ($status.started -and ($status.status -eq 'Succeeded' -or
        ($status.status -eq 'Skipped' -and $status.code -in @('Accepted', 'OK')))) {
        Write-Host "Latest source execution succeeded for '$name'; event delivery is not verified."
    } else {
        Write-Warning "Source registration/execution for '$name' is pending or unverified. Rerun the hook after initialization and inspect Connector Namespace before testing events."
    }
}
if (-not $actionEnabled) { Assert-DataverseActionSourceCleanup $actionJournal }
Write-Host 'Dataverse webhook configuration setup complete. Check the reported source status before testing events.'
