$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-settings.ps1')
$target = Join-Path $PSScriptRoot '..\..\local.settings.json'
if (Test-LocalSettingsFile $target) {
    Write-Host 'Existing local.settings.json preserved.'
    return
}
$settings = @{
    IsEncrypted = $false
    Values = @{
        AzureWebJobsStorage = 'UseDevelopmentStorage=true'
        FUNCTIONS_WORKER_RUNTIME = 'dotnet-isolated'
    }
}
Write-LocalSettings $target $settings
