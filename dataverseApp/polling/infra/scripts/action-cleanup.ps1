. (Join-Path $PSScriptRoot 'local-settings.ps1')

function Get-DataverseActionContext {
    param($Outputs, [ValidateSet('Poll', 'Webhook')] [string] $Mode)

    foreach ($name in @(
        'AZURE_SUBSCRIPTION_ID', 'resourceGroupName', 'connectorNamespaceName',
        'connectorNamespaceConnectionName', 'functionAppName', 'dataverseEnvironmentUrl')) {
        if ([string]::IsNullOrWhiteSpace([string]$Outputs.$name)) {
            throw "Missing $name required to track Dataverse action cleanup."
        }
    }
    $organization = [uri]$Outputs.dataverseEnvironmentUrl
    if (-not $organization.IsAbsoluteUri -or $organization.Scheme -ne 'https' -or
        $organization.UserInfo -or $organization.Query -or $organization.Fragment -or
        $organization.AbsolutePath -ne '/') {
        throw 'Dataverse environment must be an HTTPS organization URL without credentials, path or query.'
    }
    $resourceGroup = "/subscriptions/$($Outputs.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($Outputs.resourceGroupName)"
    $name = if ($Mode -eq 'Poll') {
        'dataverse-ondataverseactionperformed'
    } else {
        "$($Outputs.connectorNamespaceConnectionName)-ondataverseactionperformed"
    }
    return [ordered]@{
        schemaVersion = 1
        namespaceId = "$resourceGroup/providers/Microsoft.Web/connectorGateways/$($Outputs.connectorNamespaceName)"
        connectionName = [string]$Outputs.connectorNamespaceConnectionName
        appId = "$resourceGroup/providers/Microsoft.Web/sites/$($Outputs.functionAppName)"
        organization = $organization.AbsoluteUri.TrimEnd('/')
        mode = $Mode
        triggerName = $name
        operationName = 'BusinessEventsTrigger'
        functionName = 'OnDataverseActionPerformed'
    }
}

function Assert-DataverseActionContext {
    param($Expected, $Actual)

    if (@($Actual.Keys).Count -ne @($Expected.Keys).Count) {
        throw 'Dataverse action cleanup context is invalid; preserve the journal for manual investigation.'
    }
    foreach ($name in $Expected.Keys) {
        if ([string]$Expected[$name] -cne [string]$Actual[$name]) {
            throw "Dataverse action cleanup context differs at '$name'; refusing to adopt or delete a registration."
        }
    }
}

function Get-DataverseActionJournal {
    param([string] $SampleRoot, $Context)

    $directory = Join-Path $SampleRoot '.azure'
    if (Test-Path -LiteralPath $directory) {
        $item = Get-Item -LiteralPath $directory -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw '.azure must be a regular directory for Dataverse cleanup tracking.'
        }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes("$($Context.namespaceId)|$($Context.connectionName)|$($Context.appId)|$($Context.mode)")
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    return Join-Path $directory "dataverse-action-cleanup-$hash.json"
}

