param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $FunctionAppName
)

$ErrorActionPreference = 'Stop'

Write-Warning 'This retains one billed Flex Consumption always-ready instance for OnGenericConnectorEvent.'
az functionapp scale config always-ready set `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroupName `
    --name $FunctionAppName `
    --settings 'function:ongenericconnectorevent=1' `
    --output none
if ($LASTEXITCODE -ne 0) {
    throw 'Could not configure the Generic Poll function always-ready instance.'
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
$settings = ($raw -join "`n") | ConvertFrom-Json
$match = @($settings | Where-Object {
    $_.name -eq 'function:ongenericconnectorevent' -and $_.instanceCount -eq 1
})
if ($match.Count -ne 1) {
    throw 'Expected one always-ready instance for function:ongenericconnectorevent.'
}
Write-Host 'Verified: OnGenericConnectorEvent retains one function-scoped always-ready instance.'
