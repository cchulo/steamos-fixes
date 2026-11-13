# SPDX-License-Identifier: GPL-2.0-only
# fixes/hdmi-frl/component.sh — HDMI 2.1 FRL with VRR on a native HDMI port
# of an amdgpu device (STEAMOS-FIXES-PLAN.md §1.1, §6; docs/fixes/hdmi-frl.md).
#
# Two parts:
#   * the kernel argument amdgpu.dcfeaturemask=0x402 (DC_FRL_MASK | the
#     default 0x2), through /etc/default/grub.d/steamos-fixes-hdmi-frl.cfg
#     (lib/grub.sh): FRL instead of TMDS: 4K120 at up to 12-bit or 4K144 at 10-bit, 4:4:4,
#     HDR, uncompressed (12-bit at 144 Hz would need DSC); what is driven is
#     gamescope's choice through the connector's max bpc;
#   * the patched amdgpu (patches/kernel/0001-*, modules-hdmi-frl.list),
#     staged and loaded by the modules component: VRR on an FRL link.
# FRL without the patched module means FRL without VRR, the regression Valve
# avoided by keeping FRL off. So the argument is only wanted while a patched
# amdgpu for the kernel in question is staged (or the user asked for FRL
# regardless with `hdmi-frl frl --without-vrr`); otherwise the drop-in is
# removed and the link runs TMDS with VRR, which is stock behaviour, and the
# status says "degraded" and why. On a slot that is not booted (RAUC
# post-install) "the kernel in question" is that slot's kernel (SOF_KVER).
#
# Superseded when the running kernel enables FRL by default: Valve's
# 7.2.10-valve1 does (amdgpu_drv.c: amdgpu_dc_feature_mask includes
# DC_FRL_MASK) and also carries the freesync fix; mainline 7.4 enables FRL
# with VRR/ALLM. Then the drop-in is removed and the stock module is used.
#
# State (shared /var/lib/steamos-fixes/state): hdmi-frl.mode = frl|tmds
# (default frl once installed), hdmi-frl.allow-no-vrr (marker).

# shellcheck source=lib/grub.sh
. "$SOF_SRC/lib/grub.sh"
# shellcheck source=lib/modules.sh
. "$SOF_SRC/lib/modules.sh"

# shellcheck disable=SC2034  # read by lib/component.sh
COMPONENT_DESCRIPTION="HDMI 2.1 FRL (4K120 at up to 12-bit, 4K144 at 10-bit, 4:4:4, HDR) with VRR on the native HDMI port of an amdgpu device"

HDMI_FRL_ARG="amdgpu.dcfeaturemask=0x402"
HDMI_FRL_MASK=1024 # DC_FRL_MASK = 0x400
HDMI_FRL_FIX=hdmi-frl
HDMI_FRL_MODE_REL="${SOF_STATE_REL}/state/hdmi-frl.mode"
HDMI_FRL_NOVRR_REL="${SOF_STATE_REL}/state/hdmi-frl.allow-no-vrr"
HDMI_FRL_MODULE=amdgpu
# Valve kernel tags from which FRL is on by default, per upstream series
# ("<series> <tag>"; a later tag of the same series counts too). 7.3.1-valve1
# has it off again (not forward-ported), so 7.3 is not listed. From 7.4 on
# mainline enables it.
HDMI_FRL_DEFAULT_ON_TAGS="7.2 7.2.10-valve1"
HDMI_FRL_DEFAULT_ON_FROM_BASE="7.4.0"
export HDMI_FRL_ARG HDMI_FRL_MODE_REL HDMI_FRL_NOVRR_REL

hdmi_frl_files() { :; }

# ------------------------------------------------------------- hardware --

# hdmi_frl_connectors : native HDMI connectors on amdgpu, one per line
# (card0-HDMI-A-1 ...). The connector's device/ is the DRM card, whose
# device/driver symlink names the driver.
hdmi_frl_connectors() {
    local c drv
    for c in "$(sof_path /sys/class/drm)"/card*-HDMI-A-*; do
        [ -d "$c" ] || continue
        drv=$(readlink "$c/device/driver" 2>/dev/null || readlink "$c/device/device/driver" 2>/dev/null || true)
        case "${drv##*/}" in
            amdgpu) basename "$c" ;;
        esac
    done
}

