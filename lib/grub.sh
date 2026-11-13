# SPDX-License-Identifier: GPL-2.0-only
# lib/grub.sh — kernel command-line arguments through /etc/default/grub.d
# drop-ins (plan §4.2, §4.4 exception 1).
#
# SteamOS's `update-grub` (steamos-customizations) runs grub-mkconfig and
# writes the booted slot's /efi/EFI/steamos/grub.cfg; the stock command line
# comes from /etc/default/grub + /etc/default/grub-steamos, and
# /etc/default/grub.d/*.cfg drop-ins are honoured. A fix that needs a kernel
# argument therefore owns one drop-in,
#   /etc/default/grub.d/steamos-fixes-<fix>.cfg
# (manifest-tracked, on the SteamOS keep list through the update component)
# and asks for grub.cfg to be regenerated:
#   * on the booted slot: `update-grub` right away;
#   * on a slot that is not booted (RAUC post-install, `apply --slot`): the
#     request is noted in state/grub-regenerate-needed and the handler runs
#     `holo-chroot --partset <slot> -- update-grub` once our composite mount
#     of that slot is released (the same mechanism Valve's own post-install
#     uses for holo-finalize-install). If that fails, the boot service runs
#     `update-grub` on the first boot of that slot and the change applies
#     one boot later;
#   * on a fixture root: noted and logged, never run.
# grub.cfg is a stock-generated file, so the untouched copy of each slot is
# saved (backup/grub/<slot>/grub.cfg + .sha256) before the first
# regeneration. Uninstall removes the drop-in, regenerates, and reports
# whether the result is byte-identical to the saved original (it is unless
# SteamOS changed the stock file in between, in which case the regenerated
# file is the right one). Without update-grub the saved copy is restored.
#
# lib/slots.sh edits grub.cfg in place only for the early initrd token; the
# two never touch the same text.

# shellcheck source=lib/common.sh
. "${SOF_SRC:-$(dirname "${BASH_SOURCE[0]}")/..}/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$SOF_SRC/lib/manifest.sh"
# shellcheck source=lib/slots.sh
. "$SOF_SRC/lib/slots.sh"

GRUB_DROPIN_DIR_REL="/etc/default/grub.d"
GRUB_BACKUP_REL="${SOF_STATE_REL}/backup/grub"
GRUB_REGEN_REL="${SOF_STATE_REL}/state/grub-regenerate-needed"
GRUB_CMDLINE_REL="/proc/cmdline"
export GRUB_DROPIN_DIR_REL GRUB_BACKUP_REL GRUB_REGEN_REL

# Set to 1 by grub_dropin_install / grub_dropin_remove when the drop-in
# actually changed (so callers know a regeneration is due).
GRUB_CHANGED=0
export GRUB_CHANGED

# grub_dropin_rel <fix> : root-relative path of the fix's drop-in.
grub_dropin_rel() {
    printf '%s/%s-%s.cfg\n' "$GRUB_DROPIN_DIR_REL" "$SOF_NAME" "$1"
}

# grub_render_dropin <fix> <args> : the drop-in on stdout.
grub_render_dropin() {
    printf '# %s: kernel arguments of fix %s. Generated; do not edit.\n' "$SOF_NAME" "$1"
    printf '# Remove with "%s uninstall --component %s" or the fix'"'"'s own command.\n' "$SOF_NAME" "$(printf '%s' "$1" | tr '-' '_')"
    # shellcheck disable=SC2016  # the variable is for grub-mkconfig, not us
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} %s"\n' "$2"
}

# grub_dropin_present <fix>
grub_dropin_present() { [ -f "$(sof_path "$(grub_dropin_rel "$1")")" ]; }

# grub_dropin_install <component> <fix> <args> : (re)write the drop-in
# through the manifest. Sets GRUB_CHANGED=1 when its content changed.
grub_dropin_install() {
    local comp=$1 fix=$2 args=$3 rel real tmp
    rel=$(grub_dropin_rel "$fix")
    real=$(sof_path "$rel")
    tmp=$(mktemp "${TMPDIR:-/tmp}/sof-grubd.XXXXXX") || return 1
    grub_render_dropin "$fix" "$args" >"$tmp"
    if [ -f "$real" ] && cmp -s "$tmp" "$real" && manifest_has "$rel"; then
        rm -f "$tmp"
        return 0
    fi
    GRUB_CHANGED=1
    manifest_install_file "$tmp" "$rel" "$comp" 0644 shared
    rm -f "$tmp"
}

