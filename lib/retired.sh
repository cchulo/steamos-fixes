# SPDX-License-Identifier: GPL-2.0-only
# lib/retired.sh — clean up after components this version no longer ships.
#
# A component that is removed from components/ still has its files recorded
# in the manifest of every device that had it. `apply` (and the boot
# service, through apply_components) calls retired_prune_all, which removes
# them with the uninstaller's rules:
#   * only paths recorded in our manifest under that component name,
#   * only paths with the steamos-fixes marker in them,
#   * files and symlinks checked against the recorded digest first; a
#     modified file is kept, reported and stays in the manifest (remove it
#     by hand, or `uninstall --force`),
#   * directories we created are removed only when empty, deepest first,
#     never through a symlink.
# Each retired component may define retired_<name>_extra (paths it created
# outside the manifest) and retired_<name>_after (restart what loaded the
# files); both get the list of removed paths on stdin.
#
# Retired: (none yet). Add names to SOF_RETIRED_COMPONENTS when a
# component is dropped; tests may preset the variable.

# shellcheck source=lib/common.sh
. "${SOF_SRC:-$(dirname "${BASH_SOURCE[0]}")/..}/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$SOF_SRC/lib/manifest.sh"

SOF_RETIRED_COMPONENTS="${SOF_RETIRED_COMPONENTS:-}"

# retired_is <name> : 0 when <name> is a component this version retired.
retired_is() {
    case " $SOF_RETIRED_COMPONENTS " in *" $1 "*) return 0 ;; esac
    return 1
}

# _retired_recorded <component> <kind> : its manifest paths of that kind.
_retired_recorded() {
    manifest_entries | _manifest_select component "$1" \
        | _manifest_select kind "$2" | _manifest_field path
}

# _retired_unlink <component> <path> : remove one recorded file or symlink.
# 0 removed (or already gone), 1 kept (modified or no marker).
_retired_unlink() {
    local rc=0
    case "$2" in *steamos-fixes*) ;; *)
        log_warn "$1: not removing $2: no steamos-fixes marker in the path"
        return 1
        ;;
    esac
    manifest_verify "$2" || rc=$?
    case "$rc" in
        0 | 2)
            log_info "$1: removing $2 (component removed from $SOF_NAME)"
            sof_run rm -f "$(sof_path "$2")"
            manifest_forget "$2"
            return 0
            ;;
    esac
    log_warn "$1: $2 was modified after install; leaving it in place (remove it by hand)"
    return 1
}

# _retired_prune_dirs <component> : directories it created, deepest first,
# removed when empty; vanished ones are forgotten.
_retired_prune_dirs() {
    local d real
    _retired_recorded "$1" dir | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2- \
        | while IFS= read -r d; do
            case "$d" in /?*) ;; *) continue ;; esac
            real=$(sof_path "$d")
            [ -L "$real" ] && continue
            if [ ! -d "$real" ]; then
                manifest_forget "$d"
                continue
            fi
            [ -z "$(find "$real" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ] || continue
            sof_run rmdir "$real" && manifest_forget "$d"
        done
}

# retired_prune <component> : remove what the manifest records for it.
# Returns 1 if anything was kept.
retired_prune() {
    local c=$1 p rc=0 removed=""
    for p in $(_retired_recorded "$c" file) $(_retired_recorded "$c" symlink); do
        if _retired_unlink "$c" "$p"; then
            removed="$removed$p
"
        else
            rc=1
        fi
    done
    if declare -F "retired_${c}_extra" >/dev/null 2>&1; then
        printf '%s' "$removed" | "retired_${c}_extra" || rc=1
    fi
    _retired_prune_dirs "$c"
    if [ -n "$removed" ] && declare -F "retired_${c}_after" >/dev/null 2>&1; then
        printf '%s' "$removed" | "retired_${c}_after" || true
    fi
    if [ -z "$(manifest_paths "$c" | head -n 1)" ]; then
        log_info "$c: removed (no longer part of $SOF_NAME)"
    fi
    return $rc
}

# retired_prune_all : retired_prune every retired component the manifest
# still mentions. Returns 1 if anything was kept.
retired_prune_all() {
    local c rc=0
    for c in $SOF_RETIRED_COMPONENTS; do
        [ -n "$(manifest_paths "$c" | head -n 1)" ] || continue
        retired_prune "$c" || rc=1
    done
    return $rc
}
