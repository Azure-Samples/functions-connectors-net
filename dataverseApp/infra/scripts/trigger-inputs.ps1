function ConvertFrom-DataverseJson {
    param([string] $Json)
    function Convert-Element($Element) {
        switch ($Element.ValueKind) {
            Object {
                $result = [ordered]@{}
                foreach ($property in $Element.EnumerateObject()) { $result[$property.Name] = Convert-Element $property.Value }
                return $result
            }
            Array { return ,@($Element.EnumerateArray() | ForEach-Object { Convert-Element $_ }) }
            String { return $Element.GetString() }
            Number {
                $integer = 0L
                if ($Element.TryGetInt64([ref]$integer)) { return $integer }
                return $Element.GetDouble()
            }
            True { return $true }
            False { return $false }
            default { return $null }
        }
    }
    # Keep connector identifiers opaque, including strings that look like dates.
    $document = [System.Text.Json.JsonDocument]::Parse($Json)
    try { return Convert-Element $document.RootElement } finally { $document.Dispose() }
}

function Get-DataverseValue {
    param($Value, [string] $Path)
    if (-not $Path) { return ,$Value }
    if ($Value -is [Collections.IDictionary] -and $Value.Contains($Path)) { return ,$Value[$Path] }
    foreach ($part in ($Path -split '[/\.]' | Where-Object { $_ })) {
        if ($Value -isnot [Collections.IDictionary] -or -not $Value.Contains($part)) { return $null }
        $Value = $Value[$part]
    }
    return ,$Value
}

function Resolve-DataverseSchema {
    param($Swagger, $Schema)
    if ($Schema['$ref']) {
        if (-not $Schema['$ref'].StartsWith('#/')) { throw 'External connector schema references are not supported.' }
        $target = Get-DataverseValue $Swagger $Schema['$ref'].Substring(2)
        if ($null -eq $target) { throw 'Missing connector schema reference.' }
        $result = [ordered]@{}
        foreach ($entry in (Resolve-DataverseSchema $Swagger $target).GetEnumerator()) { $result[$entry.Key] = $entry.Value }
        foreach ($entry in $Schema.GetEnumerator()) { if ($entry.Key -ne '$ref') { $result[$entry.Key] = $entry.Value } }
        return $result
    }
    return $Schema
}

function Get-DataverseOperation {
    param($Swagger, [string] $Id)
    foreach ($route in $Swagger.paths.Keys) {
        foreach ($method in @('get', 'post', 'put', 'patch', 'delete')) {
            $definition = $Swagger.paths[$route][$method]
            if ($definition.operationId -ceq $Id) {
                return @{
                    route = $route
                    method = $method.ToUpperInvariant()
                    parameters = @(
                        @($Swagger.paths[$route].parameters) + @($definition.parameters) |
                            Where-Object { $null -ne $_ } |
                            ForEach-Object { Resolve-DataverseSchema $Swagger $_ }
                    )
                }
            }
        }
    }
    throw "The connector does not expose $Id in this region."
}

function New-DataverseOperationRequest {
    param($Swagger, [string] $Id, $Values)
    $operation = Get-DataverseOperation $Swagger $Id
    $request = @{ method = $operation.method; path = $operation.route -replace '^/\{connectionId\}', '' }
    foreach ($parameter in $operation.parameters) {
        if ($parameter.name -eq 'connectionId') { continue }
        $value = if ($Values.Contains($parameter.name)) { $Values[$parameter.name] } else { $parameter.default }
        if ($null -eq $value) {
            if ($parameter.required) { throw "Picker $Id requires $($parameter.name)." }
            continue
        }
        switch ($parameter.in) {
            path {
                $encoded = [uri]::EscapeDataString([string]$value)
                if ($parameter['x-ms-url-encoding'] -eq 'double') { $encoded = [uri]::EscapeDataString($encoded) }
                $request.path = $request.path.Replace("{$($parameter.name)}", $encoded)
            }
            query {
                if (-not $request.queries) { $request.queries = @{} }
                $request.queries[$parameter.name] = $value
            }
            header {
                if (-not $request.headers) { $request.headers = @{} }
                $request.headers[$parameter.name] = $value
            }
            body { $request.body = $value }
        }
    }
    if ($request.path -match '\{[^}]+\}') { throw "Unresolved picker parameters for $Id." }
    return $request
}

