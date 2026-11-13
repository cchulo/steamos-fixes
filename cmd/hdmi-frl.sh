# SPDX-License-Identifier: GPL-2.0-only
# summary: HDMI 2.1 FRL on the native HDMI port: frl [--without-vrr] | tmds | status
#
#   frl      want FRL (4K120 at up to 12-bit, 4K144 at 10-bit, 4:4:4, HDR). The kernel argument is
#            set only while a patched amdgpu for the running kernel is staged
#            (VRR on FRL needs it); --without-vrr sets it regardless.
#   tmds     back to the stock link (HDMI 2.0 TMDS, VRR works with stock amdgpu).
#   status   what is configured, what is running, VRR range, mode and bpc.
# Both switches reconcile the fix (apply --only hdmi_frl) and need a reboot.
# shellcheck source=lib/component.sh
. "$SOF_SRC/lib/component.sh"

_hdmi_frl_usage() {
    sed -n '3,9s/^# \{0,1\}//p' "$SOF_SRC/cmd/hdmi-frl.sh"
}

# _hdmi_frl_debugfs_dirs : one DRM debugfs directory per device. Kernel 7.x
# registers each card under its PCI slot (0000:03:00.0) and aliases it
# under its minor numbers (0, 128); prefer the slot names, else the numbers.
_hdmi_frl_debugfs_dirs() {
    local d any=0
    for d in "$(sof_path /sys/kernel/debug/dri)"/0000:*; do
        [ -d "$d" ] || continue
        any=1
        printf '%s\n' "$d"
    done
    [ "$any" = 1 ] && return 0
    for d in "$(sof_path /sys/kernel/debug/dri)"/[0-9]*; do
        [ -d "$d" ] || continue
        case "${d##*/}" in [0-9] | [0-9][0-9]) printf '%s\n' "$d" ;; esac
    done
    return 0
}

# _hdmi_frl_first_line <glob...> : first line of the first readable file.
_hdmi_frl_first_line() {
    local f
    for f in "$@"; do
        [ -r "$f" ] && {
            head -n1 "$f"
            return 0
        }
    done
    return 1
}

