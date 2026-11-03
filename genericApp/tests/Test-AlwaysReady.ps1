#Requires -Version 7.2
# Run from the repository root: pwsh -NoProfile -File .\genericApp\tests\Test-AlwaysReady.ps1
param(
    [string] $Helper = (Join-Path $PSScriptRoot '..\polling\infra\scripts\set-always-ready.ps1'),
    [string] $Case,
    [string] $Scratch
)

$ErrorActionPreference = 'Stop'
if (!$IsWindows) {
    throw 'These fault-injection checks require PowerShell 7 on Windows for file-lock semantics.'
}
$Helper = (Resolve-Path -LiteralPath $Helper).Path
$sentinel = 'FAKE_CALLBACK_KEY_GENERIC_TEST_DO_NOT_LOG'

if ($Case) {
    function ConvertTo-CanonicalObject($Value) {
        if ($Value -is [System.Collections.IDictionary]) {
            $ordered = [ordered]@{}
            foreach ($key in @($Value.Keys | Sort-Object)) {
                $ordered[$key] = ConvertTo-CanonicalObject $Value[$key]
            }
            return $ordered
        }
        if ($Value -is [array]) {
            return ,@($Value | ForEach-Object { ConvertTo-CanonicalObject $_ })
        }
        return $Value
    }
    $env:TMP = $Scratch
    $env:TEMP = $Scratch
    $global:mockCalls = [System.Collections.Generic.List[string]]::new()
    $global:capturedPatch = $null
    $global:ownedTemp = $null
    $global:cleanupLock = $null
    $global:mockSite = @{
        properties = @{
            functionAppConfig = @{
                deployment = @{ storage = @{ value = $sentinel; authentication = @{ type = 'SystemAssignedIdentity' } } }
                scaleAndConcurrency = @{
                    alwaysReady = @(@{ name = 'function:OnGenericConnectorEvent'; instanceCount = 1 })
                    maximumInstanceCount = 100
                    instanceMemoryMB = 2048
                }
                runtime = @{ name = 'dotnet-isolated'; version = '10.0' }
            }
        }
    } | ConvertTo-Json -Depth 20 -Compress

    function global:az {
        $tokens = @($args)
        if ($tokens[0] -eq 'rest' -and $tokens[2] -eq 'get') {
            $global:mockCalls.Add('GET')
            $global:LASTEXITCODE = if ($Case -eq 'get-failure') { 31 } else { 0 }
            if ($global:LASTEXITCODE -eq 0) { $global:mockSite }
        }
        elseif ($tokens[0] -eq 'rest' -and $tokens[2] -eq 'patch') {
            $global:mockCalls.Add('PATCH')
            $bodyIndex = [array]::IndexOf($tokens, '--body') + 1
            $path = $tokens[$bodyIndex].Substring(1)
            $global:ownedTemp = $path
            $global:capturedPatch = Get-Content -LiteralPath $path -Raw
            if ($Case -in @('cleanup-only-failure', 'patch-and-cleanup-failure')) {
                $global:cleanupLock = [System.IO.File]::Open($path, 'Open', 'Read', 'None')
            }
            $global:LASTEXITCODE = if ($Case -in @('patch-failure', 'patch-and-cleanup-failure')) { 32 } else { 0 }
        }
        elseif (($tokens[0..3] -join ' ') -eq 'functionapp scale config show') {
            $global:mockCalls.Add('VERIFY')
            $global:LASTEXITCODE = if ($Case -eq 'verify-failure') { 33 } else { 0 }
            switch ($Case) {
                'null' { 'null' }
                'nonempty' { '[{"name":"http","instanceCount":1}]' }
                'malformed' { '{invalid' }
                default { '[]' }
            }
        }
        else {
            $global:mockCalls.Add('UNEXPECTED')
            throw 'Unexpected Azure CLI call; no real CLI execution is permitted.'
        }
    }

    $source = Get-Content -LiteralPath $Helper
    $createLine = 1 + [array]::FindIndex($source, [Predicate[string]] { param($line) $line -match '^\s*\$requestFile = .*GetTempFileName' })
    $writeLine = 1 + [array]::FindIndex($source, [Predicate[string]] { param($line) $line -match '^\s*\[System.IO.File\]::WriteAllText' })
    $breakpoint = $null
    if ($Case -eq 'temp-create-failure') {
        $breakpoint = Set-PSBreakpoint -Script $Helper -Line $createLine -Action {
            $env:TMP = Join-Path $Scratch 'missing-parent'
            $env:TEMP = $env:TMP
        }
    }
    elseif ($Case -eq 'first-write-failure') {
        $breakpoint = Set-PSBreakpoint -Script $Helper -Line $writeLine -Action {
            $global:ownedTemp = $requestFile
            [System.IO.File]::Delete($requestFile)
            [System.IO.Directory]::CreateDirectory($requestFile) | Out-Null
        }
    }

    $caught = $null
    $captured = @()
    try {
        $captured = @(& {
            try {
                & $Helper -SubscriptionId 'offline-subscription' -ResourceGroupName 'offline-rg' -FunctionAppName 'offline-generic'
            }
            catch {
                $script:caught = $_.Exception.Message
            }
        } *>&1 | ForEach-Object { $_.ToString() })
        $leftovers = @(Get-ChildItem -LiteralPath $Scratch -Force)
        $expectedFailure = $Case -notin @('empty', 'null')
        $patchPreserved = $true
        if ($global:capturedPatch) {
            $before = $global:mockSite | ConvertFrom-Json -AsHashtable
            $before.properties.functionAppConfig.scaleAndConcurrency.alwaysReady = @()
            $expected = ConvertTo-CanonicalObject $before | ConvertTo-Json -Depth 30 -Compress
            $actual = ConvertTo-CanonicalObject ($global:capturedPatch | ConvertFrom-Json -AsHashtable) | ConvertTo-Json -Depth 30 -Compress
            $patchPreserved = $expected -eq $actual
        }
        $expectedMessage = switch ($Case) {
            'get-failure' { 'Could not read the Function App configuration.' }
            'patch-failure' { 'Could not clear the Function App always-ready groups.' }
            'patch-and-cleanup-failure' { 'Could not clear the Function App always-ready groups.' }
            'verify-failure' { 'Could not verify the Generic Poll function always-ready configuration.' }
            'nonempty' { 'Expected no always-ready groups.' }
            'cleanup-only-failure' { 'Could not clean the owned scale configuration request file.' }
            default { $null }
        }
        $errorPreserved = !$expectedMessage -or $caught -eq $expectedMessage
        $noSecrets = (($captured -join "`n") + $caught) -notlike "*$sentinel*"
        $cleanupExpected = $Case -notin @('cleanup-only-failure', 'patch-and-cleanup-failure')
        $cleanupPassed = !$cleanupExpected -or $leftovers.Count -eq 0
        $expectedCalls = switch ($Case) {
            'get-failure' { 'GET' }
            { $_ -in @('temp-create-failure', 'first-write-failure') } { 'GET' }
            { $_ -in @('patch-failure', 'cleanup-only-failure', 'patch-and-cleanup-failure') } { 'GET,PATCH' }
            default { 'GET,PATCH,VERIFY' }
        }
        $callsPassed = ($global:mockCalls -join ',') -eq $expectedCalls
        $cleanupWarningPassed = $Case -ne 'patch-and-cleanup-failure' -or
            ($captured -join "`n") -like '*Could not clean the owned scale configuration request file; original failure preserved.*'
        [pscustomobject]@{
            case = $Case
            passed = (($null -ne $caught) -eq $expectedFailure) -and $errorPreserved -and $noSecrets -and $cleanupPassed -and $patchPreserved -and $callsPassed -and $cleanupWarningPassed
            failedExplicitly = $null -ne $caught
            error = $caught
            originalErrorPreserved = $errorPreserved
            noSecrets = $noSecrets
            cleanupPassed = $cleanupPassed
            ownedLeftoverCount = $leftovers.Count
            configPreservedExceptAlwaysReady = $patchPreserved
            calls = @($global:mockCalls)
            callsPassed = $callsPassed
            cleanupWarningPassed = $cleanupWarningPassed
            output = $captured
        } | ConvertTo-Json -Depth 10 -Compress
    }
    finally {
        if ($breakpoint) { $breakpoint | Remove-PSBreakpoint }
        if ($global:cleanupLock) { $global:cleanupLock.Dispose() }
        if ($global:ownedTemp -and (Test-Path -LiteralPath $global:ownedTemp)) {
            Remove-Item -LiteralPath $global:ownedTemp
        }
    }
    exit 0
}

