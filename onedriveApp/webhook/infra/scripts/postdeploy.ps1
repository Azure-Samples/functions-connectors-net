# Post-deployment configuration for the OneDrive webhook sample.
#
# Uses the connector-namespace Azure CLI extension to authorize the OneDrive
# for Business connection, browse folders interactively, and create Connector
# Namespace trigger configs that POST to the Functions connector webhook URL.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-settings.ps1')

Write-Host "Post-deployment configuration..." -ForegroundColor Yellow

# --- Pre-flight: verify the connector-namespace CLI extension is installed ----
if (-not (az extension show --name connector-namespace --query name -o tsv 2>$null)) {
    Write-Host "ERROR: The 'connector-namespace' Azure CLI extension is required." -ForegroundColor Red
    Write-Host "Install: irm https://aka.ms/connector-namespace-cli-install-ps | iex" -ForegroundColor Red
    exit 1
}

# --- Read azd outputs --------------------------------------------------------
$rawOutputs = azd env get-values --output json
if ($LASTEXITCODE -ne 0) {
    throw 'Could not read the selected azd environment.'
}
$outputs = ($rawOutputs -join "`n") | ConvertFrom-Json -ErrorAction Stop

$resourceGroupName      = $outputs.resourceGroupName
$connectorNamespaceName = $outputs.connectorNamespaceName
$onedriveConnectionName = $outputs.connectorNamespaceConnectionName
$functionAppName        = $outputs.functionAppName
$functionAppHostname    = $outputs.functionAppDefaultHostname
$subscriptionId         = $outputs.AZURE_SUBSCRIPTION_ID
$onedriveFolderId       = $outputs.ONEDRIVE_FOLDER_ID

if (-not $resourceGroupName -or -not $connectorNamespaceName -or -not $onedriveConnectionName -or
    -not $functionAppName -or -not $functionAppHostname -or -not $subscriptionId) {
    Write-Host "ERROR: required azd outputs missing. Run 'azd provision' first." -ForegroundColor Red
    exit 1
}

Write-LocalSettings @{
    AzureWebJobsStorage = 'UseDevelopmentStorage=true'
    FUNCTIONS_WORKER_RUNTIME = 'dotnet-isolated'
}

function Select-FromList {
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [object[]] $Items,
        [Parameter(Mandatory)] [string] $LabelProperty,
        [string] $SubLabelProperty
    )

    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $label = $Items[$i].$LabelProperty
        if ($SubLabelProperty -and $Items[$i].$SubLabelProperty) {
            Write-Host ("  [{0}] {1}  ({2})" -f ($i + 1), $label, $Items[$i].$SubLabelProperty)
        } else {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $label)
        }
    }

    while ($true) {
        $answer = Read-Host "Enter number (1-$($Items.Count))"
        if ($null -eq $answer) {
            throw "No input available. Re-run with 'interactive: true' on the hook, or set ONEDRIVE_FOLDER_ID via 'azd env set'."
        }

        $num = 0
        if ([int]::TryParse($answer, [ref] $num) -and $num -ge 1 -and $num -le $Items.Count) {
            return $Items[$num - 1]
        }

        Write-Host "Invalid selection." -ForegroundColor Yellow
    }
}

