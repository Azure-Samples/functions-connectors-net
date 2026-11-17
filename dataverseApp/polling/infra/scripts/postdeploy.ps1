#requires -Version 7.3
param(
    [switch] $Reconfigure,
    [switch] $ForceLocalSettings
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-settings.ps1')
. (Join-Path $PSScriptRoot '../../../infra/scripts/setup.ps1')

Invoke-DataverseSetup -Mode Poll -SampleRoot (Join-Path $PSScriptRoot '../..') `
    -Reconfigure:$Reconfigure -ForceLocalSettings:$ForceLocalSettings
