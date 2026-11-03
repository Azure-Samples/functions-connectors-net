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