function Protect-DataverseActionRegistration {
    [CmdletBinding()]
    param($Context, [string] $JournalPath, $Config, $Outputs, [switch] $BeforeCreate)

    $selectors = [ordered]@{}
    if ($null -ne $Config) {
        $properties = $Config.properties
        if ($Config.name -cne $Context.triggerName -or
            $Config.id -ine "$($Context.namespaceId)/triggerConfigs/$($Context.triggerName)" -or
            $properties.operationName -cne $Context.operationName -or
            $properties.connectionDetails.connectionName -cne $Context.connectionName -or
            $properties.connectionDetails.connectorName -cne 'commondataservice') {
            throw 'Refusing to adopt or delete a Dataverse action configuration with a different resource binding.'
        }
        if (@($properties.parameters).Count -ne 5) { throw 'Unexpected Dataverse action parameters.' }
        foreach ($name in @('organization', 'catalog', 'category', 'entityname', 'sdkmessagename')) {
            $values = @($properties.parameters | Where-Object name -CEQ $name)
            if ($values.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$values[0].value)) {
                throw "Dataverse action configuration has missing or ambiguous '$name'."
            }
            $selectors[$name] = [string]$values[0].value
        }
        if ($selectors.organization.TrimEnd('/') -cne $Context.organization) {
            throw 'Refusing Dataverse action cleanup for another source organization.'
        }
        if ($Context.mode -eq 'Poll') {
            if ($properties.deliveryMode -cne 'Poll') { throw 'Dataverse action delivery mode differs.' }
        } else {
            if ($properties.deliveryMode -eq 'Poll') { throw 'Dataverse action delivery mode differs.' }
            $callback = [uri]$properties.notificationDetails.callbackUrl
            if ([string]::IsNullOrWhiteSpace([string]$Outputs.functionAppDefaultHostname) -or
                -not $callback.IsAbsoluteUri -or $callback.Scheme -ne 'https' -or
                $callback.Host -ine $Outputs.functionAppDefaultHostname -or
                $callback.AbsolutePath -cne '/runtime/webhooks/connector' -or
                $callback.Query -cne '?functionName=OnDataverseActionPerformed' -or
                $callback.UserInfo -or $callback.Fragment) {
                throw 'Refusing Dataverse action cleanup for another application callback.'
            }
        }
    } elseif ($BeforeCreate) {
        $selectors.organization = $Context.organization
        foreach ($pair in @(
            @('catalog', 'eventCatalog'), @('category', 'eventCategory'),
            @('entityname', 'eventTable'), @('sdkmessagename', 'eventAction'))) {
            $value = [string]$Outputs.($pair[1])
            if ([string]::IsNullOrWhiteSpace($value)) { throw "Missing action selector $($pair[1])." }
            $selectors[$pair[0]] = $value
        }
    }

    if (Test-Path -LiteralPath $JournalPath) {
        $item = Get-Item -LiteralPath $JournalPath -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Dataverse action cleanup journal must be a regular file.'
        }
        if (-not $IsWindows) {
            & /bin/test -f $JournalPath
            if ($LASTEXITCODE -ne 0) { throw 'Dataverse action cleanup journal must be a regular file.' }
        }
        $journal = Get-Content -LiteralPath $JournalPath -Raw | ConvertFrom-Json -AsHashtable
        Assert-DataverseActionContext $Context $journal.context
        if ($journal.status -cne 'SourceCleanupUnverified') { throw 'Invalid Dataverse action cleanup journal status.' }
        if ($null -eq $Config) {
            if ($BeforeCreate) {
                throw "Dataverse action source cleanup remains unverified. Follow README 'Action subscription cleanup' before creating a replacement. Preserve '$JournalPath'. No source callback was deleted."
            }
            return
        }
        Assert-DataverseActionContext $selectors $journal.selectors
        return
    }
    if ($null -eq $Config -and -not $BeforeCreate) {
        Write-Warning 'No action CN configuration or cleanup journal was found. Historical Dataverse source callback cleanup is not verified; see README Action subscription cleanup.'
        return
    }
    [IO.Directory]::CreateDirectory((Split-Path $JournalPath)) | Out-Null
    $temporary = "$JournalPath.$([Guid]::NewGuid().ToString('N')).tmp"
    $owned = $false
    $failure = $null
    try {
        $journal = @{ context = $Context; selectors = $selectors; status = 'SourceCleanupUnverified' }
        $stream = New-PrivateStagingStream $temporary
        $owned = $true
        $writeFailure = $null
        try {
            $stream.Write([Text.UTF8Encoding]::new($false).GetBytes(($journal | ConvertTo-Json -Depth 5)))
            $stream.Flush($true)
        } catch {
            $writeFailure = $_
            throw
        } finally {
            try { $stream.Dispose() } catch {
                if ($null -eq $writeFailure) { throw 'Could not close private action-journal staging stream.' }
                Write-Warning 'Could not close private action-journal staging stream; original failure preserved.'
            }
        }
        $validated = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json -AsHashtable
        Assert-DataverseActionContext $Context $validated.context
        Assert-DataverseActionContext $selectors $validated.selectors
        [IO.File]::Move($temporary, $JournalPath)
    } catch {
        $failure = $_
        throw
    } finally {
        try {
            if ($owned -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        } catch {
            if ($null -eq $failure) { throw 'Could not clean owned action-journal staging file.' }
            Write-Warning 'Could not clean owned action-journal staging file; original failure preserved.'
        }
    }
}

function Assert-DataverseActionSourceCleanup {
    param([string] $JournalPath)

    if (Test-Path -LiteralPath $JournalPath) {
        throw "Only the Connector Namespace action configuration was removed. Dataverse source cleanup remains unverified. Follow README 'Action subscription cleanup'; preserve '$JournalPath' until exact owned callback cleanup and GET 404 are confirmed. No Dataverse callback was automatically deleted."
    }
}
