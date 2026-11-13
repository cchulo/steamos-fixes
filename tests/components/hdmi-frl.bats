#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# fixes/hdmi-frl: hardware probe, superseded detection, apply/degrade/status,
# the hdmi-frl command (STEAMOS-FIXES-PLAN.md §6, §7).
load '../test_helper'
load '../update_helper'

KV=7.2.7-valve2-2-neptune-72-g31504582a073
KV_NEW=7.2.8-valve1-1-neptune-72-gabcdefabcdef
ARG=amdgpu.dcfeaturemask=0x402
DROPIN=/etc/default/grub.d/steamos-fixes-hdmi-frl.cfg
PATCH=0001-drm-amd-display-use-dc_is_hdmi_signal-in-freesync-caps.patch

setup() {
    export SOF_FIXES_DIR="$REPO_ROOT/fixes"
    make_root >/dev/null
    source_libs
    unset SOF_SLOT SOF_BOOT_ENTRY
    export SOF_KVER="$KV" SOF_SLOT=A
    export SOF_PATCHES_DIR="$REPO_ROOT/patches/kernel"
    fixture_partsets A
    fixture_grub
    STATE="$SOF_ROOT/var/lib/steamos-fixes/state"
    component_load hdmi_frl
}

# hdmi_on_amdgpu [card] : a native HDMI connector whose card is driven by amdgpu.
hdmi_on_amdgpu() {
    local c=${1:-card0}
    mkdir -p "$SOF_ROOT/sys/class/drm/$c-HDMI-A-1/device" "$SOF_ROOT/sys/bus/pci/drivers/amdgpu"
    ln -sfn ../../../../bus/pci/drivers/amdgpu "$SOF_ROOT/sys/class/drm/$c-HDMI-A-1/device/driver"
    fixture_file "/sys/class/drm/$c-HDMI-A-1/status" "connected
"
    fixture_file "/sys/class/drm/$c-HDMI-A-1/modes" "3840x2160
1920x1080
"
}

# staged_build <kver> [superseded] : a staged amdgpu build for kver made from
# the checkout's patch (or one that found the patch already upstream).
staged_build() {
    local d="$BATS_TEST_TMPDIR/build-$1"
    mkdir -p "$d"
    {
        printf 'kver=%s\nvermagic=%s SMP\n' "$1" "$1"
        printf 'patch.%s=%s\n' "$PATCH" "$(sof_sha256 "$REPO_ROOT/patches/kernel/$PATCH")"
        [ "${2:-}" = superseded ] && printf 'module.amdgpu=superseded\n'
    } >"$d/BUILD-INFO"
    [ "${2:-}" = superseded ] || printf 'patched amdgpu' >"$d/amdgpu.ko.zst"
    modules_stage "$1" "$d"
}

booted_with_arg() {
    fixture_file /proc/cmdline "BOOT_IMAGE=/boot/vmlinuz quiet $ARG splash
"
}

@test "applies only with a native HDMI connector on an amdgpu device" {
    run hdmi_frl_applies
    [ "$status" -eq 2 ]
    mkdir -p "$SOF_ROOT/sys/class/drm/card0-DP-1"
    run hdmi_frl_applies
    [ "$status" -eq 1 ]
    assert_output_contains "no native HDMI connector on an amdgpu device"
    # HDMI on another driver does not count
    mkdir -p "$SOF_ROOT/sys/class/drm/card1-HDMI-A-1/device" "$SOF_ROOT/sys/bus/pci/drivers/i915"
    ln -sfn ../../../../bus/pci/drivers/i915 "$SOF_ROOT/sys/class/drm/card1-HDMI-A-1/device/driver"
    run hdmi_frl_applies
    [ "$status" -eq 1 ]
    hdmi_on_amdgpu
    run hdmi_frl_applies
    assert_success
    assert_output_contains "native HDMI on amdgpu: card0-HDMI-A-1"
    [ "$(component_status hdmi_frl)" = stock ]
    rm -rf "$SOF_ROOT/sys/class/drm/card0-HDMI-A-1"
    [ "$(component_status hdmi_frl)" = n/a ]
}

@test "superseded: Valve 7.2.10-valve1 and later, mainline 7.4, or a live default with the FRL bit; not 7.2.7 or 7.3.1" {
    hdmi_frl_kernel_default_on 7.2.10-valve1-3-neptune-72-g1b214a39f3cb
    hdmi_frl_kernel_default_on 7.2.10-valve2-1-neptune-72-gabcdef123456
    hdmi_frl_kernel_default_on 7.2.12-valve1-1-neptune-72-gabcdef123456
    hdmi_frl_kernel_default_on 7.4.0-valve1-1-neptune-74-gabcdef123456
    ! hdmi_frl_kernel_default_on "$KV" || false
    ! hdmi_frl_kernel_default_on 7.2.9-valve9-1-neptune-72-gabcdef123456 || false
    ! hdmi_frl_kernel_default_on 7.3.1-valve1-1-neptune-73-g205189b410aa || false
    ! hdmi_frl_kernel_default_on garbage || false
    run hdmi_frl_probe
    [ "$status" -eq 1 ]
    SOF_KVER=7.2.10-valve1-3-neptune-72-g1b214a39f3cb run hdmi_frl_probe
    [ "$status" -eq 0 ]
    # live default: the module runs with 0x400 set and nothing on the command line
    fixture_file /proc/cmdline "BOOT_IMAGE=/boot/vmlinuz quiet splash
"
    fixture_file /sys/module/amdgpu/parameters/dcfeaturemask "1026
"
    run hdmi_frl_probe
    [ "$status" -eq 0 ]
    fixture_file /sys/module/amdgpu/parameters/dcfeaturemask "2
"
    run hdmi_frl_probe
    [ "$status" -eq 1 ]
    # with our argument on the command line the live value proves nothing
    booted_with_arg
    fixture_file /sys/module/amdgpu/parameters/dcfeaturemask "1026
"
    run hdmi_frl_probe
    [ "$status" -eq 1 ]
}

