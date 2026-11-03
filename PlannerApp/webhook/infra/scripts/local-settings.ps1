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

function Write-PrivateStagingJson {
    param([IO.Stream] $Stream, $Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 8 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush($true)
}

function Close-PrivateStagingStream {
    param($Stream, $PrimaryFailure)
    try { $Stream.Dispose() }
    catch {
        if ($null -eq $PrimaryFailure) { throw 'Could not close owned staging stream.' }
        Write-Warning 'Could not close owned staging stream; original failure preserved.'
    }
}

function Remove-PrivateStagingFile {
    param([string] $Path)
    [IO.File]::Delete($Path)
}

function Clear-OwnedStagingFiles {
    param([string[]] $Paths, $PrimaryFailure)
    $failed = $false
    foreach ($path in $Paths) {
        try { Remove-PrivateStagingFile $path }
        catch { $failed = $true; Write-Warning 'Could not clean an owned staging file.' }
    }
    if ($failed -and $null -eq $PrimaryFailure) { throw 'Owned staging cleanup failed.' }
}

function Publish-LocalSettings {
    param([string] $Path, [hashtable] $Values)
    try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { $item = $null }
    if ($null -ne $item) {
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'local.settings.json must not be a directory or link.'
        }
        Write-Host 'Existing local.settings.json preserved byte-for-byte.'
        return
    }
    $stage = Join-Path (Split-Path $Path) ".local.settings.$([Guid]::NewGuid().ToString('N')).tmp"
    $owned = $false
    $failure = $null
    try {
        $stream = New-PrivateStagingStream $stage
        $owned = $true
        $streamFailure = $null
        try { Write-PrivateStagingJson $stream @{ IsEncrypted = $false; Values = $Values } }
        catch { $streamFailure = $_; throw }
        finally { Close-PrivateStagingStream -Stream $stream -PrimaryFailure $streamFailure }
        [IO.File]::Move($stage, $Path, $false)
        Write-Host 'Created ignored local.settings.json for Azurite and developer credentials.'
    } catch { $failure = $_; throw }
    finally { if ($owned) { Clear-OwnedStagingFiles -Paths @($stage) -PrimaryFailure $failure } }
}
