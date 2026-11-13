#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
load '../test_helper'

KV=7.2.7-valve2-2-neptune-72-g31504582a073

setup() {
    make_root >/dev/null
    source_libs
    export SOF_KVER="$KV"
    export SOF_PATCHES_DIR="$BATS_TEST_TMPDIR/patches"
    mkdir -p "$SOF_PATCHES_DIR"
    printf '0001-a.patch\tsound/soc/amd/acp\tsnd-soc-acpi-amd-match.ko\n' >"$SOF_PATCHES_DIR/modules.list"
    printf '0010-h.patch\tdrivers/hid\thid-asus-ally.ko\n' >"$SOF_PATCHES_DIR/modules-hid.list"
}

# stock_modules : fixture stock modules for the two listed names (contents
# do not matter: superseded is decided by BUILD-INFO, not by strings).
stock_modules() {
    fixture_file "/usr/lib/modules/$KV/kernel/sound/soc/amd/acp/snd-soc-acpi-amd-match.ko" "${1:-stock}"
    fixture_file "/usr/lib/modules/$KV/kernel/drivers/hid/hid-asus-ally.ko" "${2:-stock}"
}

# patch_files : the two listed patches, so builds can record their hashes.
patch_files() {
    printf 'asoc patch v1\n' >"$SOF_PATCHES_DIR/0001-a.patch"
    printf 'hid patch v1\n' >"$SOF_PATCHES_DIR/0010-h.patch"
}

# build_info_patches [dir] : patch.<name>=<sha256> lines for the current patches.
build_info_patches() {
    local p
    for p in 0001-a.patch 0010-h.patch; do
        printf 'patch.%s=%s\n' "$p" "$(sof_sha256 "$SOF_PATCHES_DIR/$p")"
    done
}

stage_build() {
    local d="$BATS_TEST_TMPDIR/build"
    mkdir -p "$d"
    patch_files
    { printf 'kver=%s\n' "$KV"; build_info_patches; } >"$d/BUILD-INFO"
    printf 'a' >"$d/snd-soc-acpi-amd-match.ko.zst"
    printf 'h' >"$d/hid-asus-ally.ko.zst"
    modules_stage "$KV" "$d"
}

@test "component loads and lists the helper in the state dir, nothing under /usr" {
    component_load modules
    run component_files modules
    assert_success
    [ "$output" = "$(printf 'bin/load-or-fallback\t/etc/steamos-fixes/load-or-fallback\t0755\tshared')" ]
}

@test "apply installs the helper and a modprobe.d drop-in generated from the lists" {
    run component_apply modules
    assert_success
    [ -x "$SOF_ROOT/etc/steamos-fixes/load-or-fallback" ]
    conf="$SOF_ROOT/etc/modprobe.d/steamos-fixes-modules.conf"
    [ -f "$conf" ]
    grep -Fxq 'install hid-asus-ally /bin/sh -c '"'"'/etc/steamos-fixes/load-or-fallback hid-asus-ally "$@" || exec modprobe --ignore-install hid-asus-ally "$@"'"'"' -- $CMDLINE_OPTS' "$conf"
    grep -Fxq 'install snd-soc-acpi-amd-match /bin/sh -c '"'"'/etc/steamos-fixes/load-or-fallback snd-soc-acpi-amd-match "$@" || exec modprobe --ignore-install snd-soc-acpi-amd-match "$@"'"'"' -- $CMDLINE_OPTS' "$conf"
    [ -d "$SOF_ROOT/etc/steamos-fixes/modules" ]
    manifest_has /etc/modprobe.d/steamos-fixes-modules.conf
    manifest_has /etc/steamos-fixes/load-or-fallback
    [ -z "$(find "$SOF_ROOT/usr" -newer "$SOF_ROOT/etc" 2>/dev/null)" ]
}

@test "apply is idempotent" {
    component_apply modules
    run component_apply modules
    assert_success
    [ "$(manifest_paths modules | sort | uniq -d)" = "" ]
}

@test "probe: 2 when the stock modules dir for the kernel is absent" {
    component_load modules
    run modules_probe
    [ "$status" -eq 2 ]
}

