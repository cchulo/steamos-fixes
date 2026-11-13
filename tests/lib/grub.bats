#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# lib/grub.sh: /etc/default/grub.d drop-ins, grub.cfg argument checks,
# the stock-original backup and the regeneration bookkeeping.
load '../test_helper'
load '../update_helper'

setup() {
    make_root >/dev/null
    source_libs
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/grub.sh"
    unset SOF_SLOT SOF_BOOT_ENTRY SOF_APPLY_SLOT
    export SOF_SLOT=A
    fixture_partsets A
    fixture_grub
    STATE="$SOF_ROOT/var/lib/steamos-fixes/state"
}

@test "a drop-in is rendered, recorded in the manifest, idempotent, and removable" {
    run grub_render_dropin hdmi-frl amdgpu.dcfeaturemask=0x402
    assert_success
    assert_output_contains 'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} amdgpu.dcfeaturemask=0x402"'
    GRUB_CHANGED=0
    grub_dropin_install hdmi_frl hdmi-frl amdgpu.dcfeaturemask=0x402
    [ "$GRUB_CHANGED" = 1 ]
    f="$SOF_ROOT/etc/default/grub.d/steamos-fixes-hdmi-frl.cfg"
    [ -f "$f" ]
    manifest_has /etc/default/grub.d/steamos-fixes-hdmi-frl.cfg
    grub_dropin_present hdmi-frl
    GRUB_CHANGED=0
    grub_dropin_install hdmi_frl hdmi-frl amdgpu.dcfeaturemask=0x402
    [ "$GRUB_CHANGED" = 0 ]
    [ "$(manifest_paths hdmi_frl | grep -c "steamos-fixes-hdmi-frl.cfg")" = 1 ]
    grub_dropin_install hdmi_frl hdmi-frl amdgpu.dcfeaturemask=0x400
    [ "$GRUB_CHANGED" = 1 ]
    grep -q '0x400' "$f"
    GRUB_CHANGED=0
    grub_dropin_remove hdmi-frl
    [ "$GRUB_CHANGED" = 1 ]
    [ ! -e "$f" ]
    ! manifest_has /etc/default/grub.d/steamos-fixes-hdmi-frl.cfg || false
    ! grub_dropin_present hdmi-frl || false
    GRUB_CHANGED=0
    grub_dropin_remove hdmi-frl
    [ "$GRUB_CHANGED" = 0 ]
}

@test "grub_cfg_has_arg looks at kernel lines only, whole words; grub_cmdline_has_arg at /proc/cmdline" {
    run grub_cfg_has_arg amd_iommu=off
    assert_success
    run grub_cfg_has_arg amd_iommu=of
    [ "$status" -eq 1 ]
    run grub_cfg_has_arg amdgpu.dcfeaturemask=0x402
    [ "$status" -eq 1 ]
    printf '# amdgpu.dcfeaturemask=0x402 in a comment\n' >>"$SOF_ROOT/efi/EFI/steamos/grub.cfg"
    run grub_cfg_has_arg amdgpu.dcfeaturemask=0x402
    [ "$status" -eq 1 ]
    rm -f "$SOF_ROOT/efi/EFI/steamos/grub.cfg"
    run grub_cfg_has_arg amd_iommu=off
    [ "$status" -eq 2 ]
    run grub_cmdline_has_arg amdgpu.dcfeaturemask=0x402
    [ "$status" -eq 2 ]
    fixture_file /proc/cmdline "BOOT_IMAGE=/boot/vmlinuz quiet amdgpu.dcfeaturemask=0x402 splash"
    run grub_cmdline_has_arg amdgpu.dcfeaturemask=0x402
    assert_success
    run grub_cmdline_has_arg amdgpu.dcfeaturemask=0x40
    [ "$status" -eq 1 ]
}

@test "the stock grub.cfg is saved once, refreshed when stock changes, never saved when it carries our argument" {
    grub_backup_save A amdgpu.dcfeaturemask=0x402
    b="$SOF_ROOT/var/lib/steamos-fixes/backup/grub/A/grub.cfg"
    [ -f "$b" ] && [ -f "$b.sha256" ]
    grub_backup_valid A
    cmp -s "$b" "$SOF_ROOT/efi/EFI/steamos/grub.cfg"
    # a regenerated file with our argument is not the original
    sed -i.bak 's/amd_iommu=off$/amd_iommu=off amdgpu.dcfeaturemask=0x402/' "$SOF_ROOT/efi/EFI/steamos/grub.cfg"
    grub_backup_save A amdgpu.dcfeaturemask=0x402
    ! grep -q dcfeaturemask "$b" || false
    # stock changed (SteamOS update): the backup follows
    fixture_grub
    printf '# new stock line\n' >>"$SOF_ROOT/efi/EFI/steamos/grub.cfg"
    grub_backup_save A amdgpu.dcfeaturemask=0x402
    grep -q 'new stock line' "$b"
    grub_backup_valid A
    printf 'x' >>"$b"
    ! grub_backup_valid A || false
}

@test "regeneration is noted on a fixture or mounted slot, and cleared; the pending check is per slot" {
    ! grub_regenerate_pending || false
    run grub_regenerate A
    assert_success
    assert_output_contains "noted"
    [ "$(grub_regenerate_pending)" = A ]
    grep -q '^slot=A$' "$STATE/grub-regenerate-needed"
    SOF_APPLY_SLOT=1 run grub_regenerate B
    assert_success
    [ "$(grub_regenerate_pending)" = B ]
    # booted A, pending for B: left alone
    run grub_regenerate_if_pending
    assert_success
    [ "$(grub_regenerate_pending)" = B ]
    run grub_regenerate_slot B
    assert_success
    assert_output_contains "[fixture] holo-chroot --partset B -- update-grub"
    grub_regenerate_clear
    ! grub_regenerate_pending || false
    run grub_regenerate_slot C
    [ "$status" -eq 2 ]
    SOF_DRY_RUN=1 run grub_regenerate A
    assert_success
    assert_output_contains "[dry-run] update-grub"
    ! grub_regenerate_pending || false
}

@test "grub_restore_report compares the regenerated file with the saved original" {
    grub_backup_save A amdgpu.dcfeaturemask=0x402
    run grub_restore_report A
    assert_output_contains "byte-identical"
    printf '# changed\n' >>"$SOF_ROOT/efi/EFI/steamos/grub.cfg"
    run grub_restore_report A
    assert_output_contains "differs from the copy saved on install"
}
