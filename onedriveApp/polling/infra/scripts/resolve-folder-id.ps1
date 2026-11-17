# Resolves a connector-returned OneDrive for Business folder ID and saves it as
# ONEDRIVE_FOLDER_ID in the selected azd environment.
#
# Connection selection, in order:
#   1. -ConnectorNamespace/-ConnectionName (with -ResourceGroup): an existing OneDrive connection.
#   2. This azd environment's provisioned connection, when it has already been deployed.
#   3. Otherwise, a temporary Connector Namespace and connection in -ResourceGroup, deleted afterward
#      unless -KeepBootstrap is set.

[CmdletBinding()]
param(
    [string] $ResourceGroup,
    [string] $ConnectorNamespace,
    [string] $ConnectionName,
    [string] $Location = 'westcentralus',
    [switch] $KeepBootstrap
)

$ErrorActionPreference = 'Stop'

if (-not (az extension show --name connector-namespace --query name -o tsv 2>$null)) {
    throw "Install the connector-namespace Azure CLI extension: irm https://aka.ms/connector-namespace-cli-install-ps | iex"
}

$azdValues = $null
$raw = azd env get-values --output json 2>$null
if ($LASTEXITCODE -eq 0 -and $raw) {
    $azdValues = ($raw -join "`n") | ConvertFrom-Json
}

$bootstrapNamespace = $null

function Remove-BootstrapNamespace {
    if ($bootstrapNamespace -and -not $KeepBootstrap) {
        Write-Host "Deleting temporary Connector Namespace $bootstrapNamespace..." -ForegroundColor DarkGray
        az connector-namespace delete -g $ResourceGroup -n $bootstrapNamespace --yes -o none 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warning "Delete the temporary Connector Namespace $bootstrapNamespace in $ResourceGroup manually." }
    }
}

if ($ConnectorNamespace -or $ConnectionName) {
    if (-not $ResourceGroup -or -not $ConnectorNamespace -or -not $ConnectionName) {
        throw 'Pass -ResourceGroup, -ConnectorNamespace, and -ConnectionName together to use an existing connection.'
    }
} elseif ($azdValues -and $azdValues.resourceGroupName -and $azdValues.connectorNamespaceName -and $azdValues.connectorNamespaceConnectionName) {
    $ResourceGroup = $azdValues.resourceGroupName
    $ConnectorNamespace = $azdValues.connectorNamespaceName
    $ConnectionName = $azdValues.connectorNamespaceConnectionName
    Write-Host "Using this environment's connection $ConnectorNamespace/$ConnectionName." -ForegroundColor DarkGray
} else {
    if (-not $ResourceGroup) {
        throw 'Pass -ResourceGroup for the temporary Connector Namespace, or pass an existing connection with -ResourceGroup, -ConnectorNamespace, and -ConnectionName.'
    }
    if ((az group exists -n $ResourceGroup) -ne 'true') {
        az group create -n $ResourceGroup -l $Location -o none
        if ($LASTEXITCODE -ne 0) { throw "Could not create resource group $ResourceGroup." }
    }
    $bootstrapNamespace = "odfolder-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $ConnectorNamespace = $bootstrapNamespace
    $ConnectionName = 'onedriveforbusiness'
    Write-Host "Creating temporary Connector Namespace $ConnectorNamespace in $ResourceGroup..." -ForegroundColor Yellow
    try {
        az connector-namespace create -g $ResourceGroup -n $ConnectorNamespace -l $Location -o none
        if ($LASTEXITCODE -ne 0) { throw 'Could not create the temporary Connector Namespace.' }
        az connector-namespace connection create -g $ResourceGroup --namespace $ConnectorNamespace `
            -n $ConnectionName --connector-name onedriveforbusiness -o none
        if ($LASTEXITCODE -ne 0) { throw 'Could not create the temporary OneDrive connection.' }
    } catch {
        Remove-BootstrapNamespace
        throw
    }
}

function Invoke-OneDrive([string] $RequestJson) {
    $requestFile = Join-Path ([IO.Path]::GetTempPath()) "onedrive-request-$([guid]::NewGuid().ToString('N')).json"
    try {
        $RequestJson | Set-Content -LiteralPath $requestFile -Encoding utf8NoBOM
        $out = az connector-namespace connection invoke -g $ResourceGroup --namespace $ConnectorNamespace `
            --connection-name $ConnectionName --request "@$requestFile" -o json 2>$null | Out-String
        if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
        return $out | ConvertFrom-Json
    } finally {
        Remove-Item -LiteralPath $requestFile -ErrorAction SilentlyContinue
    }
}