@test "probe: 2 when stock modules exist but nothing is staged yet" {
    component_load modules
    stock_modules
    run modules_probe
    [ "$status" -eq 2 ]
}

@test "probe: 1 when a staged build still ships a patched module" {
    component_load modules
    stock_modules
    stage_build
    run modules_probe
    [ "$status" -eq 1 ]
}

@test "the modprobe.d drop-in gets an asus-armoury hook from modules-power.list" {
    printf '0020-p.patch\tdrivers/platform/x86\tasus-armoury.ko\n' >"$SOF_PATCHES_DIR/modules-power.list"
    run component_apply modules
    assert_success
    conf="$SOF_ROOT/etc/modprobe.d/steamos-fixes-modules.conf"
    grep -Fxq 'install asus-armoury /bin/sh -c '"'"'/etc/steamos-fixes/load-or-fallback asus-armoury "$@" || exec modprobe --ignore-install asus-armoury "$@"'"'"' -- $CMDLINE_OPTS' "$conf"
    [ "$(grep -c '^install asus-armoury ' "$conf")" -eq 1 ]
}

@test "status: stock when the drop-in predates a module added to the lists" {
    stock_modules
    component_apply modules
    stage_build
    run component_status modules
    [ "$output" = active ]
    printf '0020-p.patch\tdrivers/platform/x86\tasus-armoury.ko\n' >"$SOF_PATCHES_DIR/modules-power.list"
    printf 'power patch v1\n' >"$SOF_PATCHES_DIR/0020-p.patch"
    printf 'p' >"$SOF_ROOT/etc/steamos-fixes/modules/$KV/asus-armoury.ko.zst"
    printf 'patch.0020-p.patch=%s\n' "$(sof_sha256 "$SOF_PATCHES_DIR/0020-p.patch")" >>"$SOF_ROOT/etc/steamos-fixes/modules/$KV/BUILD-INFO"
    run component_status modules
    [ "$output" = stock ]
    run modules_status_detail
    assert_output_contains "out of date"
    component_apply modules
    run component_status modules
    [ "$output" = active ]
}