$cases = @('empty', 'null', 'get-failure', 'patch-failure', 'nonempty', 'malformed',
    'verify-failure', 'temp-create-failure', 'first-write-failure', 'cleanup-only-failure', 'patch-and-cleanup-failure')
$results = foreach ($name in $cases) {
    $directory = Join-Path ([System.IO.Path]::GetTempPath()) ("generic-scale-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $directory | Out-Null
    try {
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -File $PSCommandPath -Helper $Helper -Case $name -Scratch $directory
        if ($LASTEXITCODE -ne 0) { throw "Offline harness child failed: $name" }
        $output | ConvertFrom-Json
    }
    finally {
        Remove-Item -LiteralPath $directory
    }
}
$parseTokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Helper, [ref] $parseTokens, [ref] $parseErrors)
if ($parseErrors.Count) { throw 'The public helper has PowerShell parse errors.' }
$tempCreateProtected = $null -ne $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.TryStatementAst] -and
        $null -ne $node.Finally -and $node.Body.Extent.Text -match 'GetTempFileName'
}, $true)
$tempWriteProtected = $null -ne $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.TryStatementAst] -and
        $null -ne $node.Finally -and $node.Body.Extent.Text -match '\[System.IO.File\]::WriteAllText'
}, $true)
if (!$tempCreateProtected -or !$tempWriteProtected) {
    throw 'Temporary-file creation and writing must be protected by try/finally.'
}
$results | Select-Object case, passed, originalErrorPreserved, cleanupPassed, callsPassed, configPreservedExceptAlwaysReady, noSecrets | Format-Table -AutoSize
if (@($results | Where-Object { !$_.passed }).Count) {
    $results | Where-Object { !$_.passed } | Format-List
    exit 1
}
Write-Host "Passed all $($results.Count) offline scale-helper checks."