function Select-OneDriveFolderInteractive {
    param([string] $CurrentSavedId)

    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push([pscustomobject]@{ id = 'root'; path = '/' })

    while ($true) {
        $current = $stack.Peek()
        Write-Host ""
        Write-Host "Current folder: $($current.path)  [id: $($current.id)]" -ForegroundColor Cyan

        $listingPath = if ($current.id -eq 'root') {
            '/datasets/default/folders'
        } else {
            "/datasets/default/folders/$([Uri]::EscapeDataString($current.id))"
        }

        $invokeRaw = az connector-namespace connection invoke `
            -g $resourceGroupName --namespace $connectorNamespaceName `
            --connection-name $onedriveConnectionName `
            --request "{method:GET,path:'$listingPath'}" `
            -o json 2>$null | Out-String

        $subfolders = @()
        if ($LASTEXITCODE -eq 0 -and $invokeRaw) {
            try {
                $invokeResponse = $invokeRaw | ConvertFrom-Json
                $statusCode = 0
                $rawStatusCode = [string] $invokeResponse.response.statusCode
                $success = if ([int]::TryParse($rawStatusCode, [ref] $statusCode)) {
                    $statusCode -ge 200 -and $statusCode -lt 300
                } else {
                    $rawStatusCode -in @('OK', 'Created', 'Accepted', 'NoContent')
                }

                if ($success -and $invokeResponse.response.body) {
                    $items = @($invokeResponse.response.body)
                    $subfolders = @($items | Where-Object { $_.IsFolder })
                } elseif (-not $success) {
                    Write-Host "   connection invoke returned status: $rawStatusCode" -ForegroundColor DarkGray
                }
            } catch {
                Write-Host "   unable to parse OneDrive folder listing response." -ForegroundColor Yellow
            }
        } else {
            Write-Host "   unable to list folders from the OneDrive connection." -ForegroundColor Yellow
        }

        $choices = @()
        $pickId = if ($current.id -eq 'root') { 'root' } else { $current.id }
        $choices += [pscustomobject]@{ display = "[OK] Use this folder ($($current.path))"; action = 'pick'; targetId = $pickId; target = $null }
        if ($CurrentSavedId -and $stack.Count -eq 1) {
            $choices += [pscustomobject]@{ display = "(keep current saved: $CurrentSavedId)"; action = 'keep'; targetId = $CurrentSavedId; target = $null }
        }
        if ($stack.Count -gt 1) {
            $choices += [pscustomobject]@{ display = '.. (go up)'; action = 'up'; targetId = $null; target = $null }
        }
        foreach ($sf in $subfolders) {
            $choices += [pscustomobject]@{
                display  = "-> $($sf.Name)"
                action   = 'down'
                targetId = $null
                target   = [pscustomobject]@{
                    id   = $sf.Id
                    path = if ($current.path -eq '/') { "/$($sf.Name)" } else { "$($current.path)/$($sf.Name)" }
                }
            }
        }
        $choices += [pscustomobject]@{ display = '(Enter folder id manually...)'; action = 'manual'; targetId = $null; target = $null }
        $choices += [pscustomobject]@{ display = '(Cancel - skip trigger creation)'; action = 'cancel'; targetId = $null; target = $null }

        $picked = Select-FromList -Title 'Choose an action:' -Items $choices -LabelProperty 'display'
        switch ($picked.action) {
            'pick' { return $picked.targetId }
            'keep' { return $picked.targetId }
            'up' { [void] $stack.Pop() }
            'down' { $stack.Push($picked.target) }
            'manual' {
                $manual = Read-Host 'OneDrive folder id'
                if (-not [string]::IsNullOrWhiteSpace($manual)) {
                    return $manual.Trim()
                }
            }
            'cancel' { return $null }
        }
    }
}

Write-Host ""
if ($onedriveFolderId) {
    Write-Host "Current ONEDRIVE_FOLDER_ID: $onedriveFolderId" -ForegroundColor DarkGray
}

# --- Authorize the OneDrive connection (OAuth consent) ----------------------
Write-Host ""
Write-Host "Authorizing OneDrive for Business connection..." -ForegroundColor Yellow

