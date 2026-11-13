# SPDX-License-Identifier: GPL-2.0-only
# components/modules.sh — version-gated substitution of the patched kernel
# modules (STEAMOS-FIXES-PLAN.md §3, §4.2c). See docs/kernel-modules.md.
#
# Files: the load-or-fallback helper (state dir, never /usr) and a modprobe.d
# drop-in generated at apply time from patches/kernel/modules*.list, so the
# install hooks always match the module lists.
#
# No depmod: the hooks are read by modprobe from modprobe.d on every call,
# our .ko files live outside /lib/modules, and depmod would have to write
# modules.dep under the read-only /usr/lib/modules.

# shellcheck source=lib/modules.sh
. "$SOF_SRC/lib/modules.sh"

# shellcheck disable=SC2034  # read by lib/component.sh
COMPONENT_DESCRIPTION="patched kernel modules of every fix, loaded only for a matching kernel"

modules_files() {
    printf 'bin/load-or-fallback\t%s\t0755\tshared\n' "$SOF_HELPER_REL"
}

modules_apply() {
    local tmp
    modules_ensure_base_dir
    tmp=$(mktemp "${TMPDIR:-/tmp}/sof-modprobe.XXXXXX") || return 1
    if ! modules_render_modprobe_conf >"$tmp"; then
        rm -f "$tmp"
        log_error "cannot generate the modprobe.d drop-in from the module lists"
        return 1
    fi
    manifest_install_file "$tmp" "$SOF_MODPROBE_CONF_REL" modules 0644 shared
    rm -f "$tmp"
    # Modules the initramfs loads need the early initrd override instead of
    # the hook (lib/modules.sh); keep it in step with what is staged.
    modules_override_sync "$(probe_running_kver)" || log_warn "early initrd override not in sync; see above"
    return 0
}

# modules_probe : 0 when the staged build for the running kernel marks every
# listed module superseded (Valve's tree already carries every patch, see
# build/build-modules.sh), 2 when the stock modules directory for the kernel
# is absent (nothing to inspect) or no build is staged yet, 1 otherwise.
# Whether a *fix* is superseded is the fix's own probe; this one only says
# whether any patched module is still worth loading.
modules_probe() {
    local kver
    kver=$(probe_running_kver)
    [ -d "$(sof_path "/usr/lib/modules/$kver")" ] || return "$PROBE_UNKNOWN"
    if modules_all_superseded "$kver"; then
        return "$PROBE_YES"
    fi
    [ -f "$(sof_path "$(modules_dir_for "$kver")")/BUILD-INFO" ] || return "$PROBE_UNKNOWN"
    return "$PROBE_NO"
}

# _modules_conf_current : the installed modprobe.d drop-in has one hook per
# module the lists name today. A checkout update that adds a module (e.g.
# asus-armoury) leaves the old drop-in verifying against the manifest; this
# makes status report "stock" so the boot service re-applies it.
_modules_conf_current() {
    local conf want
    conf=$(sof_path "$SOF_MODPROBE_CONF_REL")
    [ -f "$conf" ] || return 1
    want=$(modules_render_modprobe_conf) || return 1
    [ "$(cat "$conf")" = "$want" ]
}

# _modules_files_ok : helper and modprobe.d drop-in are installed unmodified
# and the drop-in matches the current module lists.
_modules_files_ok() {
    manifest_verify "$SOF_HELPER_REL" && manifest_verify "$SOF_MODPROBE_CONF_REL" \
        && _modules_conf_current
}

# _modules_override_ok <kver> : when a staged module is loaded by the
# initramfs, the override image is installed and the boot entry carries it.
_modules_override_ok() {
    local members n p dir slot
    members=$(modules_initramfs_members "$1" 2>/dev/null) || return 0
    [ -n "$members" ] || return 0
    dir=$(sof_path "$(modules_dir_for "$1")")
    while IFS="$(printf '\t')" read -r n p; do
        [ -n "$n" ] && [ -s "$dir/$n.ko.zst" ] || continue
        manifest_verify "$SOF_OVERRIDE_INITRD_REL" || return 1
        [ "$(slots_desired_get initrd 2>/dev/null || true)" = "$SOF_OVERRIDE_INITRD_REL" ] || return 1
        if slot=$(slots_active 2>/dev/null); then
            slots_entry_in_sync "$slot" || return 1
        fi
        return 0
    done <<EOF
$members
EOF
    return 0
}

# modules_status : active | stock | superseded | n/a
#   superseded  stock modules carry the fixes, or our build for this kernel
#               found every patch already upstream
#   active      hooks installed and patched modules staged for this kernel
#   stock       hooks installed but nothing staged for this kernel (pending
#               rebuild) or kernel lockdown blocks unsigned modules; or not
#               installed
#   n/a         not installed and the probe cannot tell
modules_status() {
    local kver rc
    kver=$(probe_running_kver)
    rc=0
    modules_probe >/dev/null 2>&1 || rc=$?
    if [ "$rc" = "$PROBE_YES" ] || modules_all_superseded "$kver"; then
        printf 'superseded\n'
        return 0
    fi
    if _modules_files_ok; then
        if modules_available "$kver" && ! modules_lockdown_active && _modules_override_ok "$kver"; then
            printf 'active\n'
        else
            printf 'stock\n'
        fi
        return 0
    fi
    if component_installed modules || [ "$rc" != "$PROBE_UNKNOWN" ]; then
        printf 'stock\n'
    else
        printf 'n/a\n'
    fi
}

# _modules_load_paths : "amdgpu: early initrd, foo: modprobe hook" for the
# listed modules.
_modules_load_paths() {
    local n out="" lp
    for n in $(modules_list_names 2>/dev/null); do
        lp=$(modules_load_path "$n")
        out="${out:+$out, }$n: $(printf '%s' "$lp" | tr '-' ' ')"
    done
    printf '%s\n' "${out:-no modules listed}"
}

# modules_status_detail : one human-readable line explaining the status.
modules_status_detail() {
    local kver why
    kver=$(probe_running_kver)
    if modules_lockdown_active; then
        printf 'kernel lockdown is active: unsigned modules cannot load, stock modules in use\n'
    elif modules_all_superseded "$kver"; then
        printf 'Valve kernel %s already contains every patch\n' "$kver"
    elif ! manifest_verify "$SOF_HELPER_REL" || ! manifest_verify "$SOF_MODPROBE_CONF_REL"; then
        printf 'modprobe hooks not installed\n'
    elif ! _modules_conf_current; then
        printf 'modprobe hooks out of date with the module lists (run: %s apply --only modules)\n' "$SOF_NAME"
    elif modules_available "$kver" && ! _modules_override_ok "$kver"; then
        printf 'patched modules staged for %s, but the early initrd override for the initramfs-loaded ones is not in the boot entry (run: %s apply --only modules)\n' "$kver" "$SOF_NAME"
    elif modules_available "$kver"; then
        printf 'patched modules staged for %s (%s)\n' "$kver" "$(_modules_load_paths)"
    elif why=$(modules_staged_stale "$kver"); then
        printf 'staged modules for %s are from another release (%s); run: %s rebuild\n' "$kver" "$why" "$SOF_NAME"
    else
        printf 'pending rebuild: no patched modules for %s yet (run: %s rebuild)\n' "$kver" "$SOF_NAME"
    fi
}
