param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $FunctionAppName
)

$ErrorActionPreference = 'Stop'

$uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/${FunctionAppName}?api-version=2024-04-01"
$raw = az rest --method get --uri $uri --output json
if ($LASTEXITCODE -ne 0) {
    throw 'Could not read the Function App configuration.'
}
$site = ($raw -join "`n") | ConvertFrom-Json
$config = $site.properties.functionAppConfig
if ($null -eq $config.scaleAndConcurrency) {
    throw 'Expected an existing Flex Consumption scale configuration.'
}
$config.scaleAndConcurrency | Add-Member -NotePropertyName alwaysReady -NotePropertyValue @() -Force
$body = @{ properties = @{ functionAppConfig = $config } } | ConvertTo-Json -Depth 50 -Compress
$requestFile = $null
$failure = $null
try {
    $requestFile = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($requestFile, $body)
    az rest --method patch --uri $uri --headers 'Content-Type=application/json' --body "@$requestFile" --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not clear the Function App always-ready groups.'
    }
}
catch {
    $failure = $_
    throw
}
finally {
    try {
        if ($null -ne $requestFile) {
            Remove-Item -LiteralPath $requestFile
        }
    }
    catch {
        if ($null -eq $failure) {
            throw 'Could not clean the owned scale configuration request file.'
        }
        Write-Warning 'Could not clean the owned scale configuration request file; original failure preserved.'
    }
}

$raw = az functionapp scale config show `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroupName `
    --name $FunctionAppName `
    --query alwaysReady `
    --output json
if ($LASTEXITCODE -ne 0) {
    throw 'Could not verify the Generic Poll function always-ready configuration.'
}
$settings = ($raw -join "`n") | ConvertFrom-Json -NoEnumerate
if ($null -ne $settings -and @($settings).Count -ne 0) {
    throw 'Expected no always-ready groups.'
}
Write-Host 'Verified: no always-ready groups are configured.'
