# Post-deployment configuration for the OneDrive webhook sample.
#
# Uses the connector-namespace Azure CLI extension to authorize the OneDrive
# for Business connection, browse folders interactively, and create Connector
# Namespace trigger configs that POST to the Functions connector webhook URL.

[CmdletBinding()]
param()

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

if (-not $resourceGroupName -or -not $connectorNamespaceName -or -not $onedriveConnectionName -or -not $functionAppName) {
    Write-Host "ERROR: required azd outputs missing. Run 'azd provision' first." -ForegroundColor Red
    exit 1
}

$localSettingsPath = Join-Path $PSScriptRoot '../../local.settings.json'
if (Test-Path -LiteralPath $localSettingsPath) {
    if (-not (Test-Path -LiteralPath $localSettingsPath -PathType Leaf)) {
        throw 'local.settings.json must be a regular file, not a directory.'
    }
    Write-Host 'Existing local.settings.json preserved.'
} else {
    $settingsDirectory = Split-Path -Parent $localSettingsPath
    $settingsTemp = Join-Path $settingsDirectory ".local-settings.$([Guid]::NewGuid().ToString('N'))"
    try {
        $template = Join-Path $settingsDirectory 'local.settings.example.json'
        Copy-Item -LiteralPath $template -Destination $settingsTemp -ErrorAction Stop
        $settings = Get-Content -LiteralPath $settingsTemp -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
        if (@($settings.PSObject.Properties).Count -ne 2 -or
            $settings.IsEncrypted -isnot [bool] -or $settings.IsEncrypted -or
            @($settings.Values.PSObject.Properties).Count -ne 2 -or
            $settings.Values.AzureWebJobsStorage -cne 'UseDevelopmentStorage=true' -or
            $settings.Values.FUNCTIONS_WORKER_RUNTIME -cne 'dotnet-isolated') {
            throw 'The webhook settings template must contain only local Azurite storage and the isolated worker runtime.'
        }
        [IO.File]::Move($settingsTemp, $localSettingsPath)
        Write-Host 'Created ignored local.settings.json for Azurite and the isolated worker.'
    } finally {
        if (Test-Path -LiteralPath $settingsTemp) {
            Remove-Item -LiteralPath $settingsTemp -ErrorAction Stop
        }
    }
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

azd env set ONEDRIVE_FOLDER_ID $onedriveFolderId | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Could not save ONEDRIVE_FOLDER_ID in the selected azd environment. Trigger registration has not started.'
}
Write-Host "Saved ONEDRIVE_FOLDER_ID=$onedriveFolderId" -ForegroundColor Green

# --- Create Connector Namespace trigger configs -----------------------------
Write-Host ""
Write-Host "Fetching connector extension key for $functionAppName..." -ForegroundColor Cyan
$connectorExtensionKey = az functionapp keys list -g $resourceGroupName -n $functionAppName --query "systemKeys.connector_extension" -o tsv
if (-not $connectorExtensionKey) {
    Write-Host "ERROR: could not fetch connector_extension system key from $functionAppName." -ForegroundColor Red
    exit 1
}

$triggers = @(
    @{ functionName = 'OnNewFileContent'; operationName = 'OnNewFileV2' },
    @{ functionName = 'OnUpdatedFileContent'; operationName = 'OnUpdatedFileV2' },
    @{ functionName = 'OnNewFile'; operationName = 'OnNewFilesV2' },
    @{ functionName = 'OnUpdatedFile'; operationName = 'OnUpdatedFilesV2' }
)

$triggerFailures = @()
foreach ($trigger in $triggers) {
    $functionName = $trigger.functionName
    $operationName = $trigger.operationName
    $triggerName = "$onedriveConnectionName-$($functionName.ToLower())"
    $callbackUrl = "https://$functionAppHostname/runtime/webhooks/connector?functionName=$functionName"
    $parametersJson = "[{name:folderId,value:'$onedriveFolderId'}]"
    $notifFile = Join-Path $PSScriptRoot ".notification-details-$([System.Guid]::NewGuid().ToString('N')).json"
    @{
        callbackUrl = $callbackUrl
        authentication = @{
            type = "QueryString"
            name = "code"
            value = $connectorExtensionKey
        }
    } | ConvertTo-Json -Depth 3 -Compress | Set-Content -Path $notifFile -NoNewline

    Write-Host ""
    Write-Host "Creating trigger '$triggerName' for $functionName ($operationName)..." -ForegroundColor Yellow

    try {
        az connector-namespace trigger delete `
            -g $resourceGroupName --namespace $connectorNamespaceName `
            -n $triggerName --yes 2>$null | Out-Null

        az connector-namespace trigger create `
            -g $resourceGroupName --namespace $connectorNamespaceName `
            -n $triggerName `
            --connection-details "{connectionName:$onedriveConnectionName,connectorName:onedriveforbusiness}" `
            --operation-name $operationName `
            --parameters $parametersJson `
            --notification-details "@$notifFile" `
            --description "OneDrive $operationName -> $functionName" `
            --metadata "{destinationType:functionApp,functionAppName:$functionAppName,functionAppResourceGroup:$resourceGroupName,functionAppSubscriptionId:$subscriptionId,functionName:$functionName,recurrenceFrequency:Minute,recurrenceInterval:'5'}" `
            -o none | Out-Null

        if ($LASTEXITCODE -ne 0) {
            Write-Host "WARNING: Failed to create trigger '$triggerName'. Continuing with remaining triggers." -ForegroundColor Yellow
            $triggerFailures += $triggerName
        }
    }
    finally {
        Remove-Item $notifFile -ErrorAction SilentlyContinue
    }
}

Write-Host ""
if ($triggerFailures.Count -eq 0) {
    Write-Host "Connector Namespace trigger configs created successfully." -ForegroundColor Green
} else {
    throw "Some trigger configs failed: $($triggerFailures -join ', ')"
}

Write-Host ""
Write-Host "Post-deployment configuration complete." -ForegroundColor Green
Write-Host ""