# hdmi_frl_applies : 0 native HDMI on amdgpu, 1 none, 2 no DRM sysfs to look at.
hdmi_frl_applies() {
    local found
    [ -d "$(sof_path /sys/class/drm)" ] || {
        printf 'no /sys/class/drm to inspect\n'
        return 2
    }
    found=$(hdmi_frl_connectors | tr '\n' ' ')
    if [ -n "$found" ]; then
        printf 'native HDMI on amdgpu: %s\n' "${found% }"
        return 0
    fi
    printf 'no native HDMI connector on an amdgpu device\n'
    return 1
}

# --------------------------------------------------------------- state --

hdmi_frl_mode() {
    local f
    f=$(sof_path "$HDMI_FRL_MODE_REL")
    case "$(head -n1 "$f" 2>/dev/null)" in
        tmds) printf 'tmds\n' ;;
        *) printf 'frl\n' ;;
    esac
}

hdmi_frl_allow_no_vrr() { [ -f "$(sof_path "$HDMI_FRL_NOVRR_REL")" ]; }

# hdmi_frl_set_mode <frl|tmds> [--without-vrr]
hdmi_frl_set_mode() {
    local f
    f=$(sof_path "$HDMI_FRL_MODE_REL")
    [ "$SOF_DRY_RUN" = 1 ] || mkdir -p "$(dirname "$f")"
    printf '%s\n' "$1" | sof_atomic_write "$f" 0644
    f=$(sof_path "$HDMI_FRL_NOVRR_REL")
    if [ "${2:-}" = --without-vrr ]; then
        printf '%s\n' "$(_sof_ts)" | sof_atomic_write "$f" 0644
    elif [ -f "$f" ]; then
        sof_run rm -f "$f"
    fi
}

# hdmi_frl_installed : the fix has been applied here (state or drop-in).
hdmi_frl_installed() {
    [ -f "$(sof_path "$HDMI_FRL_MODE_REL")" ] || grub_dropin_present "$HDMI_FRL_FIX"
}

# ------------------------------------------------------------- kernel ---

# hdmi_frl_kernel_default_on <kver> : the kernel enables FRL without the
# argument (version threshold table above).
hdmi_frl_kernel_default_on() {
    local kver=$1 base tag series want_series want_tag
    base=${kver%%-*}
    case "$base" in [0-9]*.[0-9]*) ;; *) return 1 ;; esac
    tag=$(printf '%s' "$kver" | sed -n 's/^[0-9.]*-\(valve[0-9]*\).*/\1/p')
    if sof_version_ge "$base" "$HDMI_FRL_DEFAULT_ON_FROM_BASE"; then
        return 0
    fi
    series=$(printf '%s' "$base" | cut -d. -f1,2)
    set -- $HDMI_FRL_DEFAULT_ON_TAGS
    while [ $# -ge 2 ]; do
        want_series=$1
        want_tag=$2
        shift 2
        [ "$series" = "$want_series" ] || continue
        if [ "$base" != "${want_tag%%-*}" ]; then
            sof_version_ge "$base" "${want_tag%%-*}" && return 0
            return 1
        fi
        [ -n "$tag" ] || return 1
        [ "${tag#valve}" -ge "${want_tag#*-valve}" ] 2>/dev/null && return 0
        return 1
    done
    return 1
}

# hdmi_frl_live_default_on : the booted kernel runs with the FRL bit set
# although no dcfeaturemask was passed on the command line.
hdmi_frl_live_default_on() {
    local f v
    grub_cmdline_has_arg "$HDMI_FRL_ARG" && return 1
    f=$(sof_path /proc/cmdline)
    [ -r "$f" ] && tr ' ' '\n' <"$f" | grep -q '^amdgpu\.dcfeaturemask=' && return 1
    f=$(sof_path /sys/module/amdgpu/parameters/dcfeaturemask)
    [ -r "$f" ] || return 1
    v=$(tr -d ' \n' <"$f")
    case "$v" in '' | *[!0-9]*) return 1 ;; esac
    [ $((v & HDMI_FRL_MASK)) -ne 0 ]
}