# _hdmi_frl_status_report : the human report.
_hdmi_frl_status_report() {
    local kver c d dbg f rng bpc modes lp loaded v
    kver=$(probe_running_kver)
    printf 'hdmi-frl: %s\n' "$(component_status hdmi_frl)"
    printf '  %-22s %s\n' "detail:" "$(component_status_detail hdmi_frl)"
    printf '  %-22s %s\n' "configured:" "$(hdmi_frl_mode)$(hdmi_frl_allow_no_vrr && printf ' (FRL even without VRR)')"
    if grub_cmdline_has_arg "$HDMI_FRL_ARG"; then
        printf '  %-22s %s\n' "running:" "FRL argument on the kernel command line"
    else
        printf '  %-22s %s\n' "running:" "TMDS (no $HDMI_FRL_ARG on the command line)"
    fi
    printf '  %-22s %s\n' "kernel:" "$kver"
    if modules_available "$kver"; then
        lp=$(modules_load_path amdgpu | tr '-' ' ')
        loaded=0
        hdmi_frl_patched_loaded >/dev/null 2>&1 || loaded=$?
        case "$loaded" in
            0) printf '  %-22s %s\n' "amdgpu:" "patched build loaded ($lp)" ;;
            1) printf '  %-22s %s\n' "amdgpu:" "patched build staged, stock module loaded ($lp; reboot, or see journalctl -t $SOF_NAME)" ;;
            *) printf '  %-22s %s\n' "amdgpu:" "patched build staged ($lp)" ;;
        esac
    elif hdmi_frl_module_superseded "$kver"; then
        printf '  %-22s %s\n' "amdgpu:" "stock (Valve's $kver already carries the fix)"
    else
        printf '  %-22s %s\n' "amdgpu:" "stock (no patched build for $kver; run: $SOF_NAME rebuild)"
    fi
    f=$(sof_path /sys/module/amdgpu/taint)
    [ -r "$f" ] && printf '  %-22s %s\n' "amdgpu taint:" "$(cat "$f")"
    if modules_lockdown_active; then
        printf '  %-22s %s\n' "kernel lockdown:" "active (unsigned modules cannot load)"
    fi
    for c in $(hdmi_frl_connectors); do
        printf '  %s\n' "$c"
        modes=$(_hdmi_frl_first_line "$(sof_path "/sys/class/drm/$c/modes")" || true)
        printf '    %-20s %s\n' "status:" "$(_hdmi_frl_first_line "$(sof_path "/sys/class/drm/$c/status")" || echo unknown)"
        printf '    %-20s %s\n' "preferred mode:" "${modes:-unknown}"
        # debugfs needs root: vrr_range and the current bpc per crtc.
        rng=""
        for dbg in $(_hdmi_frl_debugfs_dirs); do
            dbg="$dbg/${c#card*-}/vrr_range"
            [ -r "$dbg" ] && rng=$(tr '\n' ' ' <"$dbg" 2>/dev/null) && break
        done
        if [ -n "$rng" ]; then
            printf '    %-20s %s\n' "vrr_range:" "$rng"
        elif sof_have modetest && [ -z "$SOF_ROOT" ]; then
            rng=$(modetest -M amdgpu -c 2>/dev/null | awk -v c="${c#card*-}" '$0 ~ c { inconn = 1 } inconn && /vrr_capable/ { getline; print "vrr_capable " $NF; exit }')
            printf '    %-20s %s\n' "vrr_capable:" "${rng:-unknown (modetest)}"
        else
            printf '    %-20s %s\n' "vrr_range:" "run as root for /sys/kernel/debug/dri/*/${c#card*-}/vrr_range"
        fi
        bpc=""
        for d in $(_hdmi_frl_debugfs_dirs); do
            for dbg in "$d"/crtc-*/amdgpu_current_bpc; do
                [ -r "$dbg" ] || continue
                v=$(tr '\n' ' ' <"$dbg" 2>/dev/null) || continue
                # an unused crtc reads "No such device"; only live ones have a value
                bpc="${bpc:+$bpc, }${d##*/}/$(basename "$(dirname "$dbg")"): ${v% }"
            done
        done
        [ -n "$bpc" ] && printf '    %-20s %s\n' "current bpc:" "$bpc"
    done
    printf '  %-22s %s\n' "gamescope:" "the active mode and bpc are in ~/.steam/steam/logs/console-linux.txt (gamescope lines) or journalctl --user -u gamescope-session"
}

cmd_hdmi_frl() {
    local action=${1:-status} novrr=""
    [ $# -gt 0 ] && shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --without-vrr) novrr=--without-vrr ;;
            *) die 2 "hdmi-frl: unknown argument '$1'" ;;
        esac
        shift
    done
    component_load hdmi_frl
    case "$action" in
        status)
            _hdmi_frl_status_report
            ;;
        frl | tmds)
            require_root hdmi-frl
            sof_check_readonly_root
            [ "$action" = frl ] || [ -z "$novrr" ] || die 2 "hdmi-frl: --without-vrr only applies to frl"
            if ! hdmi_frl_applies >/dev/null 2>&1; then
                die "hdmi-frl: $(hdmi_frl_applies 2>/dev/null || true); nothing to do on this machine"
            fi
            # shellcheck disable=SC2086  # novrr is one word or empty
            hdmi_frl_set_mode "$action" $novrr
            component_apply hdmi_frl || die "hdmi-frl: apply failed; see above"
            printf 'hdmi-frl: %s configured (%s). Reboot to apply.\n' "$action" "$(component_status_detail hdmi_frl)"
            ;;
        -h | --help | help) _hdmi_frl_usage ;;
        *) die 2 "hdmi-frl: expected frl [--without-vrr] | tmds | status" ;;
    esac
}
