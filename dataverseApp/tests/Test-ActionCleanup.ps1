param([string] $ResultPath)

$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) "dataverse-action-tests-$([guid]::NewGuid().ToString('N'))"
$results = [Collections.Generic.List[object]]::new()

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock] $Action, [string] $Pattern)
    $failure = $null
    try { & $Action } catch { $failure = $_ }
    Assert-True ($null -ne $failure) 'Expected an explicit failure.'
    Assert-True ($failure.Exception.Message -match $Pattern) "Unexpected failure: $($failure.Exception.Message)"
}

function Invoke-Case {
    param([string] $Name, [scriptblock] $Action)
    $script:caseRoot = Join-Path $root "$script:mode-$Name"
    [IO.Directory]::CreateDirectory($script:caseRoot) | Out-Null
    try {
        & $Action
        $results.Add(@{ connector = 'Dataverse'; mode = $script:mode; shell = 'powershell'; caseId = $Name; status = 'pass'; evidence = "Test-ActionCleanup.ps1::$Name"; reason = '' })
    } catch {
        $results.Add(@{ connector = 'Dataverse'; mode = $script:mode; shell = 'powershell'; caseId = $Name; status = 'fail'; evidence = $_.Exception.Message; reason = '' })
    }
}

function New-Fixture {
    $outputs = [pscustomobject]@{
        AZURE_SUBSCRIPTION_ID = '11111111-1111-1111-1111-111111111111'
        resourceGroupName = 'rg-test'
        connectorNamespaceName = 'cns-test'
        connectorNamespaceConnectionName = 'cnsc-test'
        functionAppName = 'func-test'
        functionAppDefaultHostname = 'func-test.azurewebsites.net'
        dataverseEnvironmentUrl = 'https://test.crm.dynamics.com'
        eventCatalog = 'catalog'
        eventCategory = 'category'
        eventTable = 'account'
        eventAction = 'GrantAccess'
    }
    $delivery = if ($script:mode -eq 'polling') { 'Poll' } else { 'Webhook' }
    $context = Get-DataverseActionContext $outputs $delivery
    $config = @{
        name = $context.triggerName
        id = "$($context.namespaceId)/triggerConfigs/$($context.triggerName)"
        properties = @{
            operationName = 'BusinessEventsTrigger'
            connectionDetails = @{ connectionName = 'cnsc-test'; connectorName = 'commondataservice' }
            parameters = @(
                @{ name = 'organization'; value = $outputs.dataverseEnvironmentUrl }
                @{ name = 'catalog'; value = 'catalog' }
                @{ name = 'category'; value = 'category' }
                @{ name = 'entityname'; value = 'account' }
                @{ name = 'sdkmessagename'; value = 'GrantAccess' }
            )
        }
    }
    if ($delivery -eq 'Poll') {
        $config.properties.deliveryMode = 'Poll'
    } else {
        $config.properties.notificationDetails = @{
            callbackUrl = 'https://func-test.azurewebsites.net/runtime/webhooks/connector?functionName=OnDataverseActionPerformed'
            authentication = @{ type = 'QueryString'; name = 'code'; value = 'FAKE-CALLBACK-SECRET-DO-NOT-LOG' }
        }
    }
    return @{ outputs = $outputs; context = $context; config = $config; path = (Get-DataverseActionJournal $script:caseRoot $context) }
}

