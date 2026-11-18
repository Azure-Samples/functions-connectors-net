#requires -Version 7.3
param(
    [string] $CallbackBaseUrl,
    [string] $LocalHostId,
    [switch] $Reconfigure,
    [switch] $ForceLocalSettings
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-settings.ps1')
. (Join-Path $PSScriptRoot '../../../infra/scripts/setup.ps1')

Invoke-DataverseSetup -Mode Webhook -SampleRoot (Join-Path $PSScriptRoot '../..') `
    -CallbackBaseUrl $CallbackBaseUrl -LocalHostId $LocalHostId `
    -Reconfigure:$Reconfigure -ForceLocalSettings:$ForceLocalSettings
