# SPDX-License-Identifier: GPL-2.0-only
# lib/status.sh — collect the facts `status` shows and write state/status.json,
# the machine-readable summary that `apply`, the boot service, the notifier
# and (later) the Decky plugin read. One writer, one shape:
#
#   {
#     "name": "steamos-fixes", "version": "0.1.0-dev", "commit": "abc1234",
#     "generated": "<iso>",
#     "kernel": { "running": "<kver>", "modules_staged": true|false },
#     "update_policy": "degrade|block", "pending_reboot_check": true|false,
#     "last_update_check": { "ts", "result", "ref" } | null,
#     "kver": "<kver>", "slot": "A|B|",          # compatibility keys
#     "<extra key>": "<extra value>", ...        # from the caller
#     "components": [ { "name", "status", "detail", "applies", "description" }, ... ]
#   status is active | degraded | stock | superseded | n/a; detail is the
#   component's one-line explanation (may be empty); applies is
#   yes | no | unknown (the fix's hardware probe).
#   }
#
# Usage:
#   status_collect                           # fill the _ST_* facts
#   status_render_json [key value]...        # print the document
#   status_write_json [key value]...         # collect + atomically write the file

# shellcheck source=lib/common.sh
. "${SOF_SRC:-$(dirname "${BASH_SOURCE[0]}")/..}/lib/common.sh"
# shellcheck source=lib/component.sh
. "$SOF_SRC/lib/component.sh"
# shellcheck source=lib/selfupdate.sh
. "$SOF_SRC/lib/selfupdate.sh"
# shellcheck source=lib/slots.sh
. "$SOF_SRC/lib/slots.sh"

# Collected facts, filled by status_collect (plain variables: bash 3.2).
_ST_VERSION="" _ST_COMMIT="" _ST_KVER="" _ST_MODULES="" _ST_POLICY="" _ST_PENDING=""
_ST_LASTCHECK="" _ST_COMPONENTS=""
_ST_SEP=$(printf '\036')

status_collect() {
    local c st desc detail applies rc
    _ST_VERSION=$(cat "$SOF_SRC/VERSION" 2>/dev/null || echo unknown)
    _ST_COMMIT=""
    if sof_have git && git -C "$SOF_SRC" rev-parse --short HEAD >/dev/null 2>&1; then
        _ST_COMMIT=$(git -C "$SOF_SRC" rev-parse --short HEAD)
    fi
    _ST_KVER=$(probe_running_kver 2>/dev/null || echo unknown)
    # Staged modules live in the early boot dir (/etc), not the state dir.
    if [ -f "$(sof_path "${SOF_EARLY_REL}/modules/${_ST_KVER}/BUILD-INFO")" ]; then
        _ST_MODULES=yes
    else
        _ST_MODULES=no
    fi
    _ST_POLICY=$(su_read_state update-policy degrade | awk '{ print $1 }')
    if [ -e "$(su_state_file pending-reboot-check)" ]; then
        _ST_PENDING=yes
    else
        _ST_PENDING=no
    fi
    _ST_LASTCHECK=$(su_read_state last-update-check "")
    # One "name<US>status<US>description<US>detail<US>applies" line per
    # component (US = \036: unlike a tab it is not whitespace, so an empty
    # detail field survives `read`). Each runs in a subshell so a broken
    # component cannot abort the whole report.
    _ST_COMPONENTS=""
    for c in $(component_list); do
        st=$( (component_status "$c") 2>/dev/null) || st=error
        [ -n "$st" ] || st=error
        desc=$( (component_description "$c") 2>/dev/null) || desc=""
        detail=$( (component_status_detail "$c") 2>/dev/null | head -n1 | tr '\t' ' ') || detail=""
        rc=0
        (component_applies "$c") >/dev/null 2>&1 || rc=$?
        case "$rc" in
            0) applies=yes ;;
            1) applies=no ;;
            *) applies=unknown ;;
        esac
        _ST_COMPONENTS="${_ST_COMPONENTS}${c}${_ST_SEP}${st}${_ST_SEP}${desc}${_ST_SEP}${detail}${_ST_SEP}${applies}
"
    done
}

status_render_json() {
    local first=1 name st desc detail applies lc_ts="" lc_result="" lc_ref=""
    if [ -n "$_ST_LASTCHECK" ]; then
        lc_ts=$(printf '%s\n' "$_ST_LASTCHECK" | cut -f1)
        lc_result=$(printf '%s\n' "$_ST_LASTCHECK" | cut -f3)
        lc_ref=$(printf '%s\n' "$_ST_LASTCHECK" | cut -f4)
    fi
    printf '{\n'
    printf '  "name": %s,\n' "$(su_json_str "$SOF_NAME")"
    printf '  "version": %s,\n' "$(su_json_str "$_ST_VERSION")"
    printf '  "commit": %s,\n' "$(su_json_str "$_ST_COMMIT")"
    printf '  "generated": %s,\n' "$(su_json_str "$(su_now_iso)")"
    printf '  "kernel": { "running": %s, "modules_staged": %s },\n' \
        "$(su_json_str "$_ST_KVER")" "$([ "$_ST_MODULES" = yes ] && echo true || echo false)"
    printf '  "update_policy": %s,\n' "$(su_json_str "$_ST_POLICY")"
    printf '  "pending_reboot_check": %s,\n' "$([ "$_ST_PENDING" = yes ] && echo true || echo false)"
    if [ -n "$lc_ts" ]; then
        printf '  "last_update_check": { "ts": %s, "result": %s, "ref": %s },\n' \
            "$(su_json_str "$lc_ts")" "$(su_json_str "$lc_result")" "$(su_json_str "$lc_ref")"
    else
        printf '  "last_update_check": null,\n'
    fi
    # Compatibility keys used by apply/boot consumers and tests.
    printf '  "kver": %s,\n' "$(su_json_str "$_ST_KVER")"
    printf '  "slot": %s,\n' "$(su_json_str "$(slots_active 2>/dev/null || true)")"
    # Caller-supplied extras (last_command, reapplied, failed, ...).
    while [ $# -ge 2 ]; do
        printf '  %s: %s,\n' "$(su_json_str "$1")" "$(su_json_str "$2")"
        shift 2
    done
    printf '  "components": ['
    while IFS="$_ST_SEP" read -r name st desc detail applies; do
        [ -n "$name" ] || continue
        [ "$first" = 1 ] || printf ','
        first=0
        printf '\n    { "name": %s, "status": %s, "detail": %s, "applies": %s, "description": %s }' \
            "$(su_json_str "$name")" "$(su_json_str "$st")" "$(su_json_str "$detail")" \
            "$(su_json_str "${applies:-yes}")" "$(su_json_str "$desc")"
    done <<EOF
$_ST_COMPONENTS
EOF
    [ "$first" = 1 ] || printf '\n  '
    printf ']\n}\n'
}

# status_write_json [key value]... : collect and atomically (re)write
# state/status.json. Never fatal (the state dir may not exist yet).
status_write_json() {
    local f
    f=$(sof_path "$SOF_STATUS_JSON_REL")
    [ "$SOF_DRY_RUN" = 1 ] && return 0
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
    status_collect
    status_render_json "$@" | sof_atomic_write "$f" 0644
}
