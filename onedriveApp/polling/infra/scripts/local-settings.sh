write_local_settings() (
    local target="$app_dir/local.settings.json" temp='' candidate_temp='' result
    if [ -e "$target" ] || [ -L "$target" ]; then
        [ -f "$target" ] && [ ! -L "$target" ] ||
            { echo 'local.settings.json must be a regular file, not a directory or link.' >&2; return 1; }
        if [ "${2:-false}" != true ]; then
            echo 'Existing local.settings.json preserved byte-for-byte.'
            return
        fi
    fi
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
    candidate_temp=$(mktemp "$app_dir/.local-settings.XXXXXXXX") ||
        { echo 'Could not create local-settings staging file.' >&2; return 1; }
    temp=$candidate_temp
    printf '%s\n' "$1" > "$temp" ||
        { echo 'Could not write local-settings staging file.' >&2; return 1; }
    if [ "${2:-false}" = true ]; then
        if [ -e "$target" ] || [ -L "$target" ]; then
            [ -f "$target" ] && [ ! -L "$target" ] ||
                { echo 'local.settings.json must be a regular file, not a directory or link.' >&2; return 1; }
        fi
        mv -f -- "$temp" "$target" ||
            { echo 'Could not replace the exact local.settings.json file.' >&2; return 1; }
    else
        link "$temp" "$target" ||
            { echo 'Could not create local.settings.json without overwriting an existing path.' >&2; return 1; }
    fi
    echo 'Created ignored local.settings.json for developer authentication and Azurite.'
)
