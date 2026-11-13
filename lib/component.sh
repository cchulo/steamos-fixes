# SPDX-License-Identifier: GPL-2.0-only
# lib/component.sh — discovery and generic driving of components/*.sh.
#
# A component is one self-contained piece: a framework component in
# components/<name>.sh, or a fix in fixes/<dir>/component.sh (the component
# name is the directory name with "-" replaced by "_"). Each defines
# (replace <name> accordingly):
#
#   COMPONENT_DESCRIPTION  one line shown by `status` and `help`
#   <name>_files           print one line per file to install:
#                            "<overlay-relative-src>\t<abs-dest>\t<mode>[\t<slot>]"
#                          src is relative to $SOF_SRC/overlay; dest WITHOUT
#                          SOF_ROOT prefix. May print nothing.
#   <name>_apply           optional. Extra work after the files are in place
#                          (systemctl enable, downloads, generated files).
#                          Must be idempotent and SOF_ROOT-aware.
#   <name>_applies         required for fixes, optional for framework
#                          components (default: applies). 0 = this hardware
#                          or software needs the fix, 1 = not applicable
#                          (apply skips it, status says n/a), 2 = cannot
#                          tell. Prints a one-line reason. Reads files under
#                          the fixture root only.
#   <name>_probe           required. 0 = stock SteamOS now provides this
#                          (superseded), 1 = still needed, 2 = unknown.
#   <name>_status          optional override of component_default_status.
#                          A fix reports "degraded" when it is installed but
#                          a part of it is not effective on this kernel.
#   <name>_status_detail   optional. One line explaining the status; shown
#                          by `status` and written to status.json.
#   <name>_remove          optional. Extra cleanup before the manifest-driven
#                          file removal (stop services, remove caches).
#
# Components never write files themselves outside manifest_install_* so that
# `uninstall` can always undo them. Names contain [a-z0-9_] only; the file
# name is the component name.

# shellcheck source=lib/common.sh
. "${SOF_SRC:-$(dirname "${BASH_SOURCE[0]}")/..}/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$SOF_SRC/lib/manifest.sh"
# shellcheck source=lib/probes.sh
. "$SOF_SRC/lib/probes.sh"

SOF_COMPONENTS_DIR="${SOF_COMPONENTS_DIR:-$SOF_SRC/components}"
SOF_FIXES_DIR="${SOF_FIXES_DIR:-$SOF_SRC/fixes}"

# component_list : names, sorted, one per line: components/*.sh and
# fixes/*/component.sh.
component_list() {
    local f
    {
        for f in "$SOF_COMPONENTS_DIR"/*.sh; do
            [ -f "$f" ] || continue
            basename "$f" .sh
        done
        for f in "$SOF_FIXES_DIR"/*/component.sh; do
            [ -f "$f" ] || continue
            basename "$(dirname "$f")" | tr '-' '_'
        done
    } | sort -u
}

# component_fix_dir <name> : the fixes/<dir> of a fix (name with "_" -> "-"),
# nothing for a framework component.
component_fix_dir() {
    local d
    d="$SOF_FIXES_DIR/$(printf '%s' "$1" | tr '_' '-')"
    [ -f "$d/component.sh" ] || return 1
    printf '%s\n' "$d"
}

# component_is_fix <name>
component_is_fix() { component_fix_dir "$1" >/dev/null 2>&1; }

# _component_file <name> : the file defining it (components/ wins).
_component_file() {
    local d
    if [ -f "$SOF_COMPONENTS_DIR/$1.sh" ]; then
        printf '%s/%s.sh\n' "$SOF_COMPONENTS_DIR" "$1"
    elif d=$(component_fix_dir "$1"); then
        printf '%s/component.sh\n' "$d"
    else
        return 1
    fi
}

# component_exists <name>
component_exists() {
    _component_file "$1" >/dev/null 2>&1
}

