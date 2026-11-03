$ErrorActionPreference = 'Stop'
$sampleRoot = Split-Path $PSScriptRoot

function Assert-Condition {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Resolve-Condition {
    param([object] $Expression, [hashtable] $Parameters, [hashtable] $Definition, [hashtable] $Groups)
    if ($Expression -isnot [string]) { return $Expression }
    $expressionText = $Expression
    if ($expressionText.StartsWith('[') -and $expressionText.EndsWith(']')) {
        $expressionText = $expressionText.Substring(1, $expressionText.Length - 2)
    }
    if ($expressionText -match "^parameters\('(?<name>[^']+)'\)$") { return $Parameters[$Matches.name] }
    if ($expressionText -match "^variables\('definitions'\)\[copyIndex\('triggers'\)\]\.(?<name>\w+)$") { return $Definition[$Matches.name] }
    if ($expressionText -eq "variables('groups')[variables('definitions')[copyIndex('triggers')].group]") { return $Groups[$Definition.group] }
    if ($expressionText -eq "lambdaVariables('t').enabled") { return $Definition.enabled }
    if ($expressionText -match "^'(?<value>[^']*)'$") { return $Matches.value }
    if ($expressionText -match '^\d+$') { return [int]$expressionText }
    if ($expressionText -notmatch '^(?<operator>and|or|not|equals|greater|empty)\((?<arguments>.*)\)$') {
        throw "Unsupported condition in compiled template: $expressionText"
    }
    $operator = $Matches.operator
    $argumentText = $Matches.arguments
    $arguments = [Collections.Generic.List[object]]::new()
    $depth = 0
    $quoted = $false
    $start = 0
    for ($index = 0; $index -lt $argumentText.Length; $index++) {
        $character = $argumentText[$index]
        if ($character -eq "'") { $quoted = -not $quoted }
        if ($quoted) { continue }
        if ($character -in @('(', '[')) { $depth++ }
        if ($character -in @(')', ']')) { $depth-- }
        if ($character -eq ',' -and $depth -eq 0) {
            $arguments.Add((Resolve-Condition $argumentText.Substring($start, $index - $start).Trim() $Parameters $Definition $Groups))
            $start = $index + 1
        }
    }
    $arguments.Add((Resolve-Condition $argumentText.Substring($start).Trim() $Parameters $Definition $Groups))
    switch ($operator) {
        'and' { return [bool]($arguments[0] -and $arguments[1]) }
        'or' { return [bool]($arguments[0] -or $arguments[1]) }
        'not' { return -not $arguments[0] }
        'equals' { return $arguments[0] -ceq $arguments[1] }
        'greater' { return $arguments[0] -gt $arguments[1] }
        'empty' { return [string]::IsNullOrEmpty($arguments[0]) }
    }
}

function Test-Hook {
    param([string] $Mode, [object[]] $Triggers, [hashtable] $Settings, [bool] $ExistingConfigurations)
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) "ado-hook-tests-$([guid]::NewGuid().ToString('N'))"
    $scripts = Join-Path $testRoot 'infra\scripts'
    $null = [IO.Directory]::CreateDirectory($scripts)
    $mockCalls = [Collections.Generic.List[object]]::new()
    $mockExisting = if ($ExistingConfigurations) { @($Triggers | ForEach-Object { "azuredevops-$($_.functionName.ToLowerInvariant())" }) } else { @() }
    $mockOutputs = @{
        resourceGroupName = 'rg-offline-test'
        connectorNamespaceName = 'offline-namespace'
        connectorNamespaceConnectionName = 'offline-connection'
        connectorPollingEndpoint = 'https://poll.example.invalid'
        functionAppName = 'offline-function'
        functionAppDefaultHostname = 'receiver.example.invalid'
        AZURE_SUBSCRIPTION_ID = '00000000-0000-0000-0000-000000000000'
        triggerConfigSettings = $Settings
        triggerDefinitions = $Triggers
    }
    function azd {
        Assert-Condition (($args -join ' ') -eq 'env get-values --output json') 'Unexpected mocked azd command.'
        $global:LASTEXITCODE = 0
        return ($mockOutputs | ConvertTo-Json -Depth 10 -Compress)
    }
    function az {
        $global:LASTEXITCODE = 0
        $command = $args[0..2] -join ' '
        if ($command -eq 'connector-namespace trigger list') { return (ConvertTo-Json -InputObject $mockExisting -Compress) }
        if ($command -eq 'functionapp keys list') { return 'offline-test-key-not-a-secret' }
        Assert-Condition ($command -in @('connector-namespace trigger create', 'connector-namespace trigger update')) 'Unexpected mocked az command.'
        $call = @{
            name = $args[[array]::IndexOf($args, '-n') + 1]
            state = $args[[array]::IndexOf($args, '--state') + 1]
        }
        $notificationIndex = [array]::IndexOf($args, '--notification-details')
        if ($notificationIndex -ge 0) {
            $call.notification = Get-Content -LiteralPath $args[$notificationIndex + 1].Substring(1) -Raw | ConvertFrom-Json
            $parameterPath = $args[[array]::IndexOf($args, '--parameters') + 1].Substring(1)
            $call.parameters = @(Get-Content -LiteralPath $parameterPath -Raw | ConvertFrom-Json)
            $call.operation = $args[[array]::IndexOf($args, '--operation-name') + 1]
        }
        $mockCalls.Add($call)
    }
    try {
        foreach ($file in @('postdeploy.ps1', 'local-settings.ps1')) {
            Copy-Item -LiteralPath (Join-Path $sampleRoot "$Mode\infra\scripts\$file") -Destination $scripts
        }
        & (Join-Path $scripts 'postdeploy.ps1')
        $localPath = Join-Path $testRoot 'local.settings.json'
        $local = Get-Content -LiteralPath $localPath -Raw | ConvertFrom-Json -AsHashtable
        foreach ($trigger in $Triggers) {
            $flag = "AzureWebJobs.$($trigger.functionName).Disabled"
            Assert-Condition ($local.Values[$flag] -ceq $Settings[$flag]) "$Mode hook lost selected local disabled flags."
            $name = "azuredevops-$($trigger.functionName.ToLowerInvariant())"
            $calls = @($mockCalls | Where-Object { $_.name -eq $name })
            if ($trigger.enabled -and $Mode -eq 'webhook') {
                Assert-Condition ($calls.Count -eq 1 -and $calls[0].state -eq 'Enabled') 'Webhook hook did not register the selected callback.'
                Assert-Condition ($calls[0].operation -eq $trigger.operationName) 'Webhook operation changed.'
                Assert-Condition ($calls[0].notification.callbackUrl -eq "https://receiver.example.invalid/runtime/webhooks/connector?functionName=$($trigger.functionName)") 'Webhook callback targets the wrong function.'
                Assert-Condition ($calls[0].notification.authentication.type -eq 'QueryString') 'Webhook key authentication changed.'
                Assert-Condition (($calls[0].parameters | ConvertTo-Json -Compress) -eq ($trigger.parameters | ConvertTo-Json -Compress)) 'Webhook parameter-array serialization changed.'
            } elseif (-not $trigger.enabled -and $ExistingConfigurations) {
                Assert-Condition ($calls.Count -eq 1 -and $calls[0].state -eq 'Disabled') "$Mode hook did not disable an existing opt-out configuration."
            } else {
                Assert-Condition ($calls.Count -eq 0) "$Mode hook configured an unexpected trigger."
            }
        }
        if ($Mode -eq 'polling') {
            Assert-Condition ($local.Values.ConnectorNamespace__pollingEndpoint -eq $mockOutputs.connectorPollingEndpoint) 'Poll endpoint missing from generated local settings.'
            foreach ($trigger in $Triggers) {
                Assert-Condition ($local.Values["$($trigger.functionName)TriggerConfigName"] -eq $Settings["$($trigger.functionName)TriggerConfigName"]) 'Poll configuration setting changed.'
            }
        }
        Assert-Condition (-not $local.Values.ContainsKey('ConnectorNamespace__credential')) 'Hook copied cloud identity into local settings.'
        $before = (Get-FileHash -LiteralPath $localPath).Hash
        foreach ($trigger in $Triggers) {
            $mockOutputs.triggerConfigSettings["AzureWebJobs.$($trigger.functionName).Disabled"] = 'true'
        }
        & (Join-Path $scripts 'postdeploy.ps1')
        Assert-Condition ((Get-FileHash -LiteralPath $localPath).Hash -eq $before) "$Mode hook overwrote existing local settings."
    } finally {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

$localSettingsHashes = @{}
foreach ($mode in @('polling', 'webhook')) {
    $path = Join-Path $sampleRoot "$mode\local.settings.json"
    $localSettingsHashes[$path] = if (Test-Path -LiteralPath $path -PathType Leaf) { (Get-FileHash -LiteralPath $path).Hash } else { $null }
}

foreach ($mode in @('polling', 'webhook')) {
    $infra = Join-Path (Join-Path $sampleRoot $mode) 'infra'
    $raw = az bicep build --file (Join-Path $infra 'main.bicep') --stdout --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "$mode Bicep compilation failed." }
    $main = ($raw -join "`n") | ConvertFrom-Json -AsHashtable
    $bindings = Get-Content -LiteralPath (Join-Path $infra 'main.parameters.json') -Raw | ConvertFrom-Json -AsHashtable
    $appModule = @($main.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' })[0]
    $app = $appModule.properties.template
    $accessModule = @($app.resources | Where-Object { $_.name -eq 'post-app-access' })[0]
    $access = $accessModule.properties.template
    $gateway = @($app.resources | Where-Object type -eq 'Microsoft.Web/connectorGateways')[0]
    Assert-Condition ($gateway.identity.type -eq 'SystemAssigned') "$mode namespace identity changed."
    $policyType = 'Microsoft.Web/connectorGateways/connections/accessPolicies'
    $developerPolicies = @($app.resources | Where-Object type -eq $policyType)
    $functionPolicies = @($access.resources | Where-Object type -eq $policyType)
    Assert-Condition ($developerPolicies.Count -eq 1) "$mode must retain only the developer policy before the app."
    Assert-Condition ($functionPolicies.Count -eq 1) "$mode must retain only the Function App policy after the app."
    Assert-Condition ($developerPolicies[0].properties.principal.identity.objectId -eq "[parameters('userPrincipalId')]") "$mode developer policy grants an unexpected principal."
    Assert-Condition ($developerPolicies[0].condition -eq "[not(empty(parameters('userPrincipalId')))]") "$mode developer policy is no longer optional."
    Assert-Condition ($functionPolicies[0].properties.principal.identity.objectId -eq "[parameters('functionAppPrincipalId')]") "$mode Function App policy grants an unexpected principal."
    Assert-Condition ($accessModule.properties.parameters.functionAppPrincipalId.value -match 'Microsoft\.Web/sites.*\.identity\.principalId') "$mode post-app policy is not bound to the Function App identity."
    foreach ($policy in @($developerPolicies) + @($functionPolicies)) {
        Assert-Condition ($policy.properties.principal.type -eq 'ActiveDirectory') "$mode connection principal type changed."
        Assert-Condition ($policy.properties.principal.identity.tenantId -eq '[tenant().tenantId]') "$mode connection tenant binding changed."
    }
    if ($mode -eq 'polling') {
        $pollModule = @($app.resources | Where-Object name -eq 'poll-triggers')[0]
        Assert-Condition (@($pollModule.dependsOn | Where-Object { $_ -match "resourceId\('Microsoft\.Web/connectorGateways/connections'," }).Count -eq 1) 'Poll configuration must depend on its connection.'
        foreach ($dependency in $pollModule.dependsOn) {
            Assert-Condition ($dependency -match "^\[resourceId\('Microsoft\.Web/connectorGateways(/connections)?',") 'Poll configuration must not depend on an access policy or Function App.'
        }
        Assert-Condition ($pollModule.properties.parameters.functionAppName.value -eq "[variables('functionAppName')]") 'Poll destination must use the deterministic app name.'
        $pollConfig = $pollModule.properties.template.resources[0]
        foreach ($field in @('destinationType', 'functionAppName', 'functionAppResourceGroup', 'functionAppSubscriptionId', 'functionName')) {
            Assert-Condition ($pollConfig.properties.metadata.ContainsKey($field)) "Poll registration omitted $field."
        }
        Assert-Condition ($pollConfig.properties.metadata.functionAppName -eq "[parameters('functionAppName')]") 'Poll destination app binding changed.'
        Assert-Condition ($pollConfig.properties.metadata.functionAppResourceGroup -eq '[resourceGroup().name]') 'Poll destination group binding changed.'
        Assert-Condition ($pollConfig.properties.metadata.functionAppSubscriptionId -eq '[subscription().subscriptionId]') 'Poll destination subscription binding changed.'
    }

    Assert-Condition ($main.parameters.telemetryLocation.defaultValue -eq "[parameters('location')]") "$mode changed the default telemetry region."
    Assert-Condition ($main.parameters.telemetryLocation.minLength -eq 1) "$mode allows an empty telemetry override."
    Assert-Condition ($bindings.parameters.telemetryLocation.value -ceq '${AZURE_TELEMETRY_LOCATION}') "$mode telemetry environment binding is missing."
    Assert-Condition ($appModule.properties.parameters.telemetryLocation.value -eq "[parameters('telemetryLocation')]") "$mode does not forward the telemetry region."
    Assert-Condition ($main.parameters.userPrincipalId.defaultValue -eq '[deployer().objectId]') "$mode removed the default deployer grants."
    Assert-Condition ($bindings.parameters.userPrincipalId.value -ceq '${AZURE_PRINCIPAL_ID}') "$mode developer identity binding changed."
    Assert-Condition ($bindings.parameters.userPrincipalType.value -ceq '${AZURE_PRINCIPAL_TYPE}') "$mode authenticated principal-type binding is missing."
    Assert-Condition (-not $main.parameters.userPrincipalType.ContainsKey('defaultValue')) "$mode guesses a developer principal type."
    Assert-Condition (($main.parameters.userPrincipalType.allowedValues -join ',') -eq 'User,ServicePrincipal,Group') "$mode accepts an unsupported principal type."
    Assert-Condition ($appModule.properties.parameters.userPrincipalType.value -eq "[parameters('userPrincipalType')]") "$mode does not forward the principal type."
    Assert-Condition ($accessModule.properties.parameters.userPrincipalType.value -eq "[parameters('userPrincipalType')]") "$mode does not forward the principal type to RBAC."
    Assert-Condition ($bindings.parameters.Count -eq $main.parameters.Count) "$mode parameter bindings are incomplete."
    foreach ($name in $main.parameters.Keys) {
        Assert-Condition ($bindings.parameters.ContainsKey($name)) "$mode has no azd binding for $name."
    }

    foreach ($scenario in @(
        @{ location = 'eastus2'; telemetryLocation = 'eastus2' },
        @{ location = 'westcentralus'; telemetryLocation = 'eastus2' }
    )) {
        foreach ($resource in $app.resources | Where-Object { $_.type -in @(
            'Microsoft.OperationalInsights/workspaces', 'Microsoft.Insights/components',
            'Microsoft.Web/sites', 'Microsoft.Web/serverfarms', 'Microsoft.Storage/storageAccounts'
        ) }) {
            $telemetry = $resource.type -in @('Microsoft.OperationalInsights/workspaces', 'Microsoft.Insights/components')
            $parameter = if ($telemetry) { 'telemetryLocation' } else { 'location' }
            Assert-Condition ($resource.location -eq "[parameters('$parameter')]") "$mode region wiring is wrong for $($resource.type)."
            if ($resource.location -notmatch "^\[parameters\('(?<name>[^']+)'\)\]$") {
                throw "$mode has an unsupported location expression."
            }
            $resolvedLocation = $scenario[$Matches.name]
            $expectedLocation = if ($telemetry) { $scenario.telemetryLocation } else { $scenario.location }
            Assert-Condition ($resolvedLocation -eq $expectedLocation) "$mode region scenario failed."
        }
    }

    $principals = $access.variables.principals
    Assert-Condition ($principals.Contains("createObject('principalId', parameters('functionAppPrincipalId'), 'principalType', 'ServicePrincipal')")) "$mode does not type the app SAMI explicitly."
    Assert-Condition ($principals.Contains("createObject('principalId', parameters('userPrincipalId'), 'principalType', parameters('userPrincipalType'))")) "$mode ignores the actual developer principal type."
    Assert-Condition (-not $principals.Contains("'User'")) "$mode still assumes a human deployer."
    Assert-Condition ($principals.Contains("if(not(empty(parameters('userPrincipalId')))")) "$mode removed optional developer-grant selection."
    if ($principals -notmatch "createObject\('principalId', parameters\('(?<id>userPrincipalId)'\), 'principalType', parameters\('(?<type>userPrincipalType)'\)\)") {
        throw "$mode has an unsupported developer-principal expression."
    }
    $idParameter = $Matches.id
    $typeParameter = $Matches.type
    foreach ($scenario in @(
        @{ name = 'human'; userPrincipalId = 'existing-human'; userPrincipalType = 'User' },
        @{ name = 'application'; userPrincipalId = 'existing-application'; userPrincipalType = 'ServicePrincipal' },
        @{ name = 'managed identity'; userPrincipalId = 'existing-identity'; userPrincipalType = 'ServicePrincipal' },
        @{ name = 'group'; userPrincipalId = 'existing-group'; userPrincipalType = 'Group' }
    )) {
        $resolvedPrincipal = @{
            principalId = $scenario[$idParameter]
            principalType = $scenario[$typeParameter]
        }
        Assert-Condition ($resolvedPrincipal.principalType -eq $scenario.userPrincipalType) "$mode mislabels the $($scenario.name) principal."
        Assert-Condition ($resolvedPrincipal.principalId -eq $scenario.userPrincipalId) "$mode changes the $($scenario.name) principal."
    }
    Assert-Condition ($access.parameters.functionAppPrincipalId.minLength -eq 1) "$mode accepts an empty app principal."
    foreach ($role in $access.resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' }) {
        Assert-Condition ($role.properties.StartsWith('[union(')) "$mode role properties do not preserve the principal object."
        Assert-Condition (-not $role.properties.Contains("'principalType'")) "$mode overrides the supplied principal type."
    }
    Assert-Condition (($access.variables.storageRoles -join ',') -eq 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b,974c5e8b-45b9-4653-ba55-5f855dd0fb88,0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3') "$mode storage roles changed."
    Assert-Condition ($access.resources.properties -join '' -match '3913510d-42f4-4e42-8a64-420c390055eb') "$mode monitoring publisher role changed."

    $function = @($app.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' })[0]
    Assert-Condition ($function.identity.type -eq 'SystemAssigned') "$mode app identity changed."
    Assert-Condition ($function.properties.functionAppConfig.deployment.storage.authentication.type -eq 'SystemAssignedIdentity') "$mode package authentication changed."
    Assert-Condition ($app.variables.groups.work -eq $true) "$mode changed default trigger selection."

    Assert-Condition ($main.parameters.workItemTriggerSelection.defaultValue -ceq 'All') "$mode changed default work-item selection."
    Assert-Condition (($main.parameters.workItemTriggerSelection.allowedValues -join ',') -ceq 'All,CreatedOnly') "$mode accepts an unsupported selection."
    Assert-Condition ($bindings.parameters.workItemTriggerSelection.value -ceq '${AZURE_DEVOPS_WORK_ITEM_TRIGGER_SELECTION=All}') "$mode selection binding changed."
    Assert-Condition ($appModule.properties.parameters.workItemTriggerSelection.value -eq "[parameters('workItemTriggerSelection')]") "$mode does not forward work-item selection."
    Assert-Condition ($app.variables.definitions.Count -eq 9) "$mode removed a handler definition."
    Assert-Condition ($main.outputs.triggerDefinitions.value.Contains("'Microsoft.Resources/deployments', 'azuredevops-$mode'") -and $main.outputs.triggerDefinitions.value.EndsWith('.outputs.triggerDefinitions.value]')) "$mode does not export trigger definitions."
    Assert-Condition ($main.outputs.triggerConfigSettings.value -eq $main.outputs.triggerDefinitions.value.Replace('triggerDefinitions.value', 'triggerSettings.value')) "$mode does not export matching hook settings."
    Assert-Condition ($app.outputs.triggerDefinitions.value -eq "[variables('triggers')]") "$mode exports different hook definitions."
    Assert-Condition ($app.outputs.triggerSettings.value -eq "[variables('triggerSettings')]") "$mode exports different hook settings."
    Assert-Condition ($app.variables.triggerSettings.Contains("format('AzureWebJobs.{0}.Disabled', lambdaVariables('t').functionName)")) "$mode disabled setting names changed."
    Assert-Condition ($app.variables.triggerSettings.Contains("string(not(lambdaVariables('t').enabled))")) "$mode disabled setting values changed."
    Assert-Condition ($function.properties.siteConfig.appSettings.Contains("map(items(variables('triggerSettings')), lambda('setting', createObject('name', lambdaVariables('setting').key, 'value', lambdaVariables('setting').value)))")) "$mode does not apply selected settings to the cloud app."
    $triggerCopy = @($app.variables.copy | Where-Object { $_.name -eq 'triggers' })[0]
    Assert-Condition ($triggerCopy.count -eq "[length(variables('definitions'))]") "$mode no longer emits all definitions."
    $source = Get-Content -LiteralPath (Join-Path $sampleRoot "$mode\AzureDevOpsFunctions.cs") -Raw
    Assert-Condition (([regex]::Matches($source, '\[Function\(')).Count -eq 9) "$mode removed a production handler."
    $scale = $function.properties.functionAppConfig.scaleAndConcurrency
    if ($mode -eq 'polling') {
        Assert-Condition ($main.parameters.pollingReadyInstanceCount.defaultValue -eq 0) 'Poll reserves instances by default.'
        Assert-Condition (($main.parameters.pollingReadyInstanceCount.allowedValues -join ',') -eq '0,1') 'Poll accepts an unsupported ready count.'
        Assert-Condition ($bindings.parameters.pollingReadyInstanceCount.value -ceq '${AZURE_DEVOPS_POLLING_READY_INSTANCE_COUNT=0}') 'Poll azd binding reserves instances by default.'
        Assert-Condition ($appModule.properties.parameters.pollingReadyInstanceCount.value -eq "[parameters('pollingReadyInstanceCount')]") 'Poll ready count is not forwarded.'
        Assert-Condition ($app.variables.readyTriggers -match "^\[filter\(variables\('triggers'\), lambda\('t', (?<condition>.*)\)\)\]$") 'Unsupported Poll ready-trigger filter.'
        $readyCondition = $Matches.condition
        $readyCopy = @($scale.copy | Where-Object { $_.name -eq 'alwaysReady' })[0]
        Assert-Condition ($readyCopy.count -eq "[length(variables('readyTriggers'))]") 'Poll reserves unfiltered groups.'
        Assert-Condition ($readyCopy.input.name -eq "[format('function:{0}', variables('readyTriggers')[copyIndex('alwaysReady')].functionName)]") 'Poll ready groups use the wrong names.'
        Assert-Condition ($readyCopy.input.instanceCount -eq "[parameters('pollingReadyInstanceCount')]") 'Poll ignores the ready count.'
        $pollModule = @($app.resources | Where-Object { $_.name -eq 'poll-triggers' })[0]
        Assert-Condition ($pollModule.properties.parameters.triggers.value -eq "[filter(variables('triggers'), lambda('t', lambdaVariables('t').enabled))]") 'Poll configurations ignore selected triggers.'
        Assert-Condition ($app.variables.triggerSettings.Contains("format('{0}TriggerConfigName', lambdaVariables('t').functionName)")) 'Poll configuration setting names changed.'
    } else {
        Assert-Condition (-not $main.parameters.ContainsKey('pollingReadyInstanceCount')) 'Webhook exposes a Poll ready-count input.'
        Assert-Condition (-not $app.parameters.ContainsKey('pollingReadyInstanceCount')) 'Webhook receives a Poll ready-count input.'
        Assert-Condition (-not $scale.ContainsKey('copy') -and -not $scale.ContainsKey('alwaysReady')) 'Webhook configures reserved groups.'
        Assert-Condition (-not $function.properties.siteConfig.ContainsKey('alwaysOn')) 'Webhook configures always-on capacity.'
        $compiled = $main | ConvertTo-Json -Depth 100 -Compress
        Assert-Condition ($compiled -notmatch '(?i)alwaysReady|alwaysOn|prewarm|minimumElasticInstanceCount|pollingReadyInstanceCount') 'Webhook contains warm-capacity configuration.'
        Assert-Condition (($bindings | ConvertTo-Json -Compress) -notmatch '(?i)ready|prewarm|alwaysOn') 'Webhook azd bindings expose warm capacity.'
    }

    foreach ($selection in @('All', 'CreatedOnly')) {
        foreach ($optIns in @('none', 'all', 'git-only', 'build-only', 'tfvc-only', 'team-only', 'assignee-only', 'assignment-only')) {
            $parameters = @{
                workItemTriggerSelection = $selection
                repository = $(if ($optIns -in @('all', 'git-only')) { 'existing-repo' } else { '' })
                enableBuildTrigger = ($optIns -in @('all', 'build-only'))
                enableTfvcTrigger = ($optIns -in @('all', 'tfvc-only'))
                team = $(if ($optIns -in @('all', 'team-only', 'assignment-only')) { 'existing-team' } else { '' })
                assignedTo = $(if ($optIns -in @('all', 'assignee-only', 'assignment-only')) { 'existing-member' } else { '' })
            }
            $groups = @{}
            foreach ($name in $app.variables.groups.Keys) {
                $groups[$name] = Resolve-Condition $app.variables.groups[$name] $parameters @{} @{}
            }
            $triggers = @(
                foreach ($definition in $app.variables.definitions) {
                    @{
                        functionName = $definition.functionName
                        operationName = $definition.operationName
                        enabled = Resolve-Condition $triggerCopy.input.enabled $parameters $definition $groups
                        parameters = @(
                            @{ name = 'account'; value = 'offline-org' }
                            @{ name = 'project'; value = 'offline-project' }
                            @{ name = 'wiql__System_WorkItemType'; value = 'Task' }
                        )
                    }
                }
            )
            $expected = @('OnWorkItemCreated')
            if ($selection -eq 'All') { $expected += @('OnWorkItemUpdated', 'OnWorkItemClosed') }
            if ($optIns -in @('all', 'build-only')) { $expected += 'OnBuildCompleted' }
            if ($optIns -in @('all', 'git-only')) { $expected += @('OnGitPullClosed', 'OnGitPullCreated', 'OnGitPush') }
            if ($optIns -in @('all', 'tfvc-only')) { $expected += 'OnTfvcCheckIn' }
            if ($optIns -in @('all', 'assignment-only')) { $expected += 'OnWorkItemAssigned' }
            $selected = @($triggers | Where-Object { $_.enabled } | ForEach-Object { $_.functionName })
            Assert-Condition ((($selected | Sort-Object) -join ',') -ceq (($expected | Sort-Object) -join ',')) "$mode $selection/$optIns enabled unexpected functions."
            $settings = @{}
            foreach ($trigger in $triggers) {
                $settings["AzureWebJobs.$($trigger.functionName).Disabled"] = ([string](-not $trigger.enabled)).ToLowerInvariant()
                if ($mode -eq 'polling') {
                    $settings["$($trigger.functionName)TriggerConfigName"] = "azuredevops-$($trigger.functionName.ToLowerInvariant())"
                }
            }
            if ($mode -eq 'polling') {
                foreach ($count in @($main.parameters.pollingReadyInstanceCount.defaultValue, 1)) {
                    $parameters.pollingReadyInstanceCount = $count
                    $ready = @($triggers | Where-Object { Resolve-Condition $readyCondition $parameters $_ @{} })
                    $expectedCount = if ($count -eq 0) { 0 } else { $selected.Count }
                    Assert-Condition ($ready.Count -eq $expectedCount) "$selection/$optIns reserved the wrong number of Poll groups at count $count."
                    foreach ($trigger in $ready) {
                        $instanceCount = Resolve-Condition $readyCopy.input.instanceCount $parameters $trigger @{}
                        Assert-Condition ($instanceCount -eq 1 -and $trigger.enabled) 'Poll emitted a zero-count or disabled reserved group.'
                    }
                }
            }
            if ($optIns -eq 'none') {
                Test-Hook $mode $triggers $settings ($selection -eq 'CreatedOnly')
            }
        }
    }
    Write-Host "$mode infrastructure checks passed: regions, principal types, SAMI, All/CreatedOnly, opt-ins, capacity and mocked PowerShell hooks."
}

foreach ($path in $localSettingsHashes.Keys) {
    if ($null -eq $localSettingsHashes[$path]) {
        Assert-Condition (-not (Test-Path -LiteralPath $path)) 'Tests created sample local settings.'
    } else {
        Assert-Condition ((Get-FileHash -LiteralPath $path).Hash -eq $localSettingsHashes[$path]) 'Existing sample local settings changed.'
    }
}
