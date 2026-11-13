#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
load '../test_helper'

KV=7.2.7-valve2-2-neptune-72-g31504582a073

setup() {
    make_root >/dev/null
    source_libs
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/modules.sh"
    export SOF_PATCHES_DIR="$BATS_TEST_TMPDIR/patches"
    mkdir -p "$SOF_PATCHES_DIR"
    printf '0001-a.patch\tsound/soc/amd/acp\tsnd-soc-acpi-amd-match.ko\n' >"$SOF_PATCHES_DIR/modules.list"
    printf '0010-h.patch\tdrivers/hid\thid-asus-ally.ko\n0011-h.patch\tdrivers/hid\thid-asus-ally.ko\n' >"$SOF_PATCHES_DIR/modules-hid.list"
    for p in 0001-a 0010-h 0011-h; do printf '%s v1\n' "$p" >"$SOF_PATCHES_DIR/$p.patch"; done
    export SOF_OFFLINE=0
}

# build_info_patches : patch.<name>=<sha256> for the listed patches, as
# build/build-modules.sh records them (builds without them are refused).
build_info_patches() {
    local p
    for p in 0001-a.patch 0010-h.patch 0011-h.patch; do
        printf 'patch.%s=%s\n' "$p" "$(sof_sha256 "$SOF_PATCHES_DIR/$p")"
    done
}