# component_load <name> : source it (idempotent), die if malformed.
component_load() {
    local name=$1 f
    case "$name" in
        *[!a-z0-9_]*) die "invalid component name '$name'" ;;
    esac
    f=$(_component_file "$name") || die "unknown component '$name'"
    eval "[ -n \"\${SOF_COMPONENT_LOADED_$name:-}\" ]" && return 0
    # shellcheck disable=SC2034  # set by the component file, read via eval below
    COMPONENT_DESCRIPTION=""
    # shellcheck disable=SC1090
    . "$f"
    eval "SOF_COMPONENT_LOADED_$name=1"
    eval "SOF_COMPONENT_DESC_$name=\"\$COMPONENT_DESCRIPTION\""
    _component_has_fn "${name}_probe" || die "component '$name' does not define ${name}_probe"
    _component_has_fn "${name}_files" || die "component '$name' does not define ${name}_files"
    if component_is_fix "$name" && ! _component_has_fn "${name}_applies"; then
        die "fix '$name' does not define ${name}_applies (which hardware it applies to)"
    fi
}

_component_has_fn() { declare -F "$1" >/dev/null 2>&1; }

# component_description <name>
component_description() {
    component_load "$1"
    eval "printf '%s\n' \"\${SOF_COMPONENT_DESC_$1}\""
}

# component_files <name> : the normalised file list (tab separated).
component_files() {
    component_load "$1"
    "${1}_files"
}

# component_apply <name> : install files via manifest, then run <name>_apply.
component_apply() {
    local name=$1 src dest mode slot line
    component_load "$name"
    log_info "applying component: $name"
    component_files "$name" | while IFS=$'\t' read -r src dest mode slot; do
        [ -n "$src" ] || continue
        [ -n "$mode" ] || mode=0644
        [ -n "$slot" ] || slot=shared
        line="$SOF_SRC/overlay/$src"
        [ -f "$line" ] || die "component $name: overlay file missing: overlay/$src"
        manifest_install_file "$line" "$dest" "$name" "$mode" "$slot"
    done || return 1
    if _component_has_fn "${name}_apply"; then
        "${name}_apply" || return 1
    fi
    return 0
}

# component_probe <name> : run the probe, return its code.
component_probe() {
    component_load "$1"
    "${1}_probe"
}

# component_applies <name> : 0 applies, 1 not applicable here, 2 unknown.
# Framework components without an _applies function always apply. Prints
# the component's one-line reason, if it gives one.
component_applies() {
    component_load "$1"
    if _component_has_fn "${1}_applies"; then
        "${1}_applies"
    else
        return 0
    fi
}

# component_status_detail <name> : the component's one-line explanation of
# its status (empty when it has none).
component_status_detail() {
    component_load "$1"
    if _component_has_fn "${1}_status_detail"; then
        "${1}_status_detail" 2>/dev/null || true
    fi
}

# component_installed <name> : 0 if at least one manifest entry exists for it.
component_installed() {
    [ -n "$(manifest_paths "$1" | head -n1)" ]
}

# component_default_status <name> : active | stock | superseded | n/a
#   n/a         the component does not apply to this hardware (nothing is
#               installed), or the probe cannot tell and nothing is installed
#   superseded  stock now provides it (probe == 0), regardless of install state
#   active      installed, every manifest file verifies, probe says still needed
#   stock       not installed (or incomplete), still needed
# A fix's own _status adds "degraded" (installed, not effective here).
component_default_status() {
    local name=$1 rc p drift=0
    component_applies "$name" >/dev/null 2>&1
    rc=$?
    if [ "$rc" != 0 ] && ! component_installed "$name"; then
        printf 'n/a\n'
        return 0
    fi
    component_probe "$name" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = "$PROBE_YES" ]; then
        printf 'superseded\n'
        return 0
    fi
    if component_installed "$name"; then
        for p in $(manifest_paths "$name"); do
            manifest_verify "$p" || drift=1
        done
        if [ "$drift" = 0 ]; then
            printf 'active\n'
        else
            printf 'stock\n' # incomplete: boot service will re-apply
        fi
        return 0
    fi
    if [ "$rc" = "$PROBE_UNKNOWN" ]; then
        printf 'n/a\n'
    else
        printf 'stock\n'
    fi
}

# component_status <name>
component_status() {
    component_load "$1"
    if _component_has_fn "${1}_status"; then
        "${1}_status"
    else
        component_default_status "$1"
    fi
}

# component_remove_hook <name> : run <name>_remove if present.
component_remove_hook() {
    component_load "$1"
    if _component_has_fn "${1}_remove"; then
        "${1}_remove"
    fi
}