try {
    foreach ($name in @('action-cleanup.ps1', 'local-settings.ps1')) {
        $pollHelper = Get-Content (Join-Path $PSScriptRoot "..\polling\infra\scripts\$name") -Raw
        $hookHelper = Get-Content (Join-Path $PSScriptRoot "..\webhook\infra\scripts\$name") -Raw
        Assert-True ($pollHelper -ceq $hookHelper) "Standalone helpers have diverged at $name."
    }
    foreach ($script:mode in @('polling', 'webhook')) {
        . (Join-Path $PSScriptRoot "..\$script:mode\infra\scripts\action-cleanup.ps1")
        Invoke-Case 'ACTION_INACTIVE_MISSING_JOURNAL' {
            $f = New-Fixture
            $warnings = @()
            Protect-DataverseActionRegistration $f.context $f.path $null $f.outputs -WarningVariable warnings -WarningAction SilentlyContinue
            Assert-True ($warnings.Count -eq 1) 'Historical cleanup must not be reported as verified.'
            Assert-True (-not (Test-Path -LiteralPath $f.path)) 'Inactive action must not create a pending marker.'
        }
        Invoke-Case 'ACTION_PENDING_REPEATED_OPT_OUT' {
            $f = New-Fixture
            Protect-DataverseActionRegistration $f.context $f.path $f.config $f.outputs
            $bytes = [IO.File]::ReadAllBytes($f.path)
            Assert-Throws { Assert-DataverseActionSourceCleanup $f.path } 'source cleanup remains unverified'
            Protect-DataverseActionRegistration $f.context $f.path $null $f.outputs
            Assert-Throws { Assert-DataverseActionSourceCleanup $f.path } 'source cleanup remains unverified'
            Assert-True ([Convert]::ToBase64String($bytes) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.path))) 'Repeated opt-out changed the pending evidence.'
            Assert-Throws { Protect-DataverseActionRegistration $f.context $f.path $null $f.outputs -BeforeCreate } 'before creating a replacement'
        }
        Invoke-Case 'ACTION_CONFIRMATION_REQUIRED' {
            $f = New-Fixture
            Protect-DataverseActionRegistration $f.context $f.path $f.config $f.outputs
            Assert-Throws { Assert-DataverseActionSourceCleanup $f.path } 'GET 404'
            # This removes only the local marker, simulating the documented administrator confirmation.
            Remove-Item -LiteralPath $f.path
            Assert-DataverseActionSourceCleanup $f.path
            $warnings = @()
            Protect-DataverseActionRegistration $f.context $f.path $null $f.outputs -WarningVariable warnings -WarningAction SilentlyContinue
            Assert-True ($warnings.Count -eq 1) 'Manual confirmation must not become automated source-cleanup proof.'
        }
        Invoke-Case 'ACTION_FOREIGN_BINDING_REFUSED' {
            foreach ($field in @('namespaceId', 'connectionName', 'appId', 'organization', 'operationName')) {
                $f = New-Fixture
                Protect-DataverseActionRegistration $f.context $f.path $f.config $f.outputs
                $foreign = [ordered]@{}
                foreach ($name in $f.context.Keys) { $foreign[$name] = $f.context[$name] }
                $foreign[$field] = 'foreign'
                Assert-Throws { Protect-DataverseActionRegistration $foreign $f.path $f.config $f.outputs } 'Refusing|differs'
            }
        }
        Invoke-Case 'ACTION_FOREIGN_CONFIG_REFUSED' {
            foreach ($field in @('id', 'operation', 'connection', 'source', 'app')) {
                if ($field -eq 'app' -and $script:mode -eq 'polling') { continue }
                $f = New-Fixture
                switch ($field) {
                    id { $f.config.id = '/foreign/config' }
                    operation { $f.config.properties.operationName = 'OtherOperation' }
                    connection { $f.config.properties.connectionDetails.connectionName = 'foreign' }
                    source { $f.config.properties.parameters[0].value = 'https://foreign.crm.dynamics.com' }
                    app { $f.config.properties.notificationDetails.callbackUrl = 'https://foreign.example/runtime/webhooks/connector?functionName=OnDataverseActionPerformed' }
                }
                Assert-Throws { Protect-DataverseActionRegistration $f.context $f.path $f.config $f.outputs } 'Refusing'
                Assert-True (-not (Test-Path -LiteralPath $f.path)) 'Foreign registration was adopted.'
            }
        }
        Invoke-Case 'ACTION_WORKING_RERUN' {
            $f = New-Fixture
            Protect-DataverseActionRegistration $f.context $f.path $f.config $f.outputs
            Protect-DataverseActionRegistration $f.context $f.path $f.config $f.outputs -BeforeCreate
            $changed = $f.config.properties.parameters[4]
            $changed.value = 'OtherAction'
            Assert-Throws { Protect-DataverseActionRegistration $f.context $f.path $f.config $f.outputs } 'differs'
        }
        Invoke-Case 'ACTION_NO_SECRET_OR_SOURCE_MUTATION' {
            $f = New-Fixture
            $before = $f.config | ConvertTo-Json -Depth 10 -Compress
            $output = @(& { Protect-DataverseActionRegistration $f.context $f.path $f.config $f.outputs } *>&1) -join "`n"
            $journal = Get-Content -LiteralPath $f.path -Raw
            Assert-True ($output -notmatch 'FAKE-CALLBACK-SECRET' -and $journal -notmatch 'FAKE-CALLBACK-SECRET|callbackUrl|authentication') 'Secret was logged or journaled.'
            Assert-True ($before -ceq ($f.config | ConvertTo-Json -Depth 10 -Compress)) 'Input registration was changed.'
            $source = Get-Content (Join-Path $PSScriptRoot "..\$script:mode\infra\scripts\action-cleanup.ps1") -Raw
            Assert-True ($source -notmatch '(?im)^\s*(az |Invoke-(RestMethod|WebRequest))') 'Manual fallback must not call source APIs.'
        }
        Invoke-Case 'ACTION_CORRUPT_JOURNAL' {
            $f = New-Fixture
            Protect-DataverseActionRegistration $f.context $f.path $f.config $f.outputs
            [IO.File]::WriteAllText($f.path, '{invalid')
            Assert-Throws { Protect-DataverseActionRegistration $f.context $f.path $null $f.outputs } 'JSON'
        }
        Invoke-Case 'ACTION_JOURNAL_EXCLUDED' {
            $sample = Join-Path $PSScriptRoot "..\$script:mode"
            $gitignore = Get-Content (Join-Path $sample '.gitignore') -Raw
            $funcignore = Get-Content (Join-Path $sample '.funcignore') -Raw
            $project = Get-Content (Join-Path $sample 'functions-connectors-net.csproj') -Raw
            Assert-True ($gitignore -match '(?m)^\.azure/' -and $funcignore -match '(?m)^\.azure\s*$' -and $project -match '\.azure/\*\*') 'Journal is not excluded from commit and both publish paths.'
        }
    }
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
foreach ($row in $results) {
    foreach ($field in @('connector', 'mode', 'shell', 'caseId', 'status', 'evidence', 'reason')) {
        if ($row[$field] -isnot [string]) { throw "Report field '$field' must be a string on every row." }
    }
}
if ($ResultPath) { [IO.File]::WriteAllText($ResultPath, ($results | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false)) }
$results | ForEach-Object { Write-Host "$($_.status): $($_.mode) $($_.caseId) $($_.evidence)" }
if (@($results | Where-Object status -eq 'fail').Count) { throw 'Dataverse action cleanup regressions failed.' }
