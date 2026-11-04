connector_jq() {
    case "${OSTYPE:-}" in
        msys*|cygwin*) command jq --binary "$@" ;;
        *) command jq "$@" ;;
    esac
}

write_local_settings() (
    target="$app_dir/local.settings.json"
    force="${2:-false}"
    if [ -e "$target" ] || [ -L "$target" ]; then
        [ ! -d "$target" ] && [ ! -L "$target" ] ||
            { echo 'local.settings.json must not be a directory or link.' >&2; return 1; }
        if [ "$force" != true ]; then
            echo 'Existing local.settings.json preserved byte-for-byte.'
            return
        fi
    fi
    temp=''
    cleanup_local_settings() {
        result=$?
        trap - EXIT
        if [ -n "$temp" ]; then
            rm -f -- "$temp" ||
                { echo 'Could not clean owned local-settings staging file.' >&2; [ "$result" -ne 0 ] || result=1; }
        fi
        exit "$result"
    }
    trap cleanup_local_settings EXIT
    umask 077
    candidate_temp=$(mktemp "$app_dir/.local-settings.XXXXXXXX") ||
        { echo 'Could not create local-settings staging file.' >&2; return 1; }
    temp="$candidate_temp"
    printf '%s\n' "$1" >"$temp" ||
        { echo 'Could not write local-settings staging file.' >&2; return 1; }
    [ ! -d "$target" ] && [ ! -L "$target" ] ||
        { echo 'local.settings.json must not be a directory or link.' >&2; return 1; }
    if [ "$force" = true ]; then
        mv -f "$temp" "$target" ||
            { echo 'Could not replace local.settings.json.' >&2; return 1; }
    else
        link "$temp" "$target" ||
            { echo 'Could not create local.settings.json without clobbering.' >&2; return 1; }
    fi
    echo 'Created ignored local.settings.json for developer authentication and Azurite.'
)
