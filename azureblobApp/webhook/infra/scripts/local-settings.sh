connector_jq() {
    case "${OSTYPE:-}" in
        msys*|cygwin*) command jq --binary "$@" ;;
        *) command jq "$@" ;;
    esac
}

write_local_settings() (
    set -euo pipefail
    umask 077
    local target="$app_dir/local.settings.json" temp='' acquired
    if [[ -e "$target" || -L "$target" ]]; then
        [[ -f "$target" && ! -L "$target" ]] ||
            { echo 'local.settings.json must be a regular file, not a directory or link.' >&2; exit 1; }
        echo 'Existing local.settings.json preserved byte-for-byte.'
        exit 0
    fi
    cleanup_local_settings() {
        local result=$?
        trap - EXIT
        if [[ -n "$temp" ]]; then
            rm -f -- "$temp" || { echo 'Could not clean owned local-settings staging file.' >&2; [[ "$result" -ne 0 ]] || result=1; }
        fi
        exit "$result"
    }
    trap cleanup_local_settings EXIT
    acquired=$(mktemp "$app_dir/.local-settings.XXXXXXXX") ||
        { echo 'Could not create local-settings staging file.' >&2; exit 1; }
    temp="$acquired"
    printf '%s\n' "$1" > "$temp" || { echo 'Could not write local-settings staging file.' >&2; exit 1; }
    (set -o noclobber; cat "$temp" > "$target") ||
        { echo 'Could not create local.settings.json without overwriting an existing file.' >&2; exit 1; }
    echo 'Created ignored local.settings.json using developer credentials and Azurite.'
)
