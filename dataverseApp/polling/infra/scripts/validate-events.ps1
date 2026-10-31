$ErrorActionPreference = 'Stop'
$raw = azd env get-values --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the selected azd environment.' }
$values = ($raw -join "`n") | ConvertFrom-Json
if ([string]$values.DATAVERSE_ENABLE_ACTION_TRIGGER -eq 'true') {
    foreach ($name in @('DATAVERSE_EVENT_CATALOG', 'DATAVERSE_EVENT_CATEGORY', 'DATAVERSE_EVENT_TABLE', 'DATAVERSE_EVENT_ACTION')) {
        if ([string]::IsNullOrWhiteSpace([string]$values.$name)) {
            throw "$name is required when DATAVERSE_ENABLE_ACTION_TRIGGER=true."
        }
    }
}
