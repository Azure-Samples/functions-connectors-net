#!/usr/bin/env bash

dv_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$dv_script_dir/trigger-inputs.sh"

dv_hash() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d ' ' -f 1
    else shasum -a 256 | cut -d ' ' -f 1; fi
}

dv_rest() {
    local method="$1" url="$2" body="${3:-}" request response
    local arguments=(rest --method "$method" --url "$url" --subscription "$dv_subscription" -o none)
    response=$(mktemp "$dv_work/response.XXXXXXXX") || return
    arguments+=(--output-file "$response")
    if [ -n "$body" ]; then
        request=$(mktemp "$dv_work/request.XXXXXXXX") || return
        printf '%s\n' "$body" > "$request" || return
        arguments+=(--body "@$request")
    fi
    az "${arguments[@]}" 2>/dev/null || {
        dv_error "Dataverse $method request failed. Check source permissions and namespace status; request secrets were not logged."
        return 1
    }
    if [ -s "$response" ]; then jq -c '.' "$response"; else printf 'null\n'; fi
}

dv_picker() {
    local id="$1" values="$2" hash request response cache
    hash=$(printf '%s:%s' "$id" "$(jq -Sc '.' <<< "$values")" | dv_hash) || return
    cache="$dv_work/picker-$hash.json"
    if [ ! -f "$cache" ]; then
        request=$(dv_json -cn --arg id "$id" --argjson values "$values" \
            'include "trigger-inputs"; {request:dvrequest($swagger[0]; $id; $values)}') || return
        response=$(dv_rest POST "$dv_connection_url/dynamicInvoke?api-version=2026-05-01-preview" "$request") || return
        jq -ce '
          if (.response.statusCode | tostring | IN("200","201","OK","Created")) then
            .response.body | if type == "string" then fromjson else . end
          else error("Connector picker failed; no values were guessed.") end
        ' <<< "$response" > "$cache" || return
    fi
    cat "$cache"
}

