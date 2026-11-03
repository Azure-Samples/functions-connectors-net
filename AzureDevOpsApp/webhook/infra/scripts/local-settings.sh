connector_jq() {
    case "${OSTYPE:-}" in
        msys*|cygwin*) command jq --binary "$@" ;;
        *) command jq "$@" ;;
    esac
}

write_local_settings() {
    local target="$app_dir/local.settings.json"
    if [ -e "$target" ] || [ -L "$target" ]; then
        [ ! -d "$target" ] && [ ! -L "$target" ] || { echo 'local.settings.json must not be a directory or link.' >&2; return 1; }
        echo 'Existing local.settings.json preserved byte-for-byte.'
        return
    fi
    if ! (set -o noclobber; printf '%s\n' "$1" > "$target"); then
        echo 'Could not create or write local.settings.json without overwriting.' >&2
        return 1
    fi
    echo 'Created ignored local.settings.json for developer authentication and Azurite.'
}
