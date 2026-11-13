#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# lib/slots.sh: slot detection and the boot-entry exception (plan §4, §5.2 rules 3a/9).
load '../test_helper'
load '../update_helper'

ENTRY=/efi/EFI/steamos/grub.cfg
INITRD=/efi/EFI/steamos/steamos-fixes-modules.img

setup() {
    make_root >/dev/null
    source_libs
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/slots.sh"
    unset SOF_SLOT SOF_BOOT_ENTRY
    fixture_partsets A
    fixture_grub
    fixture_initrd
    cp "$SOF_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "active slot comes from /dev/disk/by-partsets self vs A/B" {
    [ "$(slots_active)" = A ]
    fixture_partsets B
    [ "$(slots_active)" = B ]
    [ "$(slots_inactive)" = A ]
}

@test "SOF_SLOT overrides detection; invalid names are rejected" {
    SOF_SLOT=B
    [ "$(slots_active)" = B ]
    SOF_SLOT=dev
    run slots_active
    assert_failure
}

@test "active slot is unknown without partsets" {
    rm -rf "$SOF_ROOT/dev"
    run slots_active
    assert_failure
}

@test "slots_other flips A and B and refuses anything else" {
    [ "$(slots_other A)" = B ]
    [ "$(slots_other B)" = A ]
    run slots_other dev
    assert_failure
}

@test "entry path: stage-2 grub.cfg on the slot's efi partition" {
    [ "$(slots_entry_path A)" = "$ENTRY" ]
    [ "$(slots_entry_format "$ENTRY")" = grub ]
}

@test "apply appends kernel args, inserts the early initrd first, saves the original" {
    slots_entry_apply A "demo_arg=1 foo=bar" "$INITRD"
    f="$SOF_ROOT$ENTRY"
    grep -q 'linux /boot/vmlinuz-linux-neptune .* amd_iommu=off demo_arg=1 foo=bar$' "$f"
    grep -q 'initrd	${cmdpath}/steamos-fixes-modules.img /boot/amd-ucode.img /boot/initramfs-linux-neptune.img$' "$f"
    b="$SOF_ROOT/var/lib/steamos-fixes/backup/A/grub.cfg"
    cmp "$b" "$BATS_TEST_TMPDIR/pristine"
    [ "$(cat "$b.sha256")" = "$(sof_sha256 "$BATS_TEST_TMPDIR/pristine")" ]
    [ "$(cat "$SOF_ROOT/var/lib/steamos-fixes/backup/A/entry-path")" = "$ENTRY" ]
    slots_entry_is_modified "$f"
}

@test "apply is idempotent (twice = same bytes, one change)" {
    slots_entry_apply A "demo_arg=1" "$INITRD"
    first=$(sof_sha256 "$SOF_ROOT$ENTRY")
    slots_entry_apply A "demo_arg=1" "$INITRD"
    [ "$(sof_sha256 "$SOF_ROOT$ENTRY")" = "$first" ]
    [ "$(grep -c 'demo_arg=1' "$SOF_ROOT$ENTRY")" = 2 ] # marker line + kernel line
}

@test "changing the args replaces the earlier change instead of stacking" {
    slots_entry_apply A "one=1" "$INITRD"
    slots_entry_apply A "two=2" "$INITRD"
    ! grep -q 'one=1' "$SOF_ROOT$ENTRY"
    grep -q 'amd_iommu=off two=2$' "$SOF_ROOT$ENTRY"
    [ "$(grep -o 'steamos-fixes-modules.img' "$SOF_ROOT$ENTRY" | wc -l | tr -d ' ')" = 2 ]
    slots_entry_restore A
    cmp "$SOF_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "apply refuses a missing initrd and leaves the entry untouched" {
    rm -f "$SOF_ROOT$INITRD"
    run slots_entry_apply A "x=1" "$INITRD"
    assert_failure
    cmp "$SOF_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "apply refuses an initrd that is not an uncompressed newc cpio" {
    printf '\x28\xb5\x2f\xfdzstd' >"$SOF_ROOT$INITRD"
    run slots_entry_apply A "x=1" "$INITRD"
    assert_failure
    assert_output_contains "newc cpio"
    cmp "$SOF_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "apply refuses an initrd outside the slot's efi directory for grub" {
    fixture_initrd /var/lib/steamos-fixes/modules.img
    run slots_entry_apply A "x=1" /var/lib/steamos-fixes/modules.img
    assert_failure
    cmp "$SOF_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "apply refuses an entry without a kernel line" {
    printf 'set timeout=0\n' >"$SOF_ROOT$ENTRY"
    cp "$SOF_ROOT$ENTRY" "$BATS_TEST_TMPDIR/odd"
    run slots_entry_apply A "x=1" ""
    assert_failure
    cmp "$SOF_ROOT$ENTRY" "$BATS_TEST_TMPDIR/odd"
}