# grub_dropin_remove <fix> : remove the drop-in (manifest entry included).
grub_dropin_remove() {
    local rel real
    rel=$(grub_dropin_rel "$1")
    real=$(sof_path "$rel")
    if [ -e "$real" ] || manifest_has "$rel"; then
        GRUB_CHANGED=1
        [ "$SOF_DRY_RUN" = 1 ] && printf '[dry-run] rm %s\n' "$rel" >&2 || rm -f "$real"
        manifest_forget "$rel"
    fi
    return 0
}

# grub_cfg_rel : the slot's grub.cfg (root-relative; /efi is the slot's own
# efi partition both on the booted system and in a composite slot root).
grub_cfg_rel() { printf '%s\n' "$SLOTS_GRUB_CFG_REL"; }

# grub_cfg_has_arg <arg> : a kernel line of the slot's grub.cfg carries the
# argument as a whole word. 1 when absent, 2 when there is no grub.cfg.
grub_cfg_has_arg() {
    local f
    f=$(sof_path "$(grub_cfg_rel)")
    [ -f "$f" ] || return 2
    awk -v a="$1" '
        function kw(n) { return (NF >= n) ? $n : "" }
        (kw(1) ~ /^linux(efi)?$/ || kw(2) ~ /^linux(efi)?$/) {
            for (i = 1; i <= NF; i++) if ($i == a) { found = 1; exit }
        }
        END { exit !found }' "$f"
}

# grub_cmdline_has_arg <arg> : the running kernel was booted with it.
grub_cmdline_has_arg() {
    local f
    f=$(sof_path "$GRUB_CMDLINE_REL")
    [ -r "$f" ] || return 2
    tr ' ' '\n' <"$f" | grep -Fxq -- "$1"
}

# ---------------------------------------------------------------- backup --

grub_backup_dir() { sof_path "$GRUB_BACKUP_REL/$1"; }
grub_backup_file() { printf '%s/grub.cfg\n' "$(grub_backup_dir "$1")"; }

# grub_backup_valid <slot> : saved original exists and matches its digest.
grub_backup_valid() {
    local b
    b=$(grub_backup_file "$1")
    [ -f "$b" ] && [ -f "$b.sha256" ] || return 1
    [ "$(sof_sha256 "$b")" = "$(cat "$b.sha256")" ]
}

# grub_backup_save <slot> <args...> : save the slot's grub.cfg as the stock
# original unless it already carries one of <args> (then it is ours) or a
# lib/slots.sh marker. Refreshed when the stock file changed. Idempotent.
grub_backup_save() {
    local slot=$1 real b a
    shift
    real=$(sof_path "$(grub_cfg_rel)")
    [ -f "$real" ] || return 0
    slots_entry_is_modified "$real" && return 0
    for a in "$@"; do
        grub_cfg_has_arg "$a" && return 0
    done
    b=$(grub_backup_file "$slot")
    if [ -f "$b" ] && cmp -s "$real" "$b" && grub_backup_valid "$slot"; then
        return 0
    fi
    if [ "$SOF_DRY_RUN" = 1 ]; then
        printf '[dry-run] save %s -> %s\n' "$(grub_cfg_rel)" "$b" >&2
        return 0
    fi
    mkdir -p "$(dirname "$b")"
    cp -p "$real" "$b.tmp" && mv -f "$b.tmp" "$b"
    sof_sha256 "$b" >"$b.sha256"
    printf '%s\n' "$(grub_cfg_rel)" >"$(dirname "$b")/entry-path"
    log_info "saved the stock grub.cfg of slot $slot to ${b#"$SOF_ROOT"}"
}

# ---------------------------------------------------------- regenerate --

grub_regen_file() { sof_path "$GRUB_REGEN_REL"; }

# grub_regenerate_pending : prints the slot a regeneration is pending for.
grub_regenerate_pending() {
    local f
    f=$(grub_regen_file)
    [ -f "$f" ] || return 1
    sed -n 's/^slot=//p' "$f" | head -n1
}

# _grub_note_pending <slot>
_grub_note_pending() {
    local f
    f=$(grub_regen_file)
    [ "$SOF_DRY_RUN" = 1 ] || mkdir -p "$(dirname "$f")"
    printf 'slot=%s\nts=%s\n' "$1" "$(_sof_ts)" | sof_atomic_write "$f" 0644
}

