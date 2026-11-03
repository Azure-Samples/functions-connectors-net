$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) "dataverse-infra-tests-$([guid]::NewGuid().ToString('N'))"
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}
try {
    [IO.Directory]::CreateDirectory($root) | Out-Null
    foreach ($mode in @('polling', 'webhook')) {
        $scripts = Join-Path $PSScriptRoot "..\$mode\infra\scripts"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $scripts 'registration.ps1'))) "$mode obsolete registration helper remains."
        $hook = Get-Content (Join-Path $scripts 'postdeploy.ps1') -Raw
        Assert-True ($hook -notmatch 'Assert-DataverseTrigger|registration\.ps1|ownerFunction') "$mode obsolete trigger ownership call or metadata remains."
        $source = Join-Path $PSScriptRoot "..\$mode\infra\main.bicep"
        $target = Join-Path $root "$mode.json"
        az bicep build --file $source --outfile $target --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "$mode Bicep compilation failed." }
        $template = Get-Content $target -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $inputs = Get-Content (Join-Path $PSScriptRoot "..\$mode\infra\main.parameters.json") -Raw | ConvertFrom-Json -AsHashtable
        Assert-True ($inputs.parameters.enableSeparateRowTriggers.value -ceq '${DATAVERSE_ENABLE_SEPARATE_ROW_TRIGGERS=false}') "$mode separate row opt-in input changed."
        Assert-True ($inputs.parameters.dataverseEntitySetName.value -ceq '${DATAVERSE_ENTITY_SET_NAME=accounts}') "$mode entity-set input changed."
        Assert-True ($template.parameters.dataverseEntitySetName.defaultValue -ceq 'accounts') "$mode entity-set default changed."
        $namespace = $template.resources.connectorNamespace.properties.template
        $gateway = @($namespace.resources | Where-Object type -eq 'Microsoft.Web/connectorGateways')
        Assert-True ($gateway.Count -eq 1 -and $gateway[0].identity.type -ceq 'SystemAssigned') "$mode namespace identity changed."
        $policies = @($namespace.resources | Where-Object type -eq 'Microsoft.Web/connectorGateways/connections/accessPolicies')
        $expectedPolicyCount = if ($mode -eq 'polling') { 1 } else { 0 }
        Assert-True ($policies.Count -eq $expectedPolicyCount) "$mode namespace connection policy set changed."
        if ($mode -eq 'polling') {
            Assert-True ($policies[0].name -ceq "[format('{0}/{1}/{2}', parameters('name'), parameters('connectionName'), 'dev-user')]") 'Polling developer policy name changed.'
            Assert-True ($policies[0].properties.principal.identity.objectId -ceq "[parameters('userPrincipalId')]") 'Polling developer policy principal changed.'
            $access = $template.resources.functionAccessPolicy
            Assert-True ($access.properties.parameters.functionAppPrincipalId.value -ceq "[reference('functionApp').outputs.systemAssignedMIPrincipalId.value]") 'Polling app policy must use the Function SAMI.'
            $appPolicies = @($access.properties.template.resources | Where-Object type -eq 'Microsoft.Web/connectorGateways/connections/accessPolicies')
            Assert-True ($appPolicies.Count -eq 1 -and $appPolicies[0].properties.principal.identity.objectId -ceq "[parameters('functionAppPrincipalId')]") 'Polling Function connection access changed.'
        }
        Write-Host "PASS $mode namespace SAMI retained without self-access; existing developer/Function connection policies preserved."
        $config = $template.resources.functionApp.properties.parameters.functionAppConfig.value
        Assert-True ($config.scaleAndConcurrency.instanceMemoryMB -eq 2048 -and $config.scaleAndConcurrency.maximumInstanceCount -eq 100) "$mode hosting capacity changed."
        Assert-True (-not $template.parameters.enableActionTrigger.defaultValue -and -not $template.parameters.enableSeparateRowTriggers.defaultValue) "$mode optional triggers became default."
        Assert-True ($config.deployment.storage.authentication.type -eq 'SystemAssignedIdentity') "$mode deployment storage identity changed."
        if ($mode -eq 'webhook') {
            Assert-True ($template.outputs.enableSeparateRowTriggers.value -ceq "[parameters('enableSeparateRowTriggers')]") 'Webhook separate opt-in output changed.'
            Assert-True ($template.outputs.dataverseEntitySetName.value -ceq "[parameters('dataverseEntitySetName')]") 'Webhook entity-set output changed.'
            Assert-True (-not $config.scaleAndConcurrency.ContainsKey('alwaysReady')) 'Webhook readiness configuration was introduced.'
            continue
        }
        Assert-True ($config.scaleAndConcurrency.alwaysReady -is [array] -and $config.scaleAndConcurrency.alwaysReady.Count -eq 0) 'Polling readiness must be an unconditional empty array for all opt-in combinations.'
        $module = $template.resources.pollTriggers
        Assert-True ($module.properties.parameters.enableSeparateRowTriggers.value -ceq "[parameters('enableSeparateRowTriggers')]") 'Polling separate opt-in was not forwarded.'
        Assert-True ($module.properties.parameters.entitySetName.value -ceq "[parameters('dataverseEntitySetName')]") 'Polling entity-set selector was not forwarded.'
        Assert-True ($module.properties.parameters.functionAppName.value -ceq "[variables('functionAppName')]") 'Polling destination must use the deterministic app name.'
        Assert-True ($module.dependsOn -notcontains 'functionApp') 'Polling destination metadata depends on the app it configures.'
        $poll = $module.properties.template
        Assert-True ($poll.variables.separateTriggers.Count -eq 3) 'Three separate operations are required.'
        foreach ($operation in @('GetOnNewItems_V2', 'GetOnUpdatedItems_V2', 'GetOnDeletedItems_V2')) {
            Assert-True ($poll.variables.separateTriggers.operationName -contains $operation) "Missing operation $operation."
        }
        $resources = @($poll.resources | Where-Object type -eq 'Microsoft.Web/connectorGateways/triggerConfigs')
        Assert-True ($resources.Count -eq 3) 'Expected combined, optional action and three-entry separate loop.'
        foreach ($resource in $resources) {
            Assert-True ($resource.properties.deliveryMode -ceq 'Poll') 'Polling delivery mode changed.'
            Assert-True ($resource.properties.parameters -is [array]) 'Gateway parameters must remain name/value arrays.'
            $metadata = $resource.properties.metadata
            Assert-True (@($metadata.Keys | Where-Object { $_ -like 'owner*' }).Count -eq 0) 'Trigger ownership metadata remains.'
            Assert-True ($metadata.functionAppName -ceq "[parameters('functionAppName')]") 'App destination changed.'
            Assert-True ($metadata.functionAppResourceGroup -ceq '[resourceGroup().name]') 'Destination resource group changed.'
            Assert-True ($metadata.functionAppSubscriptionId -ceq '[subscription().subscriptionId]') 'Destination subscription changed.'
            Assert-True ($metadata.destinationType -ceq 'functionApp') 'Destination type changed.'
        }
        Write-Host 'PASS five polling bindings, destination metadata, acyclic deterministic app name and capacity defaults.'
    }
    Write-Host 'PASS both compiled standalone infrastructure templates.'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
