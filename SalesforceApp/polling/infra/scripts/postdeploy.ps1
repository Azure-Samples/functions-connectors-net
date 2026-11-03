$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'create-local-settings.ps1')
Write-Host 'Poll configurations are provisioned. Manually authorize the Salesforce connection for the approved org before testing.'
