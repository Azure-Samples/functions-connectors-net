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

function Test-LocalSettingsFile {
    param([string] $Path)
    try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { return $false }
    if ($item -isnot [IO.FileInfo] -or $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'local.settings.json must be a regular file, not a directory or link.'
    }
    return $true
}

function Write-LocalSettings {
    param([hashtable] $Values, [switch] $Force)
    $path = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../local.settings.json'))
    if ((Test-LocalSettingsFile $path) -and -not $Force) {
        Write-Host 'Existing local.settings.json preserved byte-for-byte.'
        return
    }
    $temp = Join-Path ([IO.Path]::GetDirectoryName($path)) ".local-settings-$([guid]::NewGuid().ToString('N')).tmp"
    $ownedFiles = [Collections.Generic.List[string]]::new()
    $failure = $null
    try {
        Write-PrivateJsonFile $temp @{ IsEncrypted = $false; Values = $Values } $ownedFiles
        $null = Test-LocalSettingsFile $path
        [IO.File]::Move($temp, $path, $Force.IsPresent)
        Write-Host 'Created ignored local.settings.json for developer authentication and Azurite.'
    } catch {
        $failure = $_
        throw
    } finally {
        Remove-OwnedStaging $ownedFiles $failure
    }
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