@test "apply with a staged patched amdgpu: drop-in written and recorded, stock grub.cfg saved, regeneration noted" {
    hdmi_on_amdgpu
    staged_build "$KV"
    run component_apply hdmi_frl
    assert_success
    [ -f "$SOF_ROOT$DROPIN" ]
    grep -q "GRUB_CMDLINE_LINUX_DEFAULT=\"\${GRUB_CMDLINE_LINUX_DEFAULT} $ARG\"" "$SOF_ROOT$DROPIN"
    manifest_has "$DROPIN"
    [ "$(cat "$STATE/hdmi-frl.mode")" = frl ]
    grub_backup_valid A
    cmp -s "$SOF_ROOT/var/lib/steamos-fixes/backup/grub/A/grub.cfg" "$SOF_ROOT/efi/EFI/steamos/grub.cfg"
    [ "$(grub_regenerate_pending)" = A ]
    # before the reboot: degraded, "reboot to enable"
    [ "$(component_status hdmi_frl)" = degraded ]
    run hdmi_frl_status_detail
    assert_output_contains "regeneration pending"
    grub_regenerate_clear
    run hdmi_frl_status_detail
    assert_output_contains "reboot to enable FRL"
    # after the reboot with the patched module loaded: active
    booted_with_arg
    fixture_file /sys/module/amdgpu/srcversion "ABC123
"
    printf 'ABC123\n' >"$SOF_ROOT/etc/steamos-fixes/modules/$KV/amdgpu.ko.zst.srcversion"
    [ "$(component_status hdmi_frl)" = active ]
    run hdmi_frl_status_detail
    assert_output_contains "FRL on with the patched amdgpu"
    # apply again: nothing changes
    before=$(tree_digest "$SOF_ROOT")
    component_apply hdmi_frl
    [ "$(tree_digest "$SOF_ROOT")" = "$before" ]
}

@test "degraded: FRL on the command line but the stock amdgpu loaded (no VRR)" {
    hdmi_on_amdgpu
    staged_build "$KV"
    component_apply hdmi_frl
    booted_with_arg
    fixture_file /sys/module/amdgpu/srcversion "STOCK
"
    printf 'ABC123\n' >"$SOF_ROOT/etc/steamos-fixes/modules/$KV/amdgpu.ko.zst.srcversion"
    [ "$(component_status hdmi_frl)" = degraded ]
    run hdmi_frl_status_detail
    assert_output_contains "stock amdgpu is loaded (no VRR on this link)"
}

@test "degrade: a kernel without a patched amdgpu gets no FRL argument (stock TMDS with VRR); a build brings it back" {
    hdmi_on_amdgpu
    staged_build "$KV"
    component_apply hdmi_frl
    [ -f "$SOF_ROOT$DROPIN" ]
    # SteamOS update to a kernel we have no build for
    export SOF_KVER="$KV_NEW"
    run component_apply hdmi_frl
    assert_success
    assert_output_contains "no patched amdgpu for $KV_NEW; removing the FRL argument"
    [ ! -e "$SOF_ROOT$DROPIN" ]
    ! manifest_has "$DROPIN" || false
    [ "$(component_status hdmi_frl)" = degraded ]
    run hdmi_frl_status_detail
    assert_output_contains "no patched amdgpu for $KV_NEW yet: running stock TMDS with VRR"
    # the rebuild lands
    staged_build "$KV_NEW"
    component_apply hdmi_frl
    [ -f "$SOF_ROOT$DROPIN" ]
    # lockdown withholds it too
    fixture_file /sys/kernel/security/lockdown "none [integrity] confidentiality"
    component_apply hdmi_frl
    [ ! -e "$SOF_ROOT$DROPIN" ]
    run hdmi_frl_status_detail
    assert_output_contains "lockdown"
}

@test "--without-vrr keeps the argument without a patched module; tmds removes it and reports stock by choice" {
    hdmi_on_amdgpu
    hdmi_frl_set_mode frl --without-vrr
    component_apply hdmi_frl
    [ -f "$SOF_ROOT$DROPIN" ]
    booted_with_arg
    [ "$(component_status hdmi_frl)" = active ]
    run hdmi_frl_status_detail
    assert_output_contains "VRR not required"
    hdmi_frl_set_mode tmds
    [ ! -e "$STATE/hdmi-frl.allow-no-vrr" ]
    GRUB_CHANGED=0
    component_apply hdmi_frl
    [ ! -e "$SOF_ROOT$DROPIN" ]
    [ "$(component_status hdmi_frl)" = stock ]
    run hdmi_frl_status_detail
    assert_output_contains "TMDS by choice"
}