@test "args-only change (no initrd) round-trips" {
    slots_entry_apply A "x=1" ""
    grep -q 'amd_iommu=off x=1$' "$SOF_ROOT$ENTRY"
    ! grep -q 'cmdpath' "$SOF_ROOT$ENTRY"
    slots_entry_restore A
    cmp "$SOF_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "restore puts the saved original back byte-for-byte" {
    slots_entry_apply A "demo_arg=1" "$INITRD"
    slots_entry_restore A
    cmp "$SOF_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
    ! slots_entry_is_modified "$SOF_ROOT$ENTRY"
    # idempotent
    slots_entry_restore A
    cmp "$SOF_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "restore without a backup regenerates the original from the template" {
    slots_entry_apply A "demo_arg=1" "$INITRD"
    rm -rf "$SOF_ROOT/var/lib/steamos-fixes/backup"
    run slots_entry_restore A
    assert_success
    assert_output_contains "regenerating"
    cmp "$SOF_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "restore with a corrupted backup (hash mismatch) regenerates instead" {
    slots_entry_apply A "demo_arg=1" "$INITRD"
    printf 'garbage\n' >"$SOF_ROOT/var/lib/steamos-fixes/backup/A/grub.cfg"
    slots_entry_restore A
    cmp "$SOF_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "entry without a final newline round-trips byte-for-byte" {
    printf '%s' "$(cat "$SOF_ROOT$ENTRY")" >"$SOF_ROOT$ENTRY"
    cp "$SOF_ROOT$ENTRY" "$BATS_TEST_TMPDIR/noeol"
    slots_entry_apply A "demo_arg=1" "$INITRD"
    rm -rf "$SOF_ROOT/var/lib/steamos-fixes/backup"
    slots_entry_restore A
    cmp "$SOF_ROOT$ENTRY" "$BATS_TEST_TMPDIR/noeol"
}

@test "a stock regeneration of the entry refreshes the backup" {
    slots_entry_apply A "demo_arg=1" "$INITRD"
    # steamos-finalize-install rewrote grub.cfg (our change is gone).
    fixture_grub
    printf '# new stock line\n' >>"$SOF_ROOT$ENTRY"
    cp "$SOF_ROOT$ENTRY" "$BATS_TEST_TMPDIR/newstock"
    slots_entry_apply A "demo_arg=1" "$INITRD"
    cmp "$SOF_ROOT/var/lib/steamos-fixes/backup/A/grub.cfg" "$BATS_TEST_TMPDIR/newstock"
    slots_entry_restore A
    cmp "$SOF_ROOT$ENTRY" "$BATS_TEST_TMPDIR/newstock"
}

@test "dry-run writes nothing" {
    before=$(tree_digest "$SOF_ROOT")
    SOF_DRY_RUN=1
    slots_entry_apply A "demo_arg=1" "$INITRD" 2>/dev/null
    slots_desired_set "demo_arg=1" "$INITRD" 2>/dev/null
    SOF_DRY_RUN=0
    [ "$(tree_digest "$SOF_ROOT")" = "$before" ]
}

