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
    param([hashtable] $Values)
    $path = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../local.settings.json'))
    try { $existing = Get-Item -LiteralPath $path -Force -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { $existing = $null }
    if ($null -ne $existing) {
        if ($existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'local.settings.json must not be a directory or link.'
        }
        Write-Host 'Existing local.settings.json preserved byte-for-byte.'
        return
    }
    $json = @{ IsEncrypted = $false; Values = $Values } | ConvertTo-Json -Depth 5
    $stream = New-PrivateStagingStream $path
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream.Write($bytes)
    } finally { $stream.Dispose() }
    Write-Host 'Created ignored local.settings.json for developer authentication and Azurite.'
}