# grub_regenerate_clear
grub_regenerate_clear() {
    local f
    f=$(grub_regen_file)
    [ -f "$f" ] && sof_run rm -f "$f"
    return 0
}

# grub_regenerate [slot] : regenerate the slot's grub.cfg from the drop-ins.
# Booted system: `update-grub` now. Mounted slot (`apply --slot`, exported
# as SOF_APPLY_SLOT=1) or fixture root: noted for later (the RAUC handler or
# the boot service picks it up). Returns 1 when update-grub failed or is
# missing on a live system.
grub_regenerate() {
    local slot=${1:-}
    [ -n "$slot" ] || slot=$(slots_active 2>/dev/null) || slot=unknown
    if [ "$SOF_DRY_RUN" = 1 ]; then
        printf '[dry-run] update-grub (slot %s)\n' "$slot" >&2
        return 0
    fi
    if [ "${SOF_APPLY_SLOT:-0}" = 1 ] || [ -n "$SOF_ROOT" ]; then
        _grub_note_pending "$slot"
        log_info "grub.cfg of slot $slot must be regenerated (noted; done by the update handler or on the next boot)"
        return 0
    fi
    if ! sof_have update-grub; then
        _grub_note_pending "$slot"
        log_warn "update-grub not found; grub.cfg of slot $slot not regenerated"
        return 1
    fi
    if sof_run update-grub >/dev/null 2>&1; then
        grub_regenerate_clear
        log_info "grub.cfg of slot $slot regenerated (update-grub)"
        return 0
    fi
    _grub_note_pending "$slot"
    log_warn "update-grub failed; grub.cfg of slot $slot not regenerated"
    return 1
}

# grub_regenerate_slot <slot> : regenerate a non-booted slot's grub.cfg in
# the stock way, from the booted system: holo-chroot (steamos-chroot on
# older images) --partset <slot> -- update-grub. Live system only; on a
# fixture root it only logs. Clears the pending note on success.
grub_regenerate_slot() {
    local slot=$1 tool="" t
    slots_valid_name "$slot" || return 2
    if [ -n "$SOF_ROOT" ] || [ "$SOF_DRY_RUN" = 1 ]; then
        printf '[%s] holo-chroot --partset %s -- update-grub\n' "$([ "$SOF_DRY_RUN" = 1 ] && echo dry-run || echo fixture)" "$slot" >&2
        return 0
    fi
    for t in holo-chroot steamos-chroot; do
        if sof_have "$t"; then
            tool=$t
            break
        fi
    done
    if [ -z "$tool" ]; then
        log_warn "no holo-chroot: grub.cfg of slot $slot is regenerated on its first boot instead"
        return 1
    fi
    if "$tool" --partset "$slot" -- update-grub >/dev/null 2>&1; then
        grub_regenerate_clear
        log_info "grub.cfg of slot $slot regenerated ($tool update-grub)"
        return 0
    fi
    log_warn "$tool --partset $slot -- update-grub failed; grub.cfg of slot $slot is regenerated on its first boot instead"
    return 1
}

# grub_regenerate_if_pending : the boot service's repair step on a live
# system: a pending note for the booted slot means a previous regeneration
# did not happen; run update-grub now.
grub_regenerate_if_pending() {
    local want cur
    want=$(grub_regenerate_pending) || return 0
    cur=$(slots_active 2>/dev/null) || cur=""
    if [ -n "$cur" ] && [ "$want" != unknown ] && [ "$want" != "$cur" ]; then
        log_debug "grub regeneration pending for slot $want, booted $cur; leaving it"
        return 0
    fi
    grub_regenerate "$cur"
}

# grub_restore_report <slot> : after a regeneration that removed our last
# drop-in, say whether grub.cfg is byte-identical to the saved stock original.
grub_restore_report() {
    local slot=$1 real b
    real=$(sof_path "$(grub_cfg_rel)")
    b=$(grub_backup_file "$slot")
    grub_backup_valid "$slot" || return 0
    if cmp -s "$real" "$b"; then
        log_info "grub.cfg of slot $slot is byte-identical to the saved stock original"
    else
        log_info "grub.cfg of slot $slot was regenerated and differs from the copy saved on install (SteamOS changed the stock file in between); the regenerated one is current"
    fi
}