# make_build <dir> <kver> [module...] : a fake build output directory.
make_build() {
    local d=$1 k=$2 m
    shift 2
    mkdir -p "$d"
    { printf 'format=1\nkver=%s\nvermagic=%s SMP\n' "$k" "$k"; build_info_patches; } >"$d/BUILD-INFO"
    [ $# -gt 0 ] || set -- hid-asus-ally snd-soc-acpi-amd-match
    for m in "$@"; do
        printf 'ko %s %s' "$m" "$k" >"$d/$m.ko.zst"
    done
}

# make_artifact <kver> <dest.tar.zst> : release-style tarball + .sha256
make_artifact() {
    local s="$BATS_TEST_TMPDIR/art"
    rm -rf "$s"
    make_build "$s/$1" "$1"
    tar -C "$s" -cf - "$1" | zstd -q -o "$2"
    printf '%s  %s\n' "$(sof_sha256 "$2")" "$(basename "$2")" >"$2.sha256"
}

@test "modules_list_names reads every modules*.list, de-duplicated" {
    [ "$(modules_list_names | tr '\n' ' ')" = "hid-asus-ally snd-soc-acpi-amd-match " ]
}

@test "modules_dir_for is under the state dir and unprefixed" {
    [ "$(modules_dir_for "$KV")" = "/etc/steamos-fixes/modules/$KV" ]
}

@test "modules_stage copies atomically and records everything in the manifest" {
    make_build "$BATS_TEST_TMPDIR/b" "$KV"
    run modules_stage "$KV" "$BATS_TEST_TMPDIR/b"
    assert_success
    d="$SOF_ROOT/etc/steamos-fixes/modules/$KV"
    [ -f "$d/hid-asus-ally.ko.zst" ]
    [ -f "$d/snd-soc-acpi-amd-match.ko.zst" ]
    [ -f "$d/BUILD-INFO" ]
    modules_available "$KV"
    manifest_has "/etc/steamos-fixes/modules/$KV/hid-asus-ally.ko.zst"
    manifest_has "/etc/steamos-fixes/modules/$KV/BUILD-INFO"
    manifest_has "/etc/steamos-fixes/modules/$KV"
    [ "$(manifest_entry_get "$(manifest_entry "/etc/steamos-fixes/modules/$KV/BUILD-INFO")" component)" = modules ]
    manifest_verify "/etc/steamos-fixes/modules/$KV/hid-asus-ally.ko.zst"
    # no leftovers from the staging dance
    [ -z "$(find "$SOF_ROOT/etc/steamos-fixes/modules" -maxdepth 1 -name '.*' ! -name . )" ]
}

@test "modules_stage replaces an older build and drops stale manifest entries" {
    make_build "$BATS_TEST_TMPDIR/b1" "$KV" hid-asus-ally snd-soc-acpi-amd-match old-module
    modules_stage "$KV" "$BATS_TEST_TMPDIR/b1"
    manifest_has "/etc/steamos-fixes/modules/$KV/old-module.ko.zst"
    make_build "$BATS_TEST_TMPDIR/b2" "$KV"
    printf 'new' >"$BATS_TEST_TMPDIR/b2/hid-asus-ally.ko.zst"
    modules_stage "$KV" "$BATS_TEST_TMPDIR/b2"
    [ "$(cat "$SOF_ROOT/etc/steamos-fixes/modules/$KV/hid-asus-ally.ko.zst")" = new ]
    [ ! -e "$SOF_ROOT/etc/steamos-fixes/modules/$KV/old-module.ko.zst" ]
    ! manifest_has "/etc/steamos-fixes/modules/$KV/old-module.ko.zst"
    manifest_verify "/etc/steamos-fixes/modules/$KV/hid-asus-ally.ko.zst"
}

@test "modules_stage refuses incomplete or mismatched builds" {
    make_build "$BATS_TEST_TMPDIR/b" "$KV" hid-asus-ally
    run modules_stage "$KV" "$BATS_TEST_TMPDIR/b"
    assert_failure
    assert_output_contains "lacks snd-soc-acpi-amd-match.ko.zst"
    make_build "$BATS_TEST_TMPDIR/c" 7.2.7-valve2-1-neptune-72
    run modules_stage "$KV" "$BATS_TEST_TMPDIR/c"
    assert_failure
    [ ! -d "$SOF_ROOT/etc/steamos-fixes/modules/$KV" ]
}

@test "a module recorded as superseded in BUILD-INFO counts as available" {
    make_build "$BATS_TEST_TMPDIR/b" "$KV" hid-asus-ally
    printf 'module.snd-soc-acpi-amd-match=superseded\n' >>"$BATS_TEST_TMPDIR/b/BUILD-INFO"
    modules_stage "$KV" "$BATS_TEST_TMPDIR/b"
    modules_available "$KV"
    [ "$(modules_superseded_names "$KV")" = snd-soc-acpi-amd-match ]
    ! modules_all_superseded "$KV"
}

@test "modules_stage in dry-run writes nothing" {
    make_build "$BATS_TEST_TMPDIR/b" "$KV"
    SOF_DRY_RUN=1 run modules_stage "$KV" "$BATS_TEST_TMPDIR/b"
    assert_success
    [ ! -d "$SOF_ROOT/etc/steamos-fixes/modules/$KV" ]
}

@test "resolve: cache hit when already staged, nothing else is tried" {
    make_build "$BATS_TEST_TMPDIR/b" "$KV"
    modules_stage "$KV" "$BATS_TEST_TMPDIR/b"
    _modules_fetch() { echo "fetch called" >&2; return 1; }
    modules_container_build() { echo "build called" >&2; return 1; }
    run modules_resolve "$KV"
    assert_success
    [ "${lines[${#lines[@]} - 1]}" = cache ]
    [[ "$output" != *called* ]]
}

@test "resolve: cached release artifact is verified and staged" {
    a="$SOF_ROOT/var/lib/steamos-fixes/cache/artifacts"
    mkdir -p "$a"
    make_artifact "$KV" "$a/modules-$KV.tar.zst"
    run modules_resolve "$KV" --source cache
    assert_success
    [ "${lines[${#lines[@]} - 1]}" = cache ]
    modules_available "$KV"
}

@test "resolve: release download when the cache is empty; bad checksum rejected" {
    srv="$BATS_TEST_TMPDIR/srv"
    mkdir -p "$srv"
    make_artifact "$KV" "$srv/modules-$KV.tar.zst"
    modules_online() { return 0; }
    _modules_fetch() { cp "$srv/${1##*/}" "$2"; }
    modules_container_build() { echo "build called" >&2; return 1; }
    run modules_resolve "$KV"
    assert_success
    [ "${lines[${#lines[@]} - 1]}" = release ]
    modules_available "$KV"
    [ -f "$SOF_ROOT/var/lib/steamos-fixes/cache/artifacts/modules-$KV.tar.zst" ]
    # second kernel with a corrupted checksum file falls through to container
    K2=7.2.10-valve1-1-neptune-72-g1b214a39f3cb
    make_artifact "$K2" "$srv/modules-$K2.tar.zst"
    printf '0000  x\n' >"$srv/modules-$K2.tar.zst.sha256"
    run modules_resolve "$K2"
    assert_failure
    assert_output_contains "fails its checksum"
    ! modules_available "$K2"
}

@test "resolve: release tarball with entries outside <kver>/ is rejected" {
    srv="$BATS_TEST_TMPDIR/srv"
    mkdir -p "$srv/x/$KV" "$srv/x/evil"
    make_build "$srv/x/$KV" "$KV"
    printf 'x' >"$srv/x/evil/f"
    tar -C "$srv/x" -cf - "$KV" evil | zstd -q -o "$srv/modules-$KV.tar.zst"
    printf '%s  f\n' "$(sof_sha256 "$srv/modules-$KV.tar.zst")" >"$srv/modules-$KV.tar.zst.sha256"
    modules_online() { return 0; }
    _modules_fetch() { cp "$srv/${1##*/}" "$2"; }
    run modules_resolve "$KV" --source release
    assert_failure
    assert_output_contains "unexpected entry"
}

@test "resolve: offline skips release and container, failure is reported not fatal" {
    modules_online() { return 1; }
    _modules_fetch() { echo "fetch called" >&2; return 1; }
    run modules_resolve "$KV"
    assert_failure 1
    assert_output_contains "stock modules will be used"
    [[ "$output" != *"fetch called"* ]]
}

@test "resolve: container build is used last and its output staged" {
    modules_online() { return 0; }
    _modules_fetch() { return 1; }
    sof_have() { [ "$1" = podman ] && return 0; command -v "$1" >/dev/null 2>&1; }
    modules_container_build() {
        printf '%s %s\n' "$1" "$2" >"$BATS_TEST_TMPDIR/build-args"
        make_build "$3/$1" "$1"
    }
    run modules_resolve "$KV" --channel jupiter-rel
    assert_success
    [ "${lines[${#lines[@]} - 1]}" = container ]
    [ "$(cat "$BATS_TEST_TMPDIR/build-args")" = "$KV jupiter-rel" ]
    modules_available "$KV"
}

@test "resolve: no podman means no container attempt" {
    modules_online() { return 0; }
    _modules_fetch() { return 1; }
    sof_have() { [ "$1" = podman ] && return 1; command -v "$1" >/dev/null 2>&1; }
    run modules_resolve "$KV" --source container
    assert_failure
    assert_output_contains "podman not available"
}

@test "resolve rejects an unknown source" {
    run modules_resolve "$KV" --source floppy
    assert_failure 2
}

@test "lockdown detection reads the selected mode from fixture sysfs" {
    run modules_lockdown_active
    assert_failure
    fixture_file /sys/kernel/security/lockdown "[none] integrity confidentiality"
    run modules_lockdown_active
    assert_failure
    fixture_file /sys/kernel/security/lockdown "none [integrity] confidentiality"
    run modules_lockdown_active
    assert_success
    fixture_file /sys/kernel/security/lockdown "none integrity [confidentiality]"
    run modules_lockdown_active
    assert_success
}

@test "modules_detect_channel honours SOF_CHANNEL and maps branch + release to a repo" {
    SOF_CHANNEL=jupiter-staging run modules_detect_channel
    [ "$output" = jupiter-staging ]
    unset SOF_CHANNEL
    run modules_detect_channel
    [ "$output" = jupiter-main ]
    # a stable device: its per-release repo carries the stable kernel
    fixture_file /etc/os-release 'ID=steamos
VERSION_ID="3.9.5"
BUILD_ID=20261021.1
'
    run modules_detect_channel
    [ "$output" = jupiter-3.9 ]
    fixture_file /etc/steamos-atomupd/preferences.conf '[Choices]
Variant=steamdeck
Branch=rel
'
    run modules_detect_channel
    [ "$output" = jupiter-3.9 ]
    fixture_file /etc/steamos-atomupd/preferences.conf '[Choices]
Branch=staging
'
    run modules_detect_channel
    [ "$output" = jupiter-staging ]
    fixture_file /etc/steamos-atomupd/preferences.conf '[Choices]
Branch=main
'
    run modules_detect_channel
    [ "$output" = jupiter-main ]
    rm -f "$SOF_ROOT/etc/steamos-atomupd/preferences.conf"
    fixture_file /var/lib/steamos-branch "rel"
    run modules_detect_channel
    [ "$output" = jupiter-3.9 ]
}

@test "generated install line still loads the stock module when the helper is missing (early boot)" {
    # Simulate udev running the modprobe.d install command before /etc/steamos-fixes
    # exists: the helper path is absent, so the inner shell must exec the stock load.
    export SOF_COMPONENTS_DIR="$REPO_ROOT/components"
    conf=$(modules_render_modprobe_conf)
    line=$(printf '%s\n' "$conf" | grep '^install hid-asus-ally ')
    cmd=${line#install hid-asus-ally }
    cmd=${cmd//\$CMDLINE_OPTS/opt=1}
    cmd=${cmd//\/etc\/steamos-fixes\/load-or-fallback/$BATS_TEST_TMPDIR/missing-helper}
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/modprobe" <<'M'
#!/bin/sh
printf '%s\n' "$*" >"$MODPROBE_LOG"
M
    chmod +x "$BATS_TEST_TMPDIR/bin/modprobe"
    MODPROBE_LOG="$BATS_TEST_TMPDIR/modprobe.log" PATH="$BATS_TEST_TMPDIR/bin:$PATH" sh -c "$cmd"
    [ "$(cat "$BATS_TEST_TMPDIR/modprobe.log")" = "--ignore-install hid-asus-ally opt=1" ]
}

# --- modules in the initramfs: detection and the early initrd override ----

# fixture_initramfs [member...] : a zstd-compressed newc cpio at
# /boot/initramfs-linux-neptune.img holding the given member paths.
fixture_initramfs() {
    local tree="$BATS_TEST_TMPDIR/initramfs-tree" m fmt
    rm -rf "$tree"
    mkdir -p "$tree/usr/lib/modules/$KV/kernel/drivers/hid" "$tree/etc/modprobe.d"
    printf 'stock\n' >"$tree/etc/modprobe.d/stock.conf"
    for m in "$@"; do
        mkdir -p "$tree/$(dirname "$m")"
        printf 'stock %s\n' "$m" >"$tree/$m"
    done
    if cpio --version 2>/dev/null | grep -qi gnu; then fmt="-H newc"; else fmt="--format newc"; fi
    mkdir -p "$SOF_ROOT/boot"
    # shellcheck disable=SC2086
    (cd "$tree" && find . -type f | sort | cpio -o $fmt --quiet 2>/dev/null) | zstd -q -o "$SOF_ROOT/boot/initramfs-linux-neptune.img" -f
}

@test "modules_initramfs_list reads a zstd newc initramfs; modules_in_initramfs finds a module by either name spelling" {
    command -v cpio >/dev/null 2>&1 || skip "cpio not installed"
    fixture_initramfs "usr/lib/modules/$KV/kernel/drivers/hid/hid-asus-ally.ko.zst"
    run modules_initramfs_list "$SOF_ROOT/boot/initramfs-linux-neptune.img"
    assert_success
    assert_output_contains "etc/modprobe.d/stock.conf"
    run modules_in_initramfs hid_asus_ally
    assert_success
    [ "$output" = "usr/lib/modules/$KV/kernel/drivers/hid/hid-asus-ally.ko.zst" ]
    run modules_in_initramfs snd-soc-acpi-amd-match
    [ "$status" -eq 1 ]
    [ "$(modules_load_path hid-asus-ally)" = early-initrd ]
    [ "$(modules_load_path snd-soc-acpi-amd-match)" = modprobe-hook ]
    rm -f "$SOF_ROOT/boot/initramfs-linux-neptune.img"
    run modules_in_initramfs hid-asus-ally
    [ "$status" -eq 2 ]
    [ "$(modules_load_path hid-asus-ally)" = modprobe-hook ]
}

@test "override render packs only initramfs-loaded staged modules, at the initramfs path, as an uncompressed newc cpio" {
    command -v cpio >/dev/null 2>&1 || skip "cpio not installed"
    fixture_initramfs "usr/lib/modules/$KV/kernel/drivers/hid/hid-asus-ally.ko.zst"
    make_build "$BATS_TEST_TMPDIR/b" "$KV"
    printf 'patched hid\n' | zstd -q -o "$BATS_TEST_TMPDIR/b/hid-asus-ally.ko.zst" -f
    modules_stage "$KV" "$BATS_TEST_TMPDIR/b"
    run modules_override_render "$KV" "$BATS_TEST_TMPDIR/override.img"
    assert_success
    [ "$(head -c 6 "$BATS_TEST_TMPDIR/override.img")" = 070701 ]
    run modules_initramfs_list "$BATS_TEST_TMPDIR/override.img"
    assert_success
    [ "$output" = "usr/lib/modules/$KV/kernel/drivers/hid/hid-asus-ally.ko.zst" ]
    # nothing in the initramfs -> nothing to pack
    fixture_initramfs
    run modules_override_render "$KV" "$BATS_TEST_TMPDIR/override2.img"
    [ "$status" -eq 1 ]
}

@test "override sync installs the image and the boot entry token, and drops both when no build matches" {
    command -v cpio >/dev/null 2>&1 || skip "cpio not installed"
    load '../update_helper'
    fixture_partsets A
    fixture_grub
    export SOF_SLOT=A
    fixture_initramfs "usr/lib/modules/$KV/kernel/drivers/hid/hid-asus-ally.ko.zst"
    make_build "$BATS_TEST_TMPDIR/b" "$KV"
    printf 'patched hid\n' | zstd -q -o "$BATS_TEST_TMPDIR/b/hid-asus-ally.ko.zst" -f
    modules_stage "$KV" "$BATS_TEST_TMPDIR/b"
    run modules_override_sync "$KV"
    assert_success
    [ -s "$SOF_ROOT/efi/EFI/steamos/steamos-fixes-modules.img" ]
    manifest_has /efi/EFI/steamos/steamos-fixes-modules.img
    grep -q 'initrd	/boot/amd-ucode.img /boot/initramfs-linux-neptune.img ${cmdpath}/steamos-fixes-modules.img$' "$SOF_ROOT/efi/EFI/steamos/grub.cfg"
    [ "$(slots_desired_get initrd)" = /efi/EFI/steamos/steamos-fixes-modules.img ]
    # a new kernel without a build: the entry must not reference the image
    run modules_override_sync 7.9.0-valve1-1-neptune-79-gabcdefabcdef
    assert_success
    [ ! -e "$SOF_ROOT/efi/EFI/steamos/steamos-fixes-modules.img" ]
    ! manifest_has /efi/EFI/steamos/steamos-fixes-modules.img || false
    ! grep -q 'steamos-fixes-modules.img' "$SOF_ROOT/efi/EFI/steamos/grub.cfg" || false
    cmp -s "$SOF_ROOT/efi/EFI/steamos/grub.cfg" "$SOF_ROOT/var/lib/steamos-fixes/backup/A/grub.cfg"
}
