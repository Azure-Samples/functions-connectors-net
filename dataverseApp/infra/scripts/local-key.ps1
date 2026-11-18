function Get-DataverseLocalKey {
    param([string] $SampleRoot, [string] $LocalHostId)
    $settingsPath = Join-Path $SampleRoot 'local.settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { throw 'Create local.settings.json and start the local host first.' }
    $settings = ConvertFrom-DataverseJson ([IO.File]::ReadAllText($settingsPath))
    $storage = $settings.Values.AzureWebJobsStorage
    if ($storage -notmatch '^UseDevelopmentStorage=true(?:;|$)' -and
        $storage -notmatch '(?i)BlobEndpoint=http://(?:127\.0\.0\.1|localhost|\[::1\]):') {
        throw 'Automatic local-key retrieval requires a local Azurite AzureWebJobsStorage connection.'
    }
    if (-not $LocalHostId) { $LocalHostId = $settings.Values.AzureFunctionsWebHost__hostid }
    if (-not $LocalHostId) {
        $hostConfig = ConvertFrom-DataverseJson ([IO.File]::ReadAllText((Join-Path $SampleRoot 'host.json')))
        $LocalHostId = $hostConfig.id
    }
    $raw = az storage blob list --container-name azure-webjobs-secrets --connection-string $storage `
        --query '[].name' -o json 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Could not read local host secrets. Start Azurite and func start --enableAuth first.' }
    $names = ConvertFrom-DataverseJson ($raw -join "`n")
    $candidates = @($names | Where-Object { $_ -match '^[^/]+/host\.json$' })
    if ($LocalHostId) { $candidates = @($candidates | Where-Object { $_ -ceq "$($LocalHostId.ToLowerInvariant())/host.json" }) }
    if ($candidates.Count -ne 1) {
        throw 'Could not identify one local host key file. Start this host with func start --enableAuth; if Azurite contains multiple hosts, pass -LocalHostId <host-id>.'
    }
    $file = Join-Path ([IO.Path]::GetTempPath()) "dataverse-local-key-$([guid]::NewGuid().ToString('N')).json"
    $owned = $false
    try {
        $stream = New-PrivateStagingStream $file
        $owned = $true
        $stream.Dispose()
        az storage blob download --container-name azure-webjobs-secrets --name $candidates[0] `
            --connection-string $storage --file $file --overwrite --no-progress -o none 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected local host key file.' }
        $secrets = ConvertFrom-DataverseJson ([IO.File]::ReadAllText($file))
        $key = @($secrets.systemKeys | Where-Object { $_.name -ceq 'connector_extension' })
        if ($key.Count -ne 1 -or $key[0].encrypted -eq $true) {
            throw 'An unencrypted local connector_extension key was not found. Check local host startup and secret storage.'
        }
        $value = if ($key[0].value) { $key[0].value } else { $key[0].val }
        if ([string]::IsNullOrWhiteSpace($value)) { throw 'The local connector_extension key is empty.' }
        return $value
    } finally {
        if ($owned -and [IO.File]::Exists($file)) { [IO.File]::Delete($file) }
    }
}