@test "BLS entries: options get the args, early initrd goes first" {
    rm -f "$SOF_ROOT$ENTRY"
    fixture_bls /esp/loader/entries/steamos-A.conf
    fixture_initrd /esp/steamos-fixes/modules.img
    cp "$SOF_ROOT/esp/loader/entries/steamos-A.conf" "$BATS_TEST_TMPDIR/bls"
    [ "$(slots_entry_path A)" = /esp/loader/entries/steamos-A.conf ]
    slots_entry_apply A "demo_arg=1" /esp/steamos-fixes/modules.img
    f="$SOF_ROOT/esp/loader/entries/steamos-A.conf"
    [ "$(grep '^initrd' "$f" | head -n1)" = "initrd /steamos-fixes/modules.img" ]
    grep -q '^options root=PARTUUID=1234 quiet splash demo_arg=1$' "$f"
    slots_entry_restore A
    cmp "$f" "$BATS_TEST_TMPDIR/bls"
}

@test "reconcile follows the desired state, and restores once it is cleared" {
    slots_desired_set "demo_arg=1" "$INITRD"
    ! slots_entry_in_sync A
    slots_entry_reconcile A
    slots_entry_in_sync A
    slots_desired_clear
    ! slots_entry_in_sync A
    slots_entry_reconcile A
    slots_entry_in_sync A
    cmp "$SOF_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "reconcile is a no-op where there is no boot entry (not SteamOS)" {
    rm -rf "$SOF_ROOT/efi"
    slots_desired_set "demo_arg=1" "$INITRD"
    run slots_entry_reconcile A
    assert_success
}

@test "boot-entry CLI: set, show, clear" {
    run "$CLI" --root "$SOF_ROOT" boot-entry set --arg demo_arg=1 --initrd "$INITRD"
    assert_success
    run "$CLI" --root "$SOF_ROOT" boot-entry show
    assert_success
    assert_output_contains "in sync"
    assert_output_contains "demo_arg=1"
    run "$CLI" --root "$SOF_ROOT" boot-entry clear
    assert_success
    cmp "$SOF_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "an initrd placed last (module override) is appended after the stock initramfs and strips back" {
    fixture_partsets A
    fixture_grub
    slots_entry_apply A "demo_arg=1" "$INITRD" last
    f="$SOF_ROOT$ENTRY"
    grep -q 'initrd	/boot/amd-ucode.img /boot/initramfs-linux-neptune.img ${cmdpath}/steamos-fixes-modules.img$' "$f"
    grep -q '^# steamos-fixes-initrd-pos: last$' "$f"
    slots_desired_set "demo_arg=1" "$INITRD" last
    slots_entry_in_sync A
    slots_desired_set "demo_arg=1" "$INITRD" first
    ! slots_entry_in_sync A || false
    slots_entry_reconcile A
    grep -q 'initrd	${cmdpath}/steamos-fixes-modules.img /boot/amd-ucode.img' "$f"
    slots_entry_restore A
    cmp -s "$f" "$SOF_ROOT/var/lib/steamos-fixes/backup/A/grub.cfg"
    run "$CLI" --root "$SOF_ROOT" boot-entry set --arg demo_arg=1 --initrd "$INITRD" --last
    assert_success
    grep -q 'initramfs-linux-neptune.img ${cmdpath}/steamos-fixes-modules.img$' "$f"
    run "$CLI" --root "$SOF_ROOT" boot-entry show
    assert_output_contains "(last)"
}

@test "BLS entries: an initrd placed last follows the stock initrd lines" {
    fixture_partsets A
    rm -f "$SOF_ROOT$ENTRY"
    fixture_bls /esp/loader/entries/steamos-A.conf
    fixture_initrd /esp/steamos-fixes/modules.img
    slots_entry_apply A "demo_arg=1" /esp/steamos-fixes/modules.img last
    f="$SOF_ROOT/esp/loader/entries/steamos-A.conf"
    [ "$(grep -n '^initrd' "$f" | tail -n1 | cut -d: -f2-)" = "initrd /steamos-fixes/modules.img" ]
    [ "$(grep -c '^initrd' "$f")" = 2 ]
    slots_entry_restore A
    cmp -s "$f" "$SOF_ROOT/var/lib/steamos-fixes/backup/A/steamos-A.conf"
}
