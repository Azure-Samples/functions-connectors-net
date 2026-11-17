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