function Read-DataverseChoice {
    param([string] $Label, [array] $Choices)
    Write-Host "`n$Label"
    for ($index = 0; $index -lt $Choices.Count; $index++) { Write-Host "  [$($index + 1)] $($Choices[$index].label)" }
    while ($true) {
        $answer = Read-Host "Enter number (1-$($Choices.Count)), or press Enter to skip this trigger"
        if ([string]::IsNullOrWhiteSpace($answer)) { throw [OperationCanceledException]::new($Label) }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Choices.Count) {
            return ,$Choices[$number - 1].value
        }
        Write-Host 'Choose one of the listed numbers.'
    }
}

function Test-DataverseInput {
    param($Swagger, $Schema, $Value)
    $schema = Resolve-DataverseSchema $Swagger $Schema
    if ($null -eq $Value) { return $false }
    if ($schema.Contains('enum') -and $Value -cnotin $schema.enum) { return $false }
    switch ($schema.type) {
        object {
            if ($Value -isnot [Collections.IDictionary]) { return $false }
            foreach ($name in $schema.required) {
                $field = Resolve-DataverseSchema $Swagger $schema.properties[$name]
                if ($field['x-ms-notification-url'] -or $field.readOnly -or $field['x-ms-visibility'] -eq 'internal') { continue }
                if (-not $Value.Contains($name)) { return $false }
            }
            foreach ($name in $Value.Keys) {
                if (-not $schema.properties.Contains($name) -or
                    -not (Test-DataverseInput $Swagger $schema.properties[$name] $Value[$name])) { return $false }
            }
        }
        array {
            if ($Value -isnot [array] -or ($schema.Contains('minItems') -and $Value.Count -lt $schema.minItems) -or
                ($schema.Contains('maxItems') -and $Value.Count -gt $schema.maxItems)) { return $false }
            foreach ($item in $Value) { if (-not (Test-DataverseInput $Swagger $schema.items $item)) { return $false } }
        }
        { $_ -in @('integer', 'number') } {
            if ($Value -isnot [ValueType] -or $Value -is [bool] -or
                -not [double]::IsFinite([double]$Value) -or
                ($schema.type -eq 'integer' -and [math]::Truncate([double]$Value) -ne $Value) -or
                ($schema.Contains('minimum') -and $Value -lt $schema.minimum) -or
                ($schema.Contains('maximum') -and $Value -gt $schema.maximum)) { return $false }
        }
        boolean { if ($Value -isnot [bool]) { return $false } }
        string {
            if ($Value -isnot [string] -or
                ($schema.Contains('minLength') -and $Value.Length -lt $schema.minLength) -or
                ($schema.Contains('maxLength') -and $Value.Length -gt $schema.maxLength) -or
                ($schema.pattern -and $Value -cnotmatch $schema.pattern)) { return $false }
        }
        default { return $false }
    }
    return $true
}