dv_consent() {
    local connection link attempt
    connection=$(dv_rest GET "$dv_connection_url?api-version=2026-05-01-preview") || return
    if [ "$(jq -r '.properties.overallStatus' <<< "$connection")" = Connected ]; then return; fi
    printf 'Authorize Dataverse with an account permitted to register the selected source events.\n' >&2
    link=$(az connector-namespace connection list-consent-links --subscription "$dv_subscription" \
        -g "$dv_group" --namespace "$dv_namespace" --connection-name "$dv_connection" \
        --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" --query 'value[0].link' -o tsv 2>/dev/null) || link=''
    if [ -z "$link" ] || [ "$link" = null ]; then
        link=$(az connector-namespace connection list-consent-links --subscription "$dv_subscription" \
            -g "$dv_group" --namespace "$dv_namespace" --connection-name "$dv_connection" \
            --parameters "[{parameterName:token,redirectUrl:'https://connectors.azure.com'}]" --query link -o tsv 2>/dev/null) || return
    fi
    [ -n "$link" ] && [ "$link" != null ] || { dv_error 'Could not obtain a Dataverse consent link.'; return 1; }
    printf 'Consent URL: %s\n' "$link" >&2
    if command -v open >/dev/null 2>&1; then open "$link" >/dev/null 2>&1 || true
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$link" >/dev/null 2>&1 || true; fi
    for ((attempt=0; attempt<100; attempt++)); do
        sleep 3
        connection=$(dv_rest GET "$dv_connection_url?api-version=2026-05-01-preview") || return
        if [ "$(jq -r '.properties.overallStatus' <<< "$connection")" = Connected ]; then return; fi
    done
    dv_error 'Timed out waiting for Dataverse authorization. Complete consent and rerun azd hooks run postdeploy.'
}

dv_wait_trigger() {
    local resource="$1" url="$2" state="$3" need_endpoint="$4" attempt
    for ((attempt=0; attempt<30; attempt++)); do
        if jq -e '.properties.provisioningState | IN("Failed","Canceled","Cancelled")' <<< "$resource" >/dev/null; then break; fi
        if jq -e --arg state "$state" --argjson needs "$need_endpoint" '
          .properties.state == $state and
          (.properties.provisioningState | IN("Accepted","Creating","Updating","Running") | not) and
          ($needs == false or (.properties.pollingEndpoints.receiveUri | type == "string" and length > 0))
        ' <<< "$resource" >/dev/null; then printf '%s\n' "$resource"; return; fi
        sleep 2
        resource=$(dv_rest GET "$url") || return
    done
    dv_error "Trigger did not finish provisioning in state $state. Inspect its source-registration status before retrying."
}

dv_poll_endpoint() {
    jq -ern --arg uri "$1" --arg name "$2" '
      $uri | capture("^https://(?<host>[^/?#@]+)(?<path>/[^?#]*)(?:\\?[^#]*)?$") as $uri
      | ("/triggerconfigs/" + $name + "/receive") as $suffix
      | if ($uri.path | ascii_downcase | endswith($suffix | ascii_downcase)) then
          $uri.path[: -($suffix | length)] | rtrimstr("/") as $path
          | "https://" + $uri.host + (if $path == "/api" then "" else $path end)
        else error("Unexpected Poll receive URI path.") end
    '
}

dv_local_key() {
    local settings="$dv_app_dir/local.settings.json" storage host="$1" names candidate file
    [ -f "$settings" ] && [ ! -L "$settings" ] || {
        dv_error 'Create a regular local.settings.json and start the local host first.'; return 1;
    }
    storage=$(jq -er '.Values.AzureWebJobsStorage | select(type == "string")' "$settings") || return
    if ! jq -en --arg storage "$storage" '$storage | test("^UseDevelopmentStorage=true(?:;|$)|BlobEndpoint=http://(?:127\\.0\\.0\\.1|localhost|\\[::1\\]):"; "i")' >/dev/null; then
        dv_error 'Automatic local-key retrieval requires a local Azurite AzureWebJobsStorage connection.'; return 1
    fi
    if [ -z "$host" ]; then host=$(jq -r '.Values.AzureFunctionsWebHost__hostid // ""' "$settings") || return; fi
    if [ -z "$host" ]; then host=$(jq -r '.id // ""' "$dv_app_dir/host.json") || return; fi
    names=$(az storage blob list --container-name azure-webjobs-secrets --connection-string "$storage" \
        --query '[].name' -o json 2>/dev/null) || {
        dv_error 'Could not read local host secrets. Start Azurite and func start --enableAuth first.'; return 1;
    }
    candidate=$(jq -er --arg host "$host" '
      [ .[] | select(test("^[^/]+/host\\.json$"))
        | select($host == "" or . == (($host | ascii_downcase) + "/host.json")) ]
      | if length == 1 then .[0] else error("Could not identify one local host key file. Pass --local-host-id if Azurite contains multiple hosts.") end
    ' <<< "$names") || return
    file=$(mktemp "$dv_work/local-key.XXXXXXXX") || return
    az storage blob download --container-name azure-webjobs-secrets --name "$candidate" \
        --connection-string "$storage" --file "$file" --overwrite --no-progress -o none 2>/dev/null || {
        dv_error 'Could not read the selected local host key file.'; return 1;
    }
    jq -er '
      [ .systemKeys[] | select(.name == "connector_extension") ]
      | if length == 1 and .[0].encrypted != true then .[0].value // .[0].val else null end
      | select(type == "string" and test("\\S"))
    ' "$file" || { dv_error 'An unencrypted local connector_extension key was not found.'; return 1; }
}

dv_write_local() {
    local values="$1" force="$2" target="$dv_app_dir/local.settings.json" staging
    if [ -e "$target" ] || [ -L "$target" ]; then
        [ -f "$target" ] && [ ! -L "$target" ] || {
            dv_error 'local.settings.json must be a regular file, not a directory or link.'; return 1;
        }
        if [ "$force" = false ]; then printf 'Existing local.settings.json preserved byte-for-byte.\n'; return; fi
    fi
    staging=$(mktemp "$dv_app_dir/.local-settings.XXXXXXXX") || return
    dv_local_staging="$staging"
    jq -n --argjson values "$values" '{IsEncrypted:false,Values:$values}' > "$staging" || return
    if [ "$force" = true ]; then
        if [ -e "$target" ] || [ -L "$target" ]; then
            [ -f "$target" ] && [ ! -L "$target" ] || { dv_error 'Refusing to replace a local-settings directory or link.'; return 1; }
        fi
        mv -f -- "$staging" "$target" || return
    else
        link "$staging" "$target" || { dv_error 'Could not create local.settings.json without overwriting an existing path.'; return 1; }
        rm -f -- "$staging" || return
    fi
    dv_local_staging=''
    printf 'Created ignored local.settings.json using developer credentials and Azurite.\n'
}

dataverse_setup() (
    set -euo pipefail
    umask 077
    exec 3<&0
    local mode="$1" app="$2"
    shift 2
    local reconfigure=false force=false callback='' host='' local_callback=false
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --reconfigure|-Reconfigure) reconfigure=true; shift ;;
            --force-local-settings|-ForceLocalSettings) force=true; shift ;;
            --callback-base-url|-CallbackBaseUrl) [ "$#" -ge 2 ] || { dv_error 'Missing callback URL.'; exit 1; }; callback="$2"; shift 2 ;;
            --local-host-id|-LocalHostId) [ "$#" -ge 2 ] || { dv_error 'Missing local host ID.'; exit 1; }; host="$2"; shift 2 ;;
            *) dv_error "Unknown option: $1"; exit 1 ;;
        esac
    done
    [[ "$mode" = Poll || "$mode" = Webhook ]] || { dv_error 'Invalid delivery mode.'; exit 1; }
    command -v jq >/dev/null || { dv_error 'Install jq before running this script.'; exit 1; }
    if [ -n "$callback" ]; then
        [ "$mode" = Webhook ] && jq -en --arg url "$callback" \
            '$url | test("^https://[^/?#@[:space:]]+/?$")' >/dev/null || {
            dv_error 'Callback URL must be a public HTTPS tunnel origin without credentials, path, query, or fragment.'; exit 1;
        }
        local_callback=true
    elif [ -n "$host" ]; then dv_error '--local-host-id requires --callback-base-url.'; exit 1; fi
    local dv_app_dir dv_swagger dv_subscription dv_group dv_namespace dv_connection dv_connection_url
    local outputs location namespace_id root exported saved triggers key_file
    local page inventory='[]' resources plan item properties resource name function_name selected url result
    local values='{"AzureWebJobsStorage":"UseDevelopmentStorage=true","FUNCTIONS_WORKER_RUNTIME":"dotnet-isolated"}'
    local endpoint='' candidate unchanged needs encoded hash attempt settings_file
    dv_app_dir="$(cd "$app" && pwd)"
    dv_local_staging=''
    dv_work=$(mktemp -d "${TMPDIR:-/tmp}/dataverse-setup.XXXXXXXX")
    trap 'if [ -n "$dv_local_staging" ]; then rm -f -- "$dv_local_staging"; fi; rm -f -- "$dv_work"/*; rmdir -- "$dv_work"' EXIT
    dv_swagger="$dv_work/swagger.json"
    outputs=$(azd env get-values --output json)
    for name in resourceGroupName functionAppName connectorNamespaceName connectorNamespaceConnectionName AZURE_SUBSCRIPTION_ID; do
        jq -e --arg name "$name" '.[$name] | type == "string" and test("\\S")' <<< "$outputs" >/dev/null || {
            dv_error "Missing azd output $name. Run azd provision first."; exit 1;
        }
    done
    location=$(jq -er '.connectorNamespaceLocation // .CONNECTOR_NAMESPACE_LOCATION | select(type == "string" and test("\\S"))' <<< "$outputs") || {
        dv_error 'Missing Connector Namespace location. Run azd provision to select resource regions first.'; exit 1;
    }
    dv_subscription=$(jq -r '.AZURE_SUBSCRIPTION_ID' <<< "$outputs")
    dv_group=$(jq -r '.resourceGroupName' <<< "$outputs")
    dv_namespace=$(jq -r '.connectorNamespaceName' <<< "$outputs")
    dv_connection=$(jq -r '.connectorNamespaceConnectionName' <<< "$outputs")
    namespace_id="/subscriptions/$dv_subscription/resourceGroups/$dv_group/providers/Microsoft.Web/connectorGateways/$dv_namespace"
    root="https://management.azure.com$namespace_id"
    dv_connection_url="$root/connections/$(jq -rn --arg name "$dv_connection" '$name | @uri')"
    dv_consent
    exported=$(dv_rest GET "https://management.azure.com/subscriptions/$dv_subscription/providers/Microsoft.Web/locations/$location/managedApis/commondataservice?api-version=2022-09-01-preview&export=true")
    jq -e '.properties.apiDefinitions.value // . | if type == "string" then fromjson else . end | select(.paths != null)' <<< "$exported" > "$dv_swagger"
    if [ "$mode" = Poll ]; then saved=DATAVERSE_POLLING_TRIGGER_INPUTS; else saved=DATAVERSE_WEBHOOK_TRIGGER_INPUTS; fi
    encoded=$(jq -r --arg name "$saved" '.[$name] // ""' <<< "$outputs")
    if [ -n "$encoded" ] && [ "$reconfigure" = false ]; then
        triggers=$(jq -cen --arg value "$encoded" '$value | @base64d | fromjson') || {
            dv_error "Invalid saved selections. Use --reconfigure to choose again."; exit 1;
        }
        printf 'Reusing saved selections from %s. Pass --reconfigure to choose again.\n' "$saved"
    else triggers=$(dv_collect); fi
    dv_json -n --argjson triggers "$triggers" 'include "trigger-inputs"; dvvalidate($swagger[0]; $triggers)' >/dev/null
    key_file="$dv_work/connector-key"
    : > "$key_file"
    if [ "$mode" = Webhook ]; then
        if [ "$local_callback" = true ]; then dv_local_key "$host" > "$key_file"
        else
            callback="https://$(jq -er '.functionAppDefaultHostname | select(type == "string" and test("\\S"))' <<< "$outputs")"
            for ((attempt=0; attempt<30; attempt++)); do
                az functionapp keys list --subscription "$dv_subscription" -g "$dv_group" \
                    -n "$(jq -r '.functionAppName' <<< "$outputs")" --query systemKeys.connector_extension -o tsv > "$key_file" 2>/dev/null || : > "$key_file"
                if grep -q '[^[:space:]]' "$key_file"; then break; fi
                if [ "$attempt" -lt 29 ]; then sleep 3; fi
            done
            grep -q '[^[:space:]]' "$key_file" || { dv_error 'The deployed host returned no connector_extension key.'; exit 1; }
        fi
    fi
    page="$root/triggerConfigs?api-version=2026-05-01-preview"
    while [ -n "$page" ]; do
        result=$(dv_rest GET "$page")
        inventory=$(jq -c --argjson result "$result" '. + $result.value' <<< "$inventory")
        page=$(jq -r '.nextLink // ""' <<< "$result")
        if [ -n "$page" ]; then
            jq -en --arg page "$page" --arg prefix "$root/triggerConfigs?" \
                '$page | ascii_downcase | startswith($prefix | ascii_downcase)' >/dev/null || {
                dv_error 'Unsafe trigger inventory continuation URL.'; exit 1;
            }
        fi
    done
    resources=$(jq -ce '
      if (map(.name) | unique | length) != length then error("Ambiguous trigger configuration inventory.")
      else map({key:.name,value:.}) | from_entries end' <<< "$inventory")
    plan=$(jq -cn -L "$dv_script_dir" --argjson outputs "$outputs" --argjson triggers "$triggers" \
        --argjson resources "$resources" --arg mode "$mode" --arg id "$namespace_id" --arg callback "${callback%/}" --rawfile key "$key_file" '
      include "trigger-inputs";
      [ dvdefinitions[] as $definition
        | ((if $mode == "Poll" then "dataverse-" else $outputs.connectorNamespaceConnectionName + "-" end)
          + ($definition.functionName | ascii_downcase)) as $name
        | if ($name | test("^[a-z0-9-]+$") | not) then error("Unsafe generated trigger name.") else . end
        | [$triggers[] | select(.functionName == $definition.functionName)] as $selected
        | ({
            connectionDetails:{connectionName:$outputs.connectorNamespaceConnectionName,connectorName:"commondataservice"},
            operationName:$definition.operationName, parameters:($selected[0].parameters // []),
            metadata:{destinationType:"functionApp",functionAppName:$outputs.functionAppName,
              functionAppResourceGroup:$outputs.resourceGroupName,functionAppSubscriptionId:$outputs.AZURE_SUBSCRIPTION_ID,
              functionName:$definition.functionName},
            state:"Enabled",type:"NotSpecified",
            description:("Dataverse " + $definition.operationName + " -> " + $definition.functionName)
          } + (if $mode == "Poll" then {deliveryMode:"Poll"} else {notificationDetails:{
            callbackUrl:($callback + "/runtime/webhooks/connector?functionName=" + $definition.functionName),
            authentication:{type:"QueryString",name:"code",value:($key | rtrimstr("\n") | rtrimstr("\r"))}}} end)) as $properties
        | $resources[$name] as $resource
        | if $resource != null then
            if ($resource.id | ascii_downcase) != (($id + "/triggerConfigs/" + $name) | ascii_downcase) or
               ($resource.properties.deliveryMode // "Webhook") != $mode or
               $resource.properties.operationName != $properties.operationName or
               $resource.properties.connectionDetails.connectionName != $properties.connectionDetails.connectionName or
               $resource.properties.connectionDetails.connectorName != "commondataservice" then
              error("Refusing to overwrite an unowned, legacy-operation, or other-delivery trigger: " + $name)
            elif any($properties.metadata | to_entries[]; . as $entry
               | ($resource.properties.metadata[$entry.key] // "" | ascii_downcase) != ($entry.value | ascii_downcase)) then
              error("Refusing to overwrite another application trigger: " + $name)
            else . end
          else . end
        | {definition:$definition,name:$name,selected:($selected | length > 0),properties:$properties,resource:$resource}
      ]')
    hash=$(printf '%s|%s|/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Web/sites/%s|%s' \
        "$namespace_id" "$dv_connection" "$dv_subscription" "$dv_group" "$(jq -r '.functionAppName' <<< "$outputs")" "$mode" | dv_hash)
    if jq -e 'any(.[]; .definition.functionName == "OnDataverseActionPerformed" and .selected and .resource == null)' <<< "$plan" >/dev/null &&
       [ -e "$dv_app_dir/.azure/dataverse-action-cleanup-$hash.json" ]; then
        dv_error 'A previous action registration has pending source cleanup. Verify exact-owned cleanup before creating its missing configuration.'; exit 1
    fi
    encoded=$(jq -rn --argjson triggers "$triggers" '$triggers | tojson | @base64')
    azd env set "$saved" "$encoded"
    while IFS= read -r item; do
        name=$(jq -r '.name' <<< "$item")
        function_name=$(jq -r '.definition.functionName' <<< "$item")
        selected=$(jq -r '.selected' <<< "$item")
        properties=$(jq -c '.properties' <<< "$item")
        resource=$(jq -c '.resource' <<< "$item")
        values=$(jq -c --arg function "$function_name" --argjson selected "$selected" \
            '.["AzureWebJobs." + $function + ".Disabled"] = ($selected | not | tostring)' <<< "$values")
        if [ "$mode" = Poll ]; then
            values=$(jq -c --arg function "$function_name" --arg name "$name" '.[$function + "TriggerConfigName"] = $name' <<< "$values")
        fi
        url="$root/triggerConfigs/$name?api-version=2026-05-01-preview"
        if [ "$selected" = false ]; then
            if [ "$resource" != null ] && [ "$(jq -r '.properties.state' <<< "$resource")" != Disabled ]; then
                properties=$(jq -c '{properties:(.properties | del(.pollingEndpoints,.provisioningState) | .state = "Disabled")}' <<< "$resource")
                result=$(dv_rest PUT "$url" "$properties")
                dv_wait_trigger "$result" "$url" Disabled false >/dev/null
            fi
            printf '%s skipped; any owned configuration is disabled, not deleted.\n' "$function_name"
            continue
        fi
        unchanged=$(jq -rn --argjson current "$resource" --argjson desired "$properties" --arg mode "$mode" '
          $current != null and $current.properties.state == "Enabled" and
          ($current.properties.provisioningState | IN("Failed","Canceled","Cancelled") | not) and
          ($current.properties.parameters | sort_by(.name)) == ($desired.parameters | sort_by(.name)) and
          ($mode == "Poll" or $current.properties.notificationDetails == $desired.notificationDetails)')
        if [ "$unchanged" = true ]; then result="$resource"
        else result=$(dv_rest PUT "$url" "$(jq -cn --argjson properties "$properties" '{properties:$properties}')"); fi
        needs=false
        [ "$mode" != Poll ] || needs=true
        result=$(dv_wait_trigger "$result" "$url" Enabled "$needs")
        if [ "$mode" = Poll ]; then
            candidate=$(dv_poll_endpoint "$(jq -r '.properties.pollingEndpoints.receiveUri' <<< "$result")" "$name")
            [ -z "$endpoint" ] || [ "$endpoint" = "$candidate" ] || { dv_error 'Selected Poll triggers returned inconsistent namespace endpoints.'; exit 1; }
            endpoint="$candidate"
        fi
        printf '%s configured for %s delivery.\n' "$function_name" "$mode"
    done < <(jq -c '.[]' <<< "$plan")
    if [ "$mode" = Poll ]; then
        [ -n "$endpoint" ] || { dv_error 'No Poll receive endpoint was returned.'; exit 1; }
        values=$(jq -c --arg endpoint "$endpoint" '.ConnectorNamespace__pollingEndpoint = $endpoint' <<< "$values")
    fi
    settings_file="$dv_work/appsettings.json"
    jq 'del(.AzureWebJobsStorage,.FUNCTIONS_WORKER_RUNTIME)' <<< "$values" > "$settings_file"
    az functionapp config appsettings set --subscription "$dv_subscription" -g "$dv_group" \
        -n "$(jq -r '.functionAppName' <<< "$outputs")" --settings "@$settings_file" -o none 2>/dev/null || {
        dv_error 'Could not configure deployed function listeners. Resolve the app settings error and rerun the hook.'; exit 1;
    }
    dv_write_local "$values" "$force"
    printf 'Dataverse setup complete. Source provisioning is not proof of event delivery; verify with a sample-owned fixture.\n'
)