$currentStatus = az connector-namespace connection show `
    -g $resourceGroupName --namespace $connectorNamespaceName `
    -n $onedriveConnectionName `
    --query "properties.overallStatus" -o tsv 2>$null

if ($currentStatus -and $currentStatus.ToLower() -eq 'connected') {
    Write-Host "   already Connected; skipping consent flow" -ForegroundColor Green
} else {
    $consentParameters = "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]"
    $consentJson = $null
    $link = $null

    for ($i = 0; $i -lt 5; $i++) {
        $consentJson = az connector-namespace connection list-consent-links `
            -g $resourceGroupName --namespace $connectorNamespaceName `
            --connection-name $onedriveConnectionName `
            --parameters $consentParameters `
            -o json 2>$null | Out-String
        if ($LASTEXITCODE -eq 0 -and $consentJson) {
            $link = az connector-namespace connection list-consent-links `
                -g $resourceGroupName --namespace $connectorNamespaceName `
                --connection-name $onedriveConnectionName `
                --parameters $consentParameters `
                --query "value[0].link" -o tsv 2>$null
            if (-not $link) {
                $link = az connector-namespace connection list-consent-links `
                    -g $resourceGroupName --namespace $connectorNamespaceName `
                    --connection-name $onedriveConnectionName `
                    --parameters $consentParameters `
                    --query "link" -o tsv 2>$null
            }
            if ($link) { break }
        }

        Write-Host "   list-consent-links attempt $($i + 1) failed; retrying in 5s..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }

    if (-not $consentJson) {
        Write-Host "ERROR: list-consent-links returned no output after retries" -ForegroundColor Red
        exit 1
    }

    if (-not $link) {
        Write-Host "ERROR: list-consent-links returned no link." -ForegroundColor Red
        exit 1
    }

    Write-Host "   opening browser for OAuth consent..." -ForegroundColor Cyan
    Write-Host "   (if no tab opens, paste this URL manually: $link)" -ForegroundColor Cyan
    try { Start-Process $link | Out-Null } catch { Write-Host "   Start-Process failed: $_" -ForegroundColor Yellow }

    $deadline = (Get-Date).AddMinutes(5)
    $lastStatus = ''
    $authorized = $false
    while ((Get-Date) -lt $deadline) {
        $status = az connector-namespace connection show `
            -g $resourceGroupName --namespace $connectorNamespaceName `
            -n $onedriveConnectionName `
            --query "properties.overallStatus" -o tsv 2>$null
        if ($status -ne $lastStatus) {
            Write-Host "   status: $(if ($status) { $status } else { '?' })" -ForegroundColor Cyan
            $lastStatus = $status
        }
        if ($status -and $status.ToLower() -eq 'connected') {
            Write-Host "   Connection authenticated" -ForegroundColor Green
            $authorized = $true
            break
        }
        Start-Sleep -Seconds 3
    }

    if (-not $authorized) {
        Write-Host "ERROR: OneDrive connection is not Connected. Complete OAuth consent, then re-run: azd hooks run postdeploy" -ForegroundColor Red
        exit 1
    }
}

# --- Select OneDrive folder -------------------------------------------------
if (-not $onedriveFolderId) {
    try {
        Write-Host ""
        Write-Host "Listing OneDrive folders via the authorized connection..." -ForegroundColor Yellow
        $selected = Select-OneDriveFolderInteractive -CurrentSavedId $onedriveFolderId
        if (-not $selected) {
            Write-Host "Skipping trigger creation." -ForegroundColor Yellow
            Write-Host "Connection authorized; triggers pending." -ForegroundColor Green
            exit 0
        }
        $onedriveFolderId = $selected
    } catch {
        throw "Folder selection failed. Set ONEDRIVE_FOLDER_ID explicitly with 'azd env set' and retry. Details: $_"
    }
}

if ($onedriveFolderId -isnot [string] -or [string]::IsNullOrWhiteSpace($onedriveFolderId)) {
    throw 'OneDrive folderId must be a nonempty string.'
}
azd env set ONEDRIVE_FOLDER_ID $onedriveFolderId | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Could not save ONEDRIVE_FOLDER_ID in the selected azd environment. Trigger registration has not started.'
}
Write-Host "Saved ONEDRIVE_FOLDER_ID=$onedriveFolderId" -ForegroundColor Green

# --- Create Connector Namespace trigger configs -----------------------------
Write-Host ""
$triggers = @(
    @{ functionName = 'OnNewFileContent'; operationName = 'OnNewFileV2' },
    @{ functionName = 'OnUpdatedFileContent'; operationName = 'OnUpdatedFileV2' },
    @{ functionName = 'OnNewFile'; operationName = 'OnNewFilesV2' },
    @{ functionName = 'OnUpdatedFile'; operationName = 'OnUpdatedFilesV2' }
)