function Read-DataverseText {
    param([string] $Label, $Swagger, $Schema)
    while ($true) {
        $answer = Read-Host "$Label (Enter to skip this trigger)"
        if ([string]::IsNullOrWhiteSpace($answer)) { throw [OperationCanceledException]::new($Label) }
        $value = $answer.Trim()
        if ($Schema.type -in @('integer', 'number')) {
            $number = 0.0
            if (-not [double]::TryParse($value, [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
                Write-Host 'Enter a valid number.'
                continue
            }
            $value = $number
        }
        if (Test-DataverseInput $Swagger $Schema $value) { return $value }
        Write-Host 'The value does not match the connector input constraints.'
    }
}

function Get-DataverseDynamicSpec {
    param($Schema)
    $extension = $Schema['x-ms-dynamic-list']
    if (-not $extension) { $extension = $Schema['x-ms-dynamic-values'] }
    if ($extension -and -not $extension.operationId) {
        $extension = if ($extension.dynamicState.extension) { $extension.dynamicState.extension } else { $extension.dynamicState }
    }
    return $extension
}

function Get-DataverseReferences {
    param($Swagger, $Schema)
    $schema = Resolve-DataverseSchema $Swagger $Schema
    $extension = Get-DataverseDynamicSpec $schema
    foreach ($binding in $extension.parameters.Values) {
        if ($binding -is [Collections.IDictionary]) {
            if ($binding.parameterReference) { $binding.parameterReference } elseif ($binding.parameter) { $binding.parameter }
        }
    }
    foreach ($field in $schema.properties.Values) { Get-DataverseReferences $Swagger $field }
}

function Read-DataverseField {
    param($Swagger, $Schema, [string] $Label, $Answers, [scriptblock] $InvokePicker, $Supplied)
    $schema = Resolve-DataverseSchema $Swagger $Schema
    if ($null -ne $Supplied -and $schema.type -ne 'object') { return ,$Supplied }
    if ($schema.Contains('default') -and $null -eq $Supplied) { return ,$schema.default }
    if ($schema.type -eq 'object' -or $schema.properties) {
        $result = if ($null -ne $Supplied) { $Supplied } else { [ordered]@{} }
        # Both Swagger body aliases and unqualified references must see answers as they are collected.
        $Answers.body = $result
        $remaining = [Collections.Generic.List[string]]::new()
        foreach ($name in $schema.properties.Keys) { $remaining.Add($name) }
        while ($remaining.Count) {
            $next = $null
            foreach ($name in $remaining) {
                $references = @(Get-DataverseReferences $Swagger $schema.properties[$name])
                $dependencies = @($references | ForEach-Object { ($_ -split '[/\.]')[-1] } | Where-Object { $_ -ne $name -and $_ -in $remaining })
                if (-not $dependencies.Count) { $next = $name; break }
            }
            if ($null -eq $next) { throw "Cyclic connector picker dependencies in $Label." }
            [void]$remaining.Remove($next)
            $field = Resolve-DataverseSchema $Swagger $schema.properties[$next]
            if ($field['x-ms-notification-url'] -or $field.readOnly) { continue }
            if ($field['x-ms-visibility'] -eq 'internal') {
                if ($field.Contains('default')) { $result[$next] = $field.default }
                continue
            }
            if ($next -notin $schema.required -and $field.required -ne $true) { continue }
            $title = if ($field['x-ms-summary']) { $field['x-ms-summary'] } else { $next }
            $result[$next] = Read-DataverseField $Swagger $field $title $Answers $InvokePicker $result[$next]
        }
        return $result
    }
    $extension = Get-DataverseDynamicSpec $schema
    if ($extension) {
        if (-not $extension.operationId) { throw "Missing connector picker operation for $Label." }
        $values = [ordered]@{}
        foreach ($name in $extension.parameters.Keys) {
            $binding = $extension.parameters[$name]
            if ($binding -is [Collections.IDictionary]) {
                $reference = if ($binding.parameterReference) { $binding.parameterReference } else { $binding.parameter }
                if ($reference) {
                    $value = Get-DataverseValue $Answers $reference
                    if ($null -eq $value) { $value = Get-DataverseValue $Answers.body $reference }
                    if ($null -eq $value) { throw "Select $reference before resolving $($extension.operationId)." }
                } elseif ($binding.Contains('value')) { $value = $binding.value } else { throw 'Unsupported connector picker binding.' }
            } else { $value = $binding }
            $values[$name] = $value
        }
        $response = & $InvokePicker $extension.operationId $values
        $collectionPath = $extension.itemsPath
        if (-not $collectionPath) { $collectionPath = $extension['value-collection'] }
        $items = if ($collectionPath) { Get-DataverseValue $response $collectionPath } elseif ($response -is [array]) { ,$response } else { ,$response.value }
        if ($items -isnot [array]) { throw "The connector returned a malformed list for $Label." }
        $valuePath = if ($extension.itemValuePath) { $extension.itemValuePath } else { $extension['value-path'] }
        $titlePath = if ($extension.itemTitlePath) { $extension.itemTitlePath } else { $extension['value-title'] }
        $choices = @(
            foreach ($item in $items) {
                $value = Get-DataverseValue $item $valuePath
                $title = Get-DataverseValue $item $titlePath
                if ($value -is [string] -or $value -is [ValueType]) {
                    if ($value -is [string] -and -not $value -and -not $title) { continue }
                    @{ value = $value; label = $(if ($title) { [string]$title } else { [string]$value }) }
                }
            }
        )
        if ($choices.Count) { return ,(Read-DataverseChoice $Label $choices) }
        Write-Host "No usable options returned for $Label. Enter its connector identifier manually, or leave blank to skip."
    } elseif ($schema.Contains('enum')) {
        return ,(Read-DataverseChoice $Label @($schema.enum | ForEach-Object { @{ value = $_; label = [string]$_ } }))
    } elseif ($schema.type -eq 'boolean') {
        return Read-DataverseChoice $Label @(@{ value = $true; label = 'Yes' }, @{ value = $false; label = 'No' })
    }
    if ($schema.type -notin @('string', 'integer', 'number')) { throw "Unsupported connector input type for $Label." }
    return Read-DataverseText $Label $Swagger $schema
}

function Get-DataverseTriggerDefinitions {
    @(
        @{ functionName = 'OnDataverseRowChanged'; operationName = 'SubscribeWebhookTrigger' }
        @{ functionName = 'OnDataverseActionPerformed'; operationName = 'BusinessEventsTrigger' }
        @{ functionName = 'OnDataverseRowAdded'; operationName = 'SubscribeOnNewItems' }
        @{ functionName = 'OnDataverseRowModified'; operationName = 'SubscribeOnUpdatedItems' }
        @{ functionName = 'OnDataverseRowDeleted'; operationName = 'SubscribeOnDeletedItems' }
    )
}

function Read-DataverseTriggers {
    param($Swagger, [scriptblock] $InvokePicker)
    Write-Host 'Choose the combined row-change trigger OR the separate added/modified/deleted triggers you need.'
    Write-Host 'Configuring both for the same source produces overlapping (duplicate) events. Action-performed is independent.'
    $selected = @(
        foreach ($definition in Get-DataverseTriggerDefinitions) {
            Write-Host "`n$($definition.functionName) ($($definition.operationName))"
            try {
                $configure = Read-DataverseChoice 'Configure this trigger?' @(@{ label = 'Configure'; value = $true }, @{ label = 'Skip'; value = $false })
                if (-not $configure) { continue }
                $operation = Get-DataverseOperation $Swagger $definition.operationName
                $answers = [ordered]@{}
                if ($definition.functionName -eq 'OnDataverseRowChanged') { $answers.body = [ordered]@{ message = 7; scope = 4 } }
                $parameters = [Collections.Generic.List[object]]::new()
                foreach ($parameter in $operation.parameters) {
                    if ($parameter.name -eq 'connectionId' -or $parameter['x-ms-visibility'] -eq 'internal' -or $parameter.readOnly) { continue }
                    if (-not $parameter.required) { continue }
                    if ($parameter.in -eq 'body') {
                        if ($null -eq $answers.body) { $answers.body = [ordered]@{} }
                        $answers[$parameter.name] = $answers.body
                        $value = Read-DataverseField $Swagger $parameter.schema 'Subscription details' $answers $InvokePicker $answers.body
                        $parameters.Add(@{ name = 'body'; value = $value })
                    } else {
                        $label = if ($parameter['x-ms-summary']) { $parameter['x-ms-summary'] } else { $parameter.name }
                        $value = Read-DataverseField $Swagger $parameter $label $answers $InvokePicker
                        $answers[$parameter.name] = $value
                        $parameters.Add(@{ name = $parameter.name; value = $value })
                    }
                }
                @{ functionName = $definition.functionName; operationName = $definition.operationName; parameters = @($parameters.ToArray()) }
            } catch [OperationCanceledException] {
                Write-Host "Skipped $($definition.functionName): no answer entered."
            }
        }
    )
    return ,$selected
}

function Assert-DataverseSelections {
    param($Triggers, $Swagger)
    if ($Triggers -isnot [array] -or -not $Triggers.Count) { throw 'Select at least one trigger; no configurations have been changed.' }
    $seen = @{}
    foreach ($trigger in $Triggers) {
        $definition = @(Get-DataverseTriggerDefinitions | Where-Object { $_.functionName -ceq $trigger.functionName -and $_.operationName -ceq $trigger.operationName })
        if ($definition.Count -ne 1 -or $seen.ContainsKey([string]$trigger.functionName) -or $trigger.parameters -isnot [array]) {
            throw 'Invalid saved Dataverse selections. Clear the saved inputs and rerun setup.'
        }
        $seen[$trigger.functionName] = $true
        $expected = @{}
        foreach ($parameter in (Get-DataverseOperation $Swagger $trigger.operationName).parameters) {
            if ($parameter.name -eq 'connectionId' -or $parameter['x-ms-visibility'] -eq 'internal' -or $parameter.readOnly) { continue }
            $name = if ($parameter.in -eq 'body') { 'body' } else { $parameter.name }
            $expected[$name] = $parameter
        }
        $provided = @{}
        foreach ($parameter in $trigger.parameters) {
            if (-not $expected.ContainsKey([string]$parameter.name) -or $provided.ContainsKey([string]$parameter.name)) { throw 'Invalid saved Dataverse parameter.' }
            $provided[$parameter.name] = $true
            $schema = if ($parameter.name -eq 'body') { $expected[$parameter.name].schema } else { $expected[$parameter.name] }
            if (-not (Test-DataverseInput $Swagger $schema $parameter.value)) { throw "Invalid saved input for $($trigger.functionName): $($parameter.name)." }
        }
        foreach ($name in $expected.Keys) {
            if ($expected[$name].required -and -not $provided.ContainsKey($name)) { throw "Missing saved Dataverse input: $name." }
        }
    }
}
