#requires -Version 7.3
function New-PrivateStagingStream {
    param([string] $Path)
    if ($IsWindows) {
        $security = [Security.AccessControl.FileSecurity]::new()
        $security.SetAccessRuleProtection($true, $false)
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent().User,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow))
        return [IO.FileSystemAclExtensions]::Create(
            [IO.FileInfo]::new($Path), [IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None,
            4096, [IO.FileOptions]::None, $security)
    }
    $options = [IO.FileStreamOptions]::new()
    $options.Mode = [IO.FileMode]::CreateNew
    $options.Access = [IO.FileAccess]::Write
    $options.Share = [IO.FileShare]::None
    $options.UnixCreateMode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
    return [IO.File]::Open($Path, $options)
}

function Remove-OwnedStagingFile {
    param([string] $Path)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
}

function Test-LocalSettingsFile {
    param([string] $Path)
    try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
    catch [Management.Automation.ItemNotFoundException] { return $false }
    if ($item -isnot [IO.FileInfo] -or $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'local.settings.json must be a regular file, not a directory or link.'
    }
    return $true
}

function Write-LocalSettings {
    param([hashtable] $Values, [switch] $ForceLocalSettings)
    $path = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../local.settings.json'))
    $exists = Test-LocalSettingsFile $path
    if ($exists -and -not $ForceLocalSettings) {
        Write-Host 'Existing local.settings.json preserved byte-for-byte.'
        return
    }
    $json = @{ IsEncrypted = $false; Values = $Values } | ConvertTo-Json -Depth 5
    $temp = Join-Path ([IO.Path]::GetDirectoryName($path)) ".local-settings-$([guid]::NewGuid().ToString('N')).tmp"
    $failure = $null
    $tempOwned = $false
    try {
        $stream = New-PrivateStagingStream $temp
        $tempOwned = $true
        $streamFailure = $null
        try {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } catch { $streamFailure = $_; throw }
        finally {
            try { $stream.Dispose() }
            catch {
                if ($null -eq $streamFailure) { throw 'Could not close owned local-settings staging stream.' }
                Write-Warning 'Could not close owned staging stream; original failure preserved.'
            }
        }
        $null = Test-LocalSettingsFile $path
        [IO.File]::Move($temp, $path, $ForceLocalSettings.IsPresent)
        Write-Host 'Created ignored local.settings.json using developer credentials and Azurite.'
    } catch {
        $failure = $_
        throw
    } finally {
        try { if ($tempOwned) { Remove-OwnedStagingFile $temp } }
        catch {
            if ($null -eq $failure) { throw 'Could not clean owned local-settings staging file.' }
            Write-Warning 'Could not clean owned local-settings staging file; original failure preserved.'
        }
    }
}
