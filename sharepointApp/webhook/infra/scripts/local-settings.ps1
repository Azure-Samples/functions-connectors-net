#requires -Version 7.3

function New-PrivateStagingStream {
    param([string] $Path)
    $options = [IO.FileStreamOptions]::new()
    $options.Mode = [IO.FileMode]::CreateNew
    $options.Access = [IO.FileAccess]::Write
    $options.Share = [IO.FileShare]::None
    if (-not $IsWindows) { $options.UnixCreateMode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite }
    return [IO.File]::Open($Path, $options)
}

function Write-PrivateJsonFile {
    param([string] $Path, [object] $Value, [Collections.Generic.List[string]] $OwnedFiles)
    $stream = New-PrivateStagingStream $Path
    $OwnedFiles.Add($Path)
    $streamFailure = $null
    try {
        $json = ConvertTo-Json -InputObject $Value -Depth 6 -Compress
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

function Remove-OwnedStaging {
    param([Collections.Generic.List[string]] $Paths, $Failure)
    $cleanupFailed = $false
    foreach ($path in $Paths) {
        try {
            if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
        } catch {
            $cleanupFailed = $true
            Write-Warning 'Could not clean owned callback staging file.'
        }
    }
    if ($cleanupFailed -and $null -eq $Failure) { throw 'Callback staging cleanup failed.' }
}

function Get-LocalConnectorExtensionKey {
    param([string] $SampleRoot)
    $settingsPath = Join-Path $SampleRoot 'local.settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        throw 'Create local.settings.json and start Azurite and func start --enableAuth first.'
    }
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $storage = $settings.Values.AzureWebJobsStorage
    if ($storage -notmatch '^UseDevelopmentStorage=true(?:;|$)' -and
        $storage -notmatch '(?i)BlobEndpoint=http://(?:127\.0\.0\.1|localhost|\[::1\]):') {
        throw 'Automatic local-key retrieval requires a local Azurite AzureWebJobsStorage connection.'
    }
    $hostId = $settings.Values.AzureFunctionsWebHost__hostid
    if (-not $hostId) {
        $hostConfig = Get-Content -LiteralPath (Join-Path $SampleRoot 'host.json') -Raw | ConvertFrom-Json
        $hostId = $hostConfig.id
    }
    $raw = az storage blob list --container-name azure-webjobs-secrets --connection-string $storage `
        --query '[].name' -o json
    if ($LASTEXITCODE -ne 0) { throw 'Could not read local host secrets. Start Azurite and func start --enableAuth first.' }
    $names = ($raw -join "`n") | ConvertFrom-Json
    $candidates = @($names | Where-Object { $_ -match '^[^/]+/host\.json$' })
    if ($hostId) { $candidates = @($candidates | Where-Object { $_ -ceq "$($hostId.ToLowerInvariant())/host.json" }) }
    if ($candidates.Count -ne 1) {
        throw 'Could not identify one local host key file. Start this host with func start --enableAuth. If Azurite contains multiple hosts, set Values.AzureFunctionsWebHost__hostid in local.settings.json.'
    }
    $file = Join-Path ([IO.Path]::GetTempPath()) "sharepoint-local-key-$([guid]::NewGuid().ToString('N')).json"
    $ownedFiles = [Collections.Generic.List[string]]::new()
    $failure = $null
    try {
        $stream = New-PrivateStagingStream $file
        $ownedFiles.Add($file)
        $stream.Dispose()
        az storage blob download --container-name azure-webjobs-secrets --name $candidates[0] `
            --connection-string $storage --file $file --overwrite --no-progress -o none
        if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected local host key file.' }
        $secrets = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        $keys = @($secrets.systemKeys | Where-Object { $_.name -ceq 'connector_extension' })
        if ($keys.Count -ne 1 -or $keys[0].encrypted -eq $true) {
            throw 'An unencrypted local connector_extension key was not found. Check local host startup and secret storage.'
        }
        $value = if ($keys[0].value) { $keys[0].value } else { $keys[0].val }
        if ([string]::IsNullOrWhiteSpace($value)) { throw 'The local connector_extension key is empty.' }
        return $value
    } catch { $failure = $_; throw }
    finally { Remove-OwnedStaging $ownedFiles $failure }
}
