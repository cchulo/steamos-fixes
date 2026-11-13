# SPDX-License-Identifier: GPL-2.0-only
# summary: show one desktop notification about the last boot (steamos-fixes-notify.service): [--print]
#
# Reads state/notify written by `boot`. Runs as the session user; remembers
# what it already showed in ${XDG_STATE_HOME:-~/.local/state}/steamos-fixes/notified
# so each distinct summary is shown once. --print writes to stdout instead.

NOTIFY_REL="${SOF_STATE_REL}/state/notify"

# notify_body <file> : human summary, one line per non-empty item.
notify_body() {
    local f=$1 v
    v=$(sed -n 's/^update=//p' "$f")
    [ -n "$v" ] && printf 'SteamOS was updated (slot %s).\n' "$v"
    v=$(sed -n 's/^reapplied=//p' "$f")
    [ -n "$v" ] && printf 'Re-applied: %s.\n' "$v"
    v=$(sed -n 's/^failed=//p' "$f")
    [ -n "$v" ] && printf 'Could not re-apply: %s (see %s status).\n' "$v" "$SOF_NAME"
    v=$(sed -n 's/^pending=//p' "$f")
    [ -n "$v" ] && printf 'Building %s in the background; reboot once it is done.\n' "$v"
    v=$(sed -n 's/^blocked=//p' "$f")
    [ -n "$v" ] && printf 'A SteamOS update with kernel %s was held back: no modules yet. Override: %s update-policy degrade --once.\n' "$v" "$SOF_NAME"
    v=$(sed -n 's/^superseded=//p' "$f")
    [ -n "$v" ] && printf 'SteamOS now provides: %s. Remove ours with: %s uninstall --superseded.\n' "$v" "$SOF_NAME"
    return 0
}

cmd_notify() {
    local print=0 f body seen sha
    case "${1:-}" in
        --print) print=1 ;;
        '') ;;
        *) die 2 "notify: unknown argument '$1'" ;;
    esac
    f=$(sof_path "$NOTIFY_REL")
    [ -f "$f" ] || return 0
    body=$(notify_body "$f")
    [ -n "$body" ] || return 0
    if [ "$print" = 1 ]; then
        printf '%s\n' "$body"
        return 0
    fi
    seen=$(sof_path "${XDG_STATE_HOME:-${HOME:-/nonexistent}/.local/state}/$SOF_NAME/notified")
    sha=$(sof_sha256 "$f")
    if [ -f "$seen" ] && [ "$(cat "$seen")" = "$sha" ]; then
        return 0
    fi
    if sof_have notify-send; then
        sof_run notify-send --app-name="$SOF_NAME" --icon=system-software-update "SteamOS fixes" "$body" \
            || log_warn "notify-send failed"
    else
        printf '%s\n' "$body"
    fi
    if [ "$SOF_DRY_RUN" != 1 ]; then
        mkdir -p "$(dirname "$seen")"
        printf '%s\n' "$sha" >"$seen"
    fi
}