@test "superseded kernel: the drop-in is removed and the status says why" {
    hdmi_on_amdgpu
    staged_build "$KV"
    component_apply hdmi_frl
    [ -f "$SOF_ROOT$DROPIN" ]
    export SOF_KVER=7.2.10-valve1-3-neptune-72-g1b214a39f3cb
    staged_build "$SOF_KVER" superseded
    run component_apply hdmi_frl
    assert_success
    assert_output_contains "enables FRL by default; removing our kernel argument"
    [ ! -e "$SOF_ROOT$DROPIN" ]
    [ "$(component_status hdmi_frl)" = superseded ]
    run hdmi_frl_status_detail
    assert_output_contains "enables HDMI FRL by default"
}

@test "remove: drop-in and state gone, regeneration noted" {
    hdmi_on_amdgpu
    staged_build "$KV"
    component_apply hdmi_frl
    grub_regenerate_clear
    run hdmi_frl_remove
    assert_success
    [ ! -e "$SOF_ROOT$DROPIN" ]
    [ ! -e "$STATE/hdmi-frl.mode" ]
    [ "$(grub_regenerate_pending)" = A ]
}

@test "apply --slot (RAUC post-install) decides from the slot's kernel and defers grub to the handler" {
    hdmi_on_amdgpu
    staged_build "$KV"
    fake_src self-update rebuild
    "$FAKE_CLI" --root "$SOF_ROOT" apply --only hdmi_frl >/dev/null 2>&1
    [ -f "$SOF_ROOT$DROPIN" ]
    slot="$BATS_TEST_TMPDIR/slotB"
    mkdir -p "$slot/usr/lib/modules/$KV_NEW" "$slot/etc/default/grub.d" "$slot/var/lib/steamos-fixes" "$slot/efi/EFI/steamos"
    cp "$SOF_ROOT/var/lib/steamos-fixes/manifest" "$slot/var/lib/steamos-fixes/"
    cp "$SOF_ROOT$DROPIN" "$slot$DROPIN"
    cp "$SOF_ROOT/efi/EFI/steamos/grub.cfg" "$slot/efi/EFI/steamos/grub.cfg"
    # the new slot's kernel has no build: the drop-in is removed there
    run env SOF_SLOT=B SOF_KVER="$KV_NEW" "$FAKE_CLI" --root "$SOF_ROOT" apply --slot "$slot" --only hdmi_frl
    assert_success
    [ ! -e "$slot$DROPIN" ]
    [ "$(SOF_ROOT=$slot grub_regenerate_pending)" = B ]
    # with a build for it the drop-in stays
    SOF_ROOT=$slot staged_build "$KV_NEW"
    run env SOF_SLOT=B SOF_KVER="$KV_NEW" "$FAKE_CLI" --root "$SOF_ROOT" apply --slot "$slot" --only hdmi_frl
    assert_success
    [ -f "$slot$DROPIN" ]
}

@test "hdmi-frl command: status report, frl/tmds switches, refuses on hardware without native HDMI" {
    fake_src self-update rebuild
    run "$FAKE_CLI" --root "$SOF_ROOT" hdmi-frl frl
    assert_failure
    assert_output_contains "nothing to do on this machine"
    hdmi_on_amdgpu
    staged_build "$KV"
    run "$FAKE_CLI" --root "$SOF_ROOT" hdmi-frl frl
    assert_success
    assert_output_contains "frl configured"
    assert_output_contains "Reboot to apply"
    [ -f "$SOF_ROOT$DROPIN" ]
    booted_with_arg
    fixture_file /sys/module/amdgpu/taint "OE
"
    fixture_file /sys/kernel/debug/dri/0/HDMI-A-1/vrr_range "Min: 40
Max: 144
"
    fixture_file /sys/kernel/debug/dri/0/crtc-0/amdgpu_current_bpc "Current: 10
"
    run "$FAKE_CLI" --root "$SOF_ROOT" hdmi-frl status
    assert_success
    assert_output_contains "configured:            frl"
    assert_output_contains "FRL argument on the kernel command line"
    assert_output_contains "card0-HDMI-A-1"
    assert_output_contains "preferred mode:      3840x2160"
    assert_output_contains "vrr_range:           Min: 40 Max: 144"
    assert_output_contains "current bpc:         crtc-0: Current: 10"
    assert_output_contains "amdgpu taint:          OE"
    run "$FAKE_CLI" --root "$SOF_ROOT" hdmi-frl tmds
    assert_success
    [ ! -e "$SOF_ROOT$DROPIN" ]
    run "$FAKE_CLI" --root "$SOF_ROOT" hdmi-frl tmds --without-vrr
    assert_failure 2
    run "$FAKE_CLI" --root "$SOF_ROOT" hdmi-frl bogus
    assert_failure 2
}
