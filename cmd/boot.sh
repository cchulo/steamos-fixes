# SPDX-License-Identifier: GPL-2.0-only
# summary: boot-time check run by steamos-fixes.service: re-apply what an update dropped, start module builds, probe
#
# Steps (plan §4.2 step 2), each bounded and non-fatal:
#   1. apply --missing-only: components whose files or registrations
#      drifted (e.g. after a SteamOS update) are re-applied, then a pending
#      grub.cfg regeneration for this slot is run (lib/grub.sh);
#   2. if the running kernel has no modules of ours and this checkout has a
#      `rebuild` command, start it detached (systemd-run) — it takes
#      effect on the next boot;
#   3. probes + state/status.json;
#   4. if anything is worth telling the user, write state/notify for the
#      user-session notifier. Consumes state/pending-reboot-check.

# shellcheck source=cmd/apply.sh
. "$SOF_SRC/cmd/apply.sh"
# shellcheck source=lib/grub.sh
. "$SOF_SRC/lib/grub.sh"

# boot_kick_rebuild <kver> : start a detached rebuild. Never waits.
boot_kick_rebuild() {
    local kver=$1
    if [ -n "$SOF_ROOT" ]; then
        log_info "would start a detached rebuild for $kver (fixture root: not starting)"
        return 0
    fi
    if sof_have systemd-run; then
        sof_run systemd-run --no-block --collect --unit="${SOF_NAME}-rebuild" \
            --description="steamos-fixes: build kernel modules for $kver" \
            "$SOF_SRC/steamos-fixes.sh" rebuild --kver "$kver" >/dev/null 2>&1 \
            || log_warn "could not start the detached rebuild for $kver"
    else
        log_warn "systemd-run not available; run '$SOF_NAME rebuild --kver $kver' manually"
    fi
}

cmd_boot() {
    local kver pending="" superseded="" update="" blocked="" c st state notify
    # shellcheck disable=SC2119  # require_root takes no arguments here
    require_root
    sof_check_readonly_root
    state="$(sof_state_dir)/state"
    [ "$SOF_DRY_RUN" = 1 ] || mkdir -p "$state" "$(sof_state_dir)/log"

    apply_components 1 "" || true
    # A grub.cfg regeneration the update handler could not do for this slot.
    grub_regenerate_if_pending || true

    kver=$(probe_running_kver)
    # Staged modules live under the early boot dir (/etc), not the state dir.
    if [ -f "$SOF_SRC/cmd/rebuild.sh" ] && ! [ -d "$(sof_path "${SOF_EARLY_REL}/modules/$kver")" ]; then
        pending="kernel modules for $kver"
        boot_kick_rebuild "$kver"
    fi

    for c in $(component_list); do
        st=$(component_status "$c" 2>/dev/null || true)
        [ "$st" = superseded ] && superseded="$superseded $c"
    done
    superseded=${superseded# }

    if [ -f "$state/pending-reboot-check" ]; then
        update=$(sed -n 's/^from=//p' "$state/pending-reboot-check")" -> "$(sed -n 's/^to=//p' "$state/pending-reboot-check")
        sof_run rm -f "$state/pending-reboot-check"
    fi
    if [ -f "$state/update-blocked" ]; then
        blocked=$(sed -n 's/^kver=//p' "$state/update-blocked")
    fi

    status_write_json last_command boot reapplied "$APPLY_DONE" failed "$APPLY_FAILED" \
        pending "$pending" superseded "$superseded" update "$update" blocked "$blocked"

    notify="$state/notify"
    if [ -n "$APPLY_DONE$APPLY_FAILED$pending$superseded$update$blocked" ]; then
        printf 'update=%s\nreapplied=%s\nfailed=%s\npending=%s\nsuperseded=%s\nblocked=%s\n' \
            "$update" "$APPLY_DONE" "$APPLY_FAILED" "$pending" "$superseded" "$blocked" \
            | sof_atomic_write "$notify" 0644
    elif [ -f "$notify" ]; then
        sof_run rm -f "$notify"
    fi
    return 0
}