# hdmi_frl_probe : 0 superseded (FRL on by default), 1 still needed, 2 no
# kernel version to judge.
hdmi_frl_probe() {
    local kver
    kver=$(probe_running_kver 2>/dev/null) || return "$PROBE_UNKNOWN"
    [ -n "$kver" ] || return "$PROBE_UNKNOWN"
    hdmi_frl_kernel_default_on "$kver" && return "$PROBE_YES"
    hdmi_frl_live_default_on && return "$PROBE_YES"
    return "$PROBE_NO"
}

# hdmi_frl_module_ready <kver> : a patched amdgpu is staged for the kernel
# (or the build says the stock one already has the fix) and could load.
hdmi_frl_module_ready() {
    modules_lockdown_active && return 1
    modules_available "$1" || return 1
    return 0
}

# hdmi_frl_module_superseded <kver>
hdmi_frl_module_superseded() {
    modules_superseded_names "$1" | grep -Fxq "$HDMI_FRL_MODULE"
}

# hdmi_frl_patched_loaded : the running amdgpu is our build (srcversion
# equal to the staged module's). 0 yes, 1 stock, 2 cannot tell.
hdmi_frl_patched_loaded() {
    local kver ko live ours
    kver=$(probe_running_kver)
    live=$(sof_path /sys/module/amdgpu/srcversion)
    [ -r "$live" ] || return 2
    ko="$(sof_path "$(modules_dir_for "$kver")")/$HDMI_FRL_MODULE.ko.zst"
    [ -s "$ko" ] || return 1
    if [ -f "$ko.srcversion" ]; then
        ours=$(cat "$ko.srcversion")
    elif sof_have modinfo; then
        ours=$(modinfo -F srcversion "$ko" 2>/dev/null || true)
    fi
    [ -n "$ours" ] || return 2
    [ "$(cat "$live")" = "$ours" ]
}

# hdmi_frl_want_arg [kver] : the argument belongs on this kernel's command line.
hdmi_frl_want_arg() {
    local kver=${1:-}
    [ -n "$kver" ] || kver=$(probe_running_kver)
    [ "$(hdmi_frl_mode)" = frl ] || return 1
    hdmi_frl_allow_no_vrr && return 0
    hdmi_frl_module_ready "$kver" || return 1
    hdmi_frl_module_superseded "$kver" && return 1
    return 0
}

# ---------------------------------------------------------------- apply --

# hdmi_frl_apply : reconcile the drop-in with what is wanted for this root's
# kernel, regenerate grub.cfg when it changed (lib/grub.sh decides how).
hdmi_frl_apply() {
    local kver slot rc=0 prc=0
    kver=$(probe_running_kver)
    slot=$(slots_active 2>/dev/null) || slot=unknown
    GRUB_CHANGED=0
    hdmi_frl_probe >/dev/null 2>&1 || prc=$?
    if [ "$prc" = "$PROBE_YES" ]; then
        if grub_dropin_present "$HDMI_FRL_FIX"; then
            log_info "hdmi-frl: kernel $kver enables FRL by default; removing our kernel argument"
        fi
        grub_dropin_remove "$HDMI_FRL_FIX"
    elif hdmi_frl_want_arg "$kver"; then
        [ -f "$(sof_path "$HDMI_FRL_MODE_REL")" ] || hdmi_frl_set_mode frl
        grub_backup_save "$slot" "$HDMI_FRL_ARG"
        grub_dropin_install hdmi_frl "$HDMI_FRL_FIX" "$HDMI_FRL_ARG"
    else
        [ -f "$(sof_path "$HDMI_FRL_MODE_REL")" ] || hdmi_frl_set_mode frl
        if grub_dropin_present "$HDMI_FRL_FIX"; then
            log_info "hdmi-frl: no patched amdgpu for $kver; removing the FRL argument so the link runs TMDS with VRR (stock) until a build exists"
        fi
        grub_dropin_remove "$HDMI_FRL_FIX"
    fi
    if [ "$GRUB_CHANGED" = 1 ]; then
        grub_regenerate "$slot" || rc=1
        if ! grub_dropin_present "$HDMI_FRL_FIX" && [ -z "$SOF_ROOT" ]; then
            grub_restore_report "$slot"
        fi
    fi
    return "$rc"
}

# --------------------------------------------------------------- status --

