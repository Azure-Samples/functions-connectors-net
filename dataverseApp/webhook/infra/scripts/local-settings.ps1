function New-PrivateStagingStream {
    param([string] $Path)
    $options = [IO.FileStreamOptions]::new()
    $options.Mode = [IO.FileMode]::CreateNew
    $options.Access = [IO.FileAccess]::Write
    $options.Share = [IO.FileShare]::None
    if (-not $IsWindows) { $options.UnixCreateMode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite }
    return [IO.File]::Open($Path, $options)
}

function Write-LocalSettings {
    param([hashtable] $Values, [switch] $Force)
    $path = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../local.settings.json'))
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'local.settings.json must be a regular file, not a directory or link.'
        }
        if (-not $Force) {
            Write-Host 'Existing local.settings.json preserved byte-for-byte.'
            return
        }
    }
    $json = @{ IsEncrypted = $false; Values = $Values } | ConvertTo-Json -Depth 5
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($path)) ".local-settings-$([guid]::NewGuid().ToString('N')).tmp"
    $failure = $null
    $owned = $false
    try {
        $stream = New-PrivateStagingStream $temporary
        $owned = $true
        $writeFailure = $null
        try {
            $stream.Write([Text.UTF8Encoding]::new($false).GetBytes($json))
            $stream.Flush($true)
        } catch {
            $writeFailure = $_
            throw
        } finally {
            try { $stream.Dispose() } catch {
                if ($null -eq $writeFailure) { throw 'Could not close private local-settings staging stream.' }
                Write-Warning 'Could not close private local-settings staging stream; original failure preserved.'
            }
        }
        [IO.File]::Move($temporary, $path, [bool]$Force)
        Write-Host 'Created ignored local.settings.json using developer credentials and Azurite.'
    } catch {
        $failure = $_
        throw
    } finally {
        try {
            if ($owned -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        } catch {
            if ($null -eq $failure) { throw 'Could not clean owned local-settings staging file.' }
            Write-Warning 'Could not clean owned local-settings staging file; original failure preserved.'
        }
    }
}