@test "probe: 0 only when the staged build marks every module superseded" {
    component_load modules
    stock_modules
    d="$BATS_TEST_TMPDIR/sup"
    mkdir -p "$d"
    patch_files
    { printf 'kver=%s
module.snd-soc-acpi-amd-match=superseded
' "$KV"; build_info_patches; } >"$d/BUILD-INFO"
    printf 'h' >"$d/hid-asus-ally.ko.zst"
    modules_stage "$KV" "$d"
    run modules_probe
    [ "$status" -eq 1 ]
    printf 'module.hid-asus-ally=superseded
' >>"$SOF_ROOT/etc/steamos-fixes/modules/$KV/BUILD-INFO"
    rm -f "$SOF_ROOT/etc/steamos-fixes/modules/$KV/hid-asus-ally.ko.zst"
    run modules_probe
    [ "$status" -eq 0 ]
}

@test "status: n/a when nothing installed and nothing to inspect" {
    run component_status modules
    [ "$output" = n/a ]
}

@test "status: stock (pending rebuild) when hooks are in place but no build for this kernel" {
    stock_modules
    component_apply modules
    run component_status modules
    [ "$output" = stock ]
    run modules_status_detail
    assert_output_contains "pending rebuild"
    assert_output_contains "$KV"
}

@test "status: active when hooks are in place and modules for SOF_KVER are staged" {
    stock_modules
    component_apply modules
    stage_build
    run component_status modules
    [ "$output" = active ]
    # a different running kernel has no build yet
    SOF_KVER=7.2.10-valve1-1-neptune-72-g1b214a39f3cb run component_status modules
    [ "$output" = stock ]
}

@test "status: stock with an explanation when kernel lockdown is active" {
    stock_modules
    component_apply modules
    stage_build
    fixture_file /sys/kernel/security/lockdown "none [integrity] confidentiality"
    run component_status modules
    [ "$output" = stock ]
    run modules_status_detail
    assert_output_contains "lockdown"
}

@test "status: stock when the drop-in was modified" {
    stock_modules
    component_apply modules
    stage_build
    printf '# edited\n' >>"$SOF_ROOT/etc/modprobe.d/steamos-fixes-modules.conf"
    run component_status modules
    [ "$output" = stock ]
}

@test "status: superseded when our build found every patch already upstream" {
    stock_modules
    component_apply modules
    d="$BATS_TEST_TMPDIR/build"
    mkdir -p "$d"
    patch_files
    { printf 'kver=%s\nmodule.snd-soc-acpi-amd-match=superseded\nmodule.hid-asus-ally=superseded\n' "$KV"; build_info_patches; } >"$d/BUILD-INFO"
    modules_stage "$KV" "$d"
    run component_status modules
    [ "$output" = superseded ]
}

@test "rebuild command: prints the source used and BUILD-INFO" {
    a="$SOF_ROOT/var/lib/steamos-fixes/cache/artifacts"
    mkdir -p "$a" "$BATS_TEST_TMPDIR/art/$KV"
    patch_files
    { printf 'kver=%s\nheader_source=2\n' "$KV"; build_info_patches; } >"$BATS_TEST_TMPDIR/art/$KV/BUILD-INFO"
    printf 'a' >"$BATS_TEST_TMPDIR/art/$KV/snd-soc-acpi-amd-match.ko.zst"
    printf 'h' >"$BATS_TEST_TMPDIR/art/$KV/hid-asus-ally.ko.zst"
    tar -C "$BATS_TEST_TMPDIR/art" -cf - "$KV" | zstd -q -o "$a/modules-$KV.tar.zst"
    printf '%s  x\n' "$(sof_sha256 "$a/modules-$KV.tar.zst")" >"$a/modules-$KV.tar.zst.sha256"
    run env SOF_OFFLINE=1 "$CLI" --root "$SOF_ROOT" rebuild --source cache
    assert_success
    assert_output_contains "modules for $KV: cache"
    assert_output_contains "header_source=2"
}

@test "rebuild command: failure is reported, unknown source rejected" {
    run env SOF_OFFLINE=1 "$CLI" --root "$SOF_ROOT" rebuild
    assert_failure
    assert_output_contains "stock modules stay in use"
    run "$CLI" --root "$SOF_ROOT" rebuild --source floppy
    assert_failure 2
}

@test "a staged build from another version of a patch is not available; status explains; rebuild re-stages" {
    component_apply modules
    stage_build
    modules_available "$KV"
    # the checkout's hid patch changes (a new release)
    printf 'hid patch v2\n' >"$SOF_PATCHES_DIR/0010-h.patch"
    run modules_available "$KV"
    assert_failure
    run modules_staged_stale "$KV"
    assert_success
    assert_output_contains '0010-h.patch: built from a different version of the patch'
    run modules_status
    assert_output_contains 'stock'
    run modules_status_detail
    assert_output_contains 'staged modules for'
    assert_output_contains 'are from another release (0010-h.patch: built from a different version of the patch)'
    # the cache holds no artifact: staging a matching build makes it current again
    stage_build
    run modules_available "$KV"
    assert_success
}

@test "a build whose BUILD-INFO lacks the patch hashes is refused by modules_stage" {
    component_load modules
    patch_files
    d="$BATS_TEST_TMPDIR/old"
    mkdir -p "$d"
    printf 'kver=%s\n' "$KV" >"$d/BUILD-INFO"
    printf 'a' >"$d/snd-soc-acpi-amd-match.ko.zst"
    printf 'h' >"$d/hid-asus-ally.ko.zst"
    run modules_stage "$KV" "$d"
    assert_failure
    assert_output_contains "does not match this checkout's patches (0001-a.patch: not in the build)"
    [ ! -d "$SOF_ROOT/etc/steamos-fixes/modules/$KV" ]
}

@test "release download tries the checkout version first, then latest" {
    component_load modules
    printf '0.1.7\n' >"$BATS_TEST_TMPDIR/VERSION"
    SOF_SRC="$BATS_TEST_TMPDIR" run _modules_release_urls
    assert_success
    [ "${lines[0]}" = "https://github.com/cchulo/steamos-fixes/releases/download/v0.1.7" ]
    [ "${lines[1]}" = "https://github.com/cchulo/steamos-fixes/releases/latest/download" ]
}
