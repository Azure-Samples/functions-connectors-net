connector_jq() {
    case "${OSTYPE:-}" in
        msys*|cygwin*) command jq --binary "$@" ;;
        *) command jq "$@" ;;
    esac
}

get_local_connector_extension_key() (
    set -euo pipefail
    umask 077
    local sample_root=$1 settings storage host_id names candidates
    file=''
    settings="$sample_root/local.settings.json"
    if [[ ! -f "$settings" ]]; then
        echo 'Create local.settings.json and start Azurite and func start --enableAuth first.' >&2
        exit 1
    fi
    storage=$(connector_jq -er '.Values.AzureWebJobsStorage' "$settings")
    if ! printf '%s' "$storage" | grep -Eiq '^UseDevelopmentStorage=true(;|$)|BlobEndpoint=http://(127\.0\.0\.1|localhost|\[::1\]):'; then
        echo 'Automatic local-key retrieval requires a local Azurite AzureWebJobsStorage connection.' >&2
        exit 1
    fi
    host_id=$(connector_jq -r '.Values.AzureFunctionsWebHost__hostid // empty' "$settings")
    if [[ -z "$host_id" ]]; then
        host_id=$(connector_jq -r '.id // empty' "$sample_root/host.json")
    fi
    host_id=$(printf '%s' "$host_id" | tr '[:upper:]' '[:lower:]')
    names=$(az storage blob list --container-name azure-webjobs-secrets --connection-string "$storage" \
        --query '[].name' -o json) || {
        echo 'Could not read local host secrets. Start Azurite and func start --enableAuth first.' >&2
        exit 1
    }
    candidates=$(printf '%s' "$names" | connector_jq -c --arg host "$host_id" \
        '[.[] | select(test("^[^/]+/host\\.json$")) | select($host == "" or . == ($host + "/host.json"))]')
    if [[ "$(printf '%s' "$candidates" | connector_jq 'length')" != 1 ]]; then
        echo 'Could not identify one local host key file. Start this host with func start --enableAuth. If Azurite contains multiple hosts, set Values.AzureFunctionsWebHost__hostid in local.settings.json.' >&2
        exit 1
    fi
    file=$(mktemp "${TMPDIR:-/tmp}/sharepoint-local-key.XXXXXXXX")
    trap 'rm -f -- "$file"' EXIT
    az storage blob download --container-name azure-webjobs-secrets \
        --name "$(printf '%s' "$candidates" | connector_jq -r '.[0]')" \
        --connection-string "$storage" --file "$file" --overwrite --no-progress -o none || {
        echo 'Could not read the selected local host key file.' >&2
        exit 1
    }
    connector_jq -er '
        [.systemKeys[]? | select(.name == "connector_extension")] |
        if length == 1 and .[0].encrypted != true then
            .[0] | (if (.value // "") != "" then .value else .val end) |
            select(type == "string" and test("\\S"))
        else empty end' "$file" || {
        echo 'An unencrypted local connector_extension key was not found. Check local host startup and secret storage.' >&2
        exit 1
    }
)
