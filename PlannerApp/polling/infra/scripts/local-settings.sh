connector_jq() {
    case "${OSTYPE:-}" in
        msys*|cygwin*) command jq --binary "$@" ;;
        *) command jq "$@" ;;
    esac
}

publish_local_settings() (
    set -euo pipefail
    local path=$1 json=$2 stage='' acquired
    if [[ -e "$path" || -L "$path" ]]; then
        [[ -f "$path" && ! -L "$path" ]] || { echo 'ERROR: local.settings.json must be a regular file, not a directory or link.' >&2; exit 1; }
        echo 'Existing local.settings.json preserved byte-for-byte.'
        exit 0
    fi
    cleanup_local_settings() {
        local result=$?
        trap - EXIT
        if [[ -n "$stage" ]]; then
            rm -f -- "$stage" || { echo 'ERROR: staged settings cleanup failed.' >&2; [[ "$result" -ne 0 ]] || result=1; }
        fi
        exit "$result"
    }
    trap cleanup_local_settings EXIT
    acquired=$(mktemp "$(dirname "$path")/.local.settings.XXXXXXXX") ||
        { echo 'ERROR: could not create local-settings staging file.' >&2; exit 1; }
    stage=$acquired
    printf '%s\n' "$json" > "$stage" ||
        { echo 'ERROR: could not write local-settings staging file.' >&2; exit 1; }
    link "$stage" "$path" ||
        { echo 'ERROR: could not create local.settings.json without overwriting an existing path.' >&2; exit 1; }
    echo 'Created ignored local.settings.json for Azurite and developer credentials.'
)
