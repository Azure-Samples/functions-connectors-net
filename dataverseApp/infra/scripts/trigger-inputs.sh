#!/usr/bin/env bash

dv_json() {
    jq -L "$dv_script_dir" --slurpfile swagger "$dv_swagger" "$@"
}

dv_error() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

dv_choice() {
    local label="$1" choices="$2" answer number count
    count=$(jq 'length' <<< "$choices") || return
    printf '\n%s\n' "$label" >&2
    jq -r 'to_entries[] | "  [\(.key + 1)] \(.value.label)"' <<< "$choices" >&2 || return
    while true; do
        printf 'Enter number (1-%s), or press Enter to skip this trigger: ' "$count" >&2
        IFS= read -r answer <&3 || answer=''
        [ -n "$(printf '%s' "$answer" | tr -d '[:space:]')" ] || return 20
        if [[ "$answer" =~ ^[0-9]+$ ]] && [ "${#answer}" -le 9 ]; then
            number=$((10#$answer))
            if [ "$number" -ge 1 ] && [ "$number" -le "$count" ]; then
                jq -c --argjson index "$((number - 1))" '.[$index].value' <<< "$choices"
                return
            fi
        fi
        printf 'Choose one of the listed numbers.\n' >&2
    done
}

dv_text() {
    local label="$1" schema="$2" answer value kind
    kind=$(jq -r '.type' <<< "$schema") || return
    while true; do
        printf '%s (Enter to skip this trigger): ' "$label" >&2
        IFS= read -r answer <&3 || answer=''
        answer=$(printf '%s' "$answer" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -n "$answer" ] || return 20
        if [ "$kind" = string ]; then
            value=$(jq -cn --arg value "$answer" '$value') || return
        elif [[ "$kind" = integer || "$kind" = number ]]; then
            value=$(jq -cen --arg value "$answer" '$value | tonumber' 2>/dev/null) || {
                printf 'Enter a valid number.\n' >&2; continue;
            }
        else dv_error "Unsupported connector input type: $kind"; return 1; fi
        if dv_json -e --argjson schema "$schema" --argjson value "$value" \
            'include "trigger-inputs"; dvvalid($swagger[0]; $schema; $value)' <<< '{}' >/dev/null; then
            printf '%s\n' "$value"; return
        fi
        printf 'The value does not match the connector input constraints.\n' >&2
    done
}

dv_field() {
    local schema label="$2" answers="$3" supplied="${4:-null}"
    local result name field title value extension values response choices status
    schema=$(dv_json -cn --argjson schema "$1" 'include "trigger-inputs"; dvresolve($swagger[0]; $schema)') || return
    if [ "$supplied" != null ] && [ "$(jq -r '.type' <<< "$schema")" != object ]; then
        printf '%s\n' "$supplied"; return
    fi
    if [ "$supplied" = null ] && jq -e 'has("default")' <<< "$schema" >/dev/null; then
        jq -c '.default' <<< "$schema"; return
    fi
    if jq -e '.type == "object" or .properties != null' <<< "$schema" >/dev/null; then
        result="$supplied"
        [ "$result" != null ] || result='{}'
        dv_json -cn --argjson schema "$schema" \
            'include "trigger-inputs"; dvfieldorder($swagger[0]; $schema)' > "$dv_work/field-order-check.json" || return
        while IFS= read -r name; do
            field=$(dv_json -cn --argjson schema "$schema" --arg name "$name" \
                'include "trigger-inputs"; dvresolve($swagger[0]; $schema.properties[$name])') || return
            if jq -e '.["x-ms-notification-url"] == true or .readOnly == true' <<< "$field" >/dev/null; then continue; fi
            if jq -e '.["x-ms-visibility"] == "internal"' <<< "$field" >/dev/null; then
                if jq -e 'has("default")' <<< "$field" >/dev/null; then
                    result=$(jq -c --arg name "$name" --argjson field "$field" '.[$name] = $field.default' <<< "$result") || return
                fi
                continue
            fi
            if ! jq -e --arg name "$name" --argjson field "$field" \
                '(.required // [] | index($name)) != null or $field.required == true' <<< "$schema" >/dev/null; then continue; fi
            title=$(jq -r --arg name "$name" '.["x-ms-summary"] // $name' <<< "$field") || return
            answers=$(jq -c --argjson body "$result" '.body = $body | .subscriptionRequest = $body' <<< "$answers") || return
            supplied=$(jq -c --arg name "$name" '.[$name]' <<< "$result") || return
            value=$(dv_field "$field" "$title" "$answers" "$supplied") || return $?
            result=$(jq -c --arg name "$name" --argjson value "$value" '.[$name] = $value' <<< "$result") || return
        done < <(dv_json -rn --argjson schema "$schema" 'include "trigger-inputs"; dvfieldorder($swagger[0]; $schema)[]')
        printf '%s\n' "$result"; return
    fi
    extension=$(jq -c -L "$dv_script_dir" 'include "trigger-inputs"; dvdynamic' <<< "$schema") || return
    if [ "$extension" != null ]; then
        values=$(jq -cn -L "$dv_script_dir" --argjson extension "$extension" --argjson answers "$answers" \
            'include "trigger-inputs"; dvbindings($extension; $answers)') || return
        response=$(dv_picker "$(jq -r '.operationId' <<< "$extension")" "$values") || return
        choices=$(jq -cn -L "$dv_script_dir" --argjson extension "$extension" --argjson response "$response" \
            'include "trigger-inputs"; dvchoices($extension; $response)') || return
        if [ "$(jq 'length' <<< "$choices")" -gt 0 ]; then
            dv_choice "$label" "$choices"; return $?
        fi
        printf 'No usable options returned for %s. Enter its connector identifier manually, or leave blank to skip.\n' "$label" >&2
    elif jq -e 'has("enum")' <<< "$schema" >/dev/null; then
        choices=$(jq -c '[.enum[] | {value: ., label: tostring}]' <<< "$schema") || return
        dv_choice "$label" "$choices"; return $?
    elif [ "$(jq -r '.type' <<< "$schema")" = boolean ]; then
        dv_choice "$label" '[{"value":true,"label":"Yes"},{"value":false,"label":"No"}]'; return $?
    fi
    dv_text "$label" "$schema"
}

dv_collect_trigger() {
    local definition="$1" operation answers='{}' parameters='[]' parameter name label value body status
    operation=$(dv_json -cn --arg id "$(jq -r '.operationName' <<< "$definition")" \
        'include "trigger-inputs"; dvoperation($swagger[0]; $id)') || return
    if [ "$(jq -r '.functionName' <<< "$definition")" = OnDataverseRowChanged ]; then
        answers='{"body":{"message":7,"scope":4}}'
    fi
    while IFS= read -r parameter; do
        name=$(jq -r '.name' <<< "$parameter") || return
        if [ "$(jq -r '.in' <<< "$parameter")" = body ]; then
            body=$(jq -c '.body // {}' <<< "$answers") || return
            answers=$(jq -c --arg name "$name" --argjson body "$body" '.body = $body | .[$name] = $body' <<< "$answers") || return
            value=$(dv_field "$(jq -c '.schema' <<< "$parameter")" 'Subscription details' "$answers" "$body") || return $?
            name=body
        else
            label=$(jq -r '.["x-ms-summary"] // .name' <<< "$parameter") || return
            value=$(dv_field "$parameter" "$label" "$answers") || return $?
            answers=$(jq -c --arg name "$name" --argjson value "$value" '.[$name] = $value' <<< "$answers") || return
        fi
        parameters=$(jq -c --arg name "$name" --argjson value "$value" '. + [{name:$name,value:$value}]' <<< "$parameters") || return
    done < <(jq -c -L "$dv_script_dir" 'include "trigger-inputs"; .parameters[] | select(.name != "connectionId" and (dvhidden | not) and .required == true)' <<< "$operation")
    jq -cn --argjson definition "$definition" --argjson parameters "$parameters" '$definition + {parameters:$parameters}'
}

dv_collect() {
    local selected='[]' definition configure trigger status
    printf 'Choose the combined row-change trigger OR the separate added/modified/deleted triggers you need.\n' >&2
    printf 'Configuring both for the same source produces overlapping (duplicate) events. Action-performed is independent.\n' >&2
    while IFS= read -r definition; do
        jq -r '"\n\(.functionName) (\(.operationName))"' <<< "$definition" >&2 || return
        status=0
        configure=$(dv_choice 'Configure this trigger?' '[{"label":"Configure","value":true},{"label":"Skip","value":false}]') || status=$?
        if [ "$status" = 20 ] || [ "$configure" = false ]; then continue; fi
        [ "$status" = 0 ] || return "$status"
        trigger=$(dv_collect_trigger "$definition") || status=$?
        if [ "$status" = 20 ]; then
            printf 'Skipped %s: no answer entered.\n' "$(jq -r '.functionName' <<< "$definition")" >&2; continue
        fi
        [ "$status" = 0 ] || return "$status"
        selected=$(jq -c --argjson trigger "$trigger" '. + [$trigger]' <<< "$selected") || return
    done < <(jq -cn -L "$dv_script_dir" 'include "trigger-inputs"; dvdefinitions[]')
    printf '%s\n' "$selected"
}