function Get-RootFolderId {
    $response = Invoke-OneDrive '{"method":"GET","path":"/datasets/default/GetFileByPath","queries":{"path":"/"}}'
    $rootId = [string] $response.response.body.Id
    if ([string]::IsNullOrWhiteSpace($rootId) -or $rootId -ieq 'root') {
        throw 'Could not resolve the OneDrive root folder ID from the connection.'
    }
    return $rootId.Trim()
}

function Get-Subfolders([string] $FolderId) {
    $path = if ($FolderId -eq 'root') { '/datasets/default/folders' } else { "/datasets/default/folders/$([Uri]::EscapeDataString($FolderId))" }
    $response = Invoke-OneDrive (@{ method = 'GET'; path = $path } | ConvertTo-Json -Compress)
    if (-not $response) {
        Write-Host '   unable to list folders from the OneDrive connection.' -ForegroundColor Yellow
        return @()
    }
    return @(@($response.response.body) | Where-Object { $_.IsFolder })
}

function Select-Folder {
    $stack = [Collections.Generic.Stack[object]]::new()
    $stack.Push([pscustomobject]@{ id = 'root'; path = '/' })
    while ($true) {
        $current = $stack.Peek()
        Write-Host ''
        Write-Host "Current folder: $($current.path)" -ForegroundColor Cyan
        $choices = [Collections.Generic.List[object]]::new()
        $choices.Add([pscustomobject]@{ label = "[OK] Use this folder ($($current.path))"; action = 'pick' })
        if ($stack.Count -gt 1) { $choices.Add([pscustomobject]@{ label = '.. (go up)'; action = 'up' }) }
        foreach ($folder in Get-Subfolders $current.id) {
            $childPath = if ($current.path -eq '/') { "/$($folder.Name)" } else { "$($current.path)/$($folder.Name)" }
            $choices.Add([pscustomobject]@{ label = "-> $($folder.Name)"; action = 'down'; target = [pscustomobject]@{ id = $folder.Id; path = $childPath } })
        }
        $choices.Add([pscustomobject]@{ label = '(Cancel)'; action = 'cancel' })
        for ($i = 0; $i -lt $choices.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $choices[$i].label) }

        $answer = Read-Host "Enter number (1-$($choices.Count))"
        if ($null -eq $answer) { throw 'No input available; run this script interactively.' }
        $num = 0
        if (-not [int]::TryParse($answer, [ref] $num) -or $num -lt 1 -or $num -gt $choices.Count) {
            Write-Host 'Invalid selection.' -ForegroundColor Yellow
            continue
        }
        $picked = $choices[$num - 1]
        switch ($picked.action) {
            'pick' { if ($current.id -eq 'root') { return Get-RootFolderId } else { return $current.id } }
            'up' { [void] $stack.Pop() }
            'down' { $stack.Push($picked.target) }
            'cancel' { return $null }
        }
    }
}

try {
    $status = az connector-namespace connection show -g $ResourceGroup --namespace $ConnectorNamespace `
        -n $ConnectionName --query 'properties.overallStatus' -o tsv 2>$null
    if ($status -ne 'Connected') {
        Write-Host 'Authorize the OneDrive for Business connection with the account to monitor.' -ForegroundColor Yellow
        az connector-namespace connection authenticate -g $ResourceGroup --namespace $ConnectorNamespace `
            --connection-name $ConnectionName --timeout 300 -o none
        if ($LASTEXITCODE -ne 0) { throw 'OneDrive connection authorization did not complete.' }
    }

    $folderId = Select-Folder
    if (-not $folderId) {
        Write-Host 'Cancelled; ONEDRIVE_FOLDER_ID was not changed.' -ForegroundColor Yellow
        return
    }
    if ($folderId -ieq 'root') { throw "Literal 'root' is not a valid OneDrive trigger folder ID." }

    if ($azdValues) {
        azd env set ONEDRIVE_FOLDER_ID $folderId | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not save ONEDRIVE_FOLDER_ID in the selected azd environment.' }
        Write-Host "Saved ONEDRIVE_FOLDER_ID=$folderId" -ForegroundColor Green
    } else {
        Write-Host "ONEDRIVE_FOLDER_ID=$folderId" -ForegroundColor Green
        Write-Host 'Run: azd env set ONEDRIVE_FOLDER_ID <id> in your azd environment.'
    }
} finally {
    Remove-BootstrapNamespace
}
