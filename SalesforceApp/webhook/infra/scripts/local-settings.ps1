function New-PrivateStagingStream {
    param([string] $Path)
    $options = [IO.FileStreamOptions]::new()
    $options.Mode = [IO.FileMode]::CreateNew
    $options.Access = [IO.FileAccess]::Write
    $options.Share = [IO.FileShare]::None
    if (-not $IsWindows) { $options.UnixCreateMode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite }
    return [IO.File]::Open($Path, $options)
}

function Test-LocalSettingsFile {
    param([string] $Path)
    try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { return $false }
    if ($item -isnot [IO.FileInfo] -or $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'local.settings.json must be a regular file, not a directory or link.'
    }
    return $true
}

function Remove-OwnedStaging {
    param([Collections.Generic.List[string]] $Paths, $Failure)
    $cleanupFailed = $false
    foreach ($path in $Paths) {
        try { [IO.File]::Delete($path) }
        catch {
            $cleanupFailed = $true
            Write-Warning 'Could not clean an owned staging file.'
        }
    }
    if ($cleanupFailed -and $null -eq $Failure) { throw 'Owned staging cleanup failed.' }
}

function Write-PrivateJson {
    param([string] $Path, $Value, [Collections.Generic.List[string]] $OwnedPaths)
    $stream = New-PrivateStagingStream $Path
    $OwnedPaths.Add($Path)
    $streamFailure = $null
    try {
        $json = ConvertTo-Json -InputObject $Value -Depth 12
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream.Write($bytes)
        $stream.Flush($true)
    }
    catch { $streamFailure = $_; throw }
    finally {
        try { $stream.Dispose() }
        catch {
            if ($null -eq $streamFailure) { throw 'Could not close owned staging stream.' }
            Write-Warning 'Could not close owned staging stream; original failure preserved.'
        }
    }
}

function Write-LocalSettings {
    param([string] $Target, [hashtable] $Settings)
    $json = ConvertTo-Json -InputObject $Settings -Depth 4
    $stream = [IO.File]::Open($Target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream.Write($bytes)
    }
    finally { $stream.Dispose() }
    Write-Host 'Created ignored local.settings.json for Azurite and developer authentication.'
}