$raw = az connector-namespace trigger list -g $resourceGroupName --namespace $connectorNamespaceName --query '[].name' -o json 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Could not list existing webhook trigger configurations.' }
$existing = ($raw -join "`n") | ConvertFrom-Json -NoEnumerate
if ($null -ne $existing -and $existing -isnot [array]) { throw 'Invalid trigger list response.' }
if (@($existing | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count) {
    throw 'Invalid trigger names in list response.'
}
$connectorExtensionKey = az functionapp keys list -g $resourceGroupName -n $functionAppName --query "systemKeys.connector_extension" -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($connectorExtensionKey) -or $connectorExtensionKey -eq 'null') {
    throw 'Could not fetch the connector_extension system key.'
}
foreach ($trigger in $triggers) {
    $functionName = $trigger.functionName
    $operationName = $trigger.operationName
    $triggerName = "$onedriveConnectionName-$($functionName.ToLower())"
    $callbackUrl = "https://$functionAppHostname/runtime/webhooks/connector?functionName=$functionName"
    $notifFile = Join-Path ([IO.Path]::GetTempPath()) "onedrive-notification-$([guid]::NewGuid()).json"
    $parametersFile = Join-Path ([IO.Path]::GetTempPath()) "onedrive-parameters-$([guid]::NewGuid()).json"
    $ownedFiles = [Collections.Generic.List[string]]::new()
    $failure = $null
    try {
        $documents = @(
            @{ path = $notifFile; value = @{
                callbackUrl = $callbackUrl
                authentication = @{ type = 'QueryString'; name = 'code'; value = $connectorExtensionKey }
            } },
            @{ path = $parametersFile; value = @(@{ name = 'folderId'; value = $onedriveFolderId }) }
        )
        foreach ($document in $documents) {
            $stream = New-PrivateStagingStream $document.path
            $ownedFiles.Add($document.path)
            $streamFailure = $null
            try {
                $json = ConvertTo-Json -InputObject $document.value -Depth 4 -Compress
                $stream.Write([Text.UTF8Encoding]::new($false).GetBytes($json))
                $stream.Flush($true)
            } catch { $streamFailure = $_; throw }
            finally {
                try { $stream.Dispose() }
                catch {
                    if ($null -eq $streamFailure) { throw 'Could not close owned callback staging stream.' }
                    Write-Warning 'Could not close owned staging stream; original failure preserved.'
                }
            }
        }
        $verb = if ($triggerName -in $existing) { 'update' } else { 'create' }
        az connector-namespace trigger $verb `
            -g $resourceGroupName --namespace $connectorNamespaceName `
            -n $triggerName `
            --connection-details "{connectionName:$onedriveConnectionName,connectorName:onedriveforbusiness}" `
            --operation-name $operationName `
            --parameters "@$parametersFile" `
            --notification-details "@$notifFile" `
            --state Enabled `
            --description "OneDrive $operationName -> $functionName" `
            --metadata "{destinationType:functionApp,functionAppName:$functionAppName,functionAppResourceGroup:$resourceGroupName,functionAppSubscriptionId:$subscriptionId,functionName:$functionName,recurrenceFrequency:Minute,recurrenceInterval:'5'}" `
            -o none 2>$null | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Could not configure webhook trigger $triggerName."
        }
    } catch {
        $failure = $_
        throw
    } finally {
        $cleanupFailed = $false
        foreach ($path in $ownedFiles) {
            try { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
            catch { $cleanupFailed = $true; Write-Warning 'Could not clean owned callback staging file.' }
        }
        if ($cleanupFailed -and $null -eq $failure) { throw 'Callback staging cleanup failed.' }
    }
}

Write-Host ""
Write-Host "Connector Namespace trigger configs configured successfully." -ForegroundColor Green

Write-Host ""
Write-Host "Post-deployment configuration complete." -ForegroundColor Green
Write-Host ""