# hdmi_frl_status : active | degraded | stock | superseded | n/a
hdmi_frl_status() {
    local kver prc loaded
    prc=0
    hdmi_frl_probe >/dev/null 2>&1 || prc=$?
    if ! hdmi_frl_installed; then
        if hdmi_frl_applies >/dev/null 2>&1; then
            [ "$prc" = "$PROBE_YES" ] && printf 'superseded\n' || printf 'stock\n'
        else
            printf 'n/a\n'
        fi
        return 0
    fi
    [ "$prc" = "$PROBE_YES" ] && {
        printf 'superseded\n'
        return 0
    }
    [ "$(hdmi_frl_mode)" = tmds ] && {
        printf 'stock\n'
        return 0
    }
    kver=$(probe_running_kver)
    if grub_dropin_present "$HDMI_FRL_FIX" && grub_cmdline_has_arg "$HDMI_FRL_ARG"; then
        loaded=0
        hdmi_frl_patched_loaded >/dev/null 2>&1 || loaded=$?
        if hdmi_frl_allow_no_vrr; then
            printf 'active\n'
        elif hdmi_frl_module_ready "$kver" && [ "$loaded" != 1 ]; then
            printf 'active\n'
        else
            printf 'degraded\n'
        fi
        return 0
    fi
    printf 'degraded\n'
}

hdmi_frl_status_detail() {
    local kver st rc
    st=$(hdmi_frl_status)
    kver=$(probe_running_kver)
    case "$st" in
        n/a) hdmi_frl_applies 2>/dev/null || true ;;
        superseded)
            if hdmi_frl_kernel_default_on "$kver"; then
                printf 'kernel %s enables HDMI FRL by default (VRR included); nothing to add\n' "$kver"
            else
                printf 'the running amdgpu has FRL on without our argument; nothing to add\n'
            fi
            ;;
        stock)
            if hdmi_frl_installed; then
                printf 'TMDS by choice (run: %s hdmi-frl frl)\n' "$SOF_NAME"
            else
                printf 'not installed\n'
            fi
            ;;
        active)
            if hdmi_frl_allow_no_vrr; then
                printf 'FRL on, VRR not required (--without-vrr)\n'
            else
                printf 'FRL on with the patched amdgpu for %s\n' "$kver"
            fi
            ;;
        degraded)
            if modules_lockdown_active; then
                printf 'kernel lockdown is active: the patched amdgpu cannot load, so the FRL argument is withheld (TMDS with VRR, stock)\n'
            elif ! hdmi_frl_module_ready "$kver"; then
                printf 'no patched amdgpu for %s yet: running stock TMDS with VRR until a build exists (release asset or on-device rebuild, then reboot)\n' "$kver"
            elif ! grub_dropin_present "$HDMI_FRL_FIX"; then
                printf 'patched amdgpu staged but the kernel argument is not set (run: %s apply --only hdmi_frl)\n' "$SOF_NAME"
            elif ! grub_cmdline_has_arg "$HDMI_FRL_ARG"; then
                if [ "$(grub_regenerate_pending 2>/dev/null)" != "" ]; then
                    printf 'kernel argument set, grub.cfg regeneration pending; reboot after it ran\n'
                else
                    printf 'kernel argument set; reboot to enable FRL\n'
                fi
            else
                rc=0
                hdmi_frl_patched_loaded >/dev/null 2>&1 || rc=$?
                if [ "$rc" = 1 ]; then
                    printf 'FRL on but the stock amdgpu is loaded (no VRR on this link); check journalctl -t %s for the loader fallback\n' "$SOF_NAME"
                else
                    printf 'FRL on, patched module state unknown\n'
                fi
            fi
            ;;
    esac
}

# hdmi_frl_remove : back to stock before the manifest removal.
hdmi_frl_remove() {
    local slot
    slot=$(slots_active 2>/dev/null) || slot=unknown
    GRUB_CHANGED=0
    grub_dropin_remove "$HDMI_FRL_FIX"
    if [ "$GRUB_CHANGED" = 1 ]; then
        grub_regenerate "$slot" || true
        [ -z "$SOF_ROOT" ] && grub_restore_report "$slot"
    fi
    sof_run rm -f "$(sof_path "$HDMI_FRL_MODE_REL")" "$(sof_path "$HDMI_FRL_NOVRR_REL")"
    return 0
}
