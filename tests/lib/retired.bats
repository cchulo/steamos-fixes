#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# lib/retired.sh: removing the files of components this version no longer
# ships, on apply, boot and uninstall. No component is retired today, so
# the tests declare a fake one ("oldfix") through SOF_RETIRED_COMPONENTS.
load '../test_helper'
load '../update_helper'

CONF=/etc/steamos-fixes/oldfix/steamos-fixes-oldfix.conf
UNIT=/etc/systemd/system/steamos-fixes-oldfix.service
LINK=/etc/systemd/system/multi-user.target.wants/steamos-fixes-oldfix.service
HOMEF=/home/deck/.config/steamos-fixes/oldfix.conf

setup() {
    make_root >/dev/null
    export SOF_RETIRED_COMPONENTS=oldfix
    source_libs
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/retired.sh"
    unset SOF_SLOT SOF_KVER
    export SOF_KVER=7.2.7-valve2-test
    mkdir -p "$SOF_ROOT/home/deck/.config"
}

# old_install : what the last version with oldfix left behind, recorded
# under component oldfix exactly as it recorded it.
old_install() {
    local src="$BATS_TEST_TMPDIR/src.d" p
    mkdir -p "$src"
    for p in "$CONF" "$UNIT" "$HOMEF"; do
        printf 'old oldfix file %s\n' "$p" >"$src/f"
        manifest_install_file "$src/f" "$p" oldfix 0644
    done
    manifest_install_symlink ../steamos-fixes-oldfix.service "$LINK" oldfix
}

assert_gone() {
    local p
    for p in "$CONF" "$UNIT" "$LINK" "$HOMEF"; do
        [ ! -e "$SOF_ROOT$p" ] && [ ! -L "$SOF_ROOT$p" ]
    done
    [ -z "$(manifest_paths oldfix)" ]
    [ ! -d "$SOF_ROOT/etc/steamos-fixes/oldfix" ]
    [ -d "$SOF_ROOT/home/deck/.config" ]
}

@test "nothing is retired by default; the list comes from SOF_RETIRED_COMPONENTS" {
    retired_is oldfix
    ! retired_is modules || false
    ! component_exists oldfix || false
}

@test "retired_prune_all removes every recorded file, symlink and empty dir" {
    old_install
    [ -n "$(manifest_paths oldfix)" ]
    run retired_prune_all
    assert_success
    assert_output_contains "oldfix: removing $CONF (component removed from steamos-fixes)"
    assert_output_contains "oldfix: removed (no longer part of steamos-fixes)"
    assert_gone
}

@test "retired_prune_all with nothing recorded does nothing" {
    run retired_prune_all
    assert_success
    [ -z "$output" ]
}

@test "a modified file is kept, reported and stays in the manifest; the rest goes" {
    old_install
    printf 'hand edit\n' >>"$SOF_ROOT$CONF"
    run retired_prune_all
    assert_failure 1
    assert_output_contains "$CONF was modified after install; leaving it in place"
    [ -f "$SOF_ROOT$CONF" ]
    manifest_has "$CONF"
    [ ! -e "$SOF_ROOT$UNIT" ]
    # its directory is not empty, so it stays
    [ -d "$SOF_ROOT/etc/steamos-fixes/oldfix" ]
}

@test "a recorded path without the steamos-fixes marker is never removed" {
    old_install
    fixture_file /etc/stock.conf "stock"
    manifest_record /etc/stock.conf oldfix file "$(sof_sha256 "$SOF_ROOT/etc/stock.conf")" shared false
    run retired_prune_all
    assert_failure 1
    assert_output_contains "not removing /etc/stock.conf: no steamos-fixes marker"
    [ -f "$SOF_ROOT/etc/stock.conf" ]
}

@test "files already gone are forgotten; other components' entries are untouched" {
    old_install
    rm -f "$SOF_ROOT$UNIT"
    fixture_file /etc/modprobe.d/steamos-fixes-modules.conf "x"
    manifest_record /etc/modprobe.d/steamos-fixes-modules.conf modules file \
        "$(sof_sha256 "$SOF_ROOT/etc/modprobe.d/steamos-fixes-modules.conf")" shared false
    run retired_prune_all
    assert_success
    ! manifest_has "$UNIT" || false
    manifest_has /etc/modprobe.d/steamos-fixes-modules.conf
    [ -f "$SOF_ROOT/etc/modprobe.d/steamos-fixes-modules.conf" ]
}

@test "a directory is kept when something else lives in it" {
    old_install
    fixture_file /etc/steamos-fixes/oldfix/notes.txt "mine"
    run retired_prune_all
    assert_success
    [ -f "$SOF_ROOT/etc/steamos-fixes/oldfix/notes.txt" ]
    [ ! -e "$SOF_ROOT$CONF" ]
}

# --- through the CLI ------------------------------------------------------

@test "apply removes a retired component's files and writes status.json without it" {
    old_install
    export SOF_COMPONENTS_DIR="$BATS_TEST_TMPDIR/components"
    mkdir -p "$SOF_COMPONENTS_DIR"
    fake_src self-update rebuild
    run "$FAKE_CLI" --root "$SOF_ROOT" apply
    assert_success
    assert_output_contains "oldfix: removed"
    assert_gone
    s="$SOF_ROOT/var/lib/steamos-fixes/state/status.json"
    jq -e . "$s" >/dev/null
    [ "$(jq -r '[.components[].name] | index("oldfix")' "$s")" = null ]
    run "$FAKE_CLI" --root "$SOF_ROOT" apply
    assert_success
    [[ "$output" != *"oldfix"* ]]
}

@test "the boot service run (apply --missing-only) removes them too" {
    old_install
    export SOF_COMPONENTS_DIR="$BATS_TEST_TMPDIR/components"
    mkdir -p "$SOF_COMPONENTS_DIR"
    fake_src self-update rebuild
    run "$FAKE_CLI" --root "$SOF_ROOT" apply --missing-only
    assert_success
    assert_gone
}

@test "apply --only <retired> removes it instead of failing as unknown" {
    old_install
    export SOF_COMPONENTS_DIR="$BATS_TEST_TMPDIR/components"
    mkdir -p "$SOF_COMPONENTS_DIR"
    fake_src self-update rebuild
    run "$FAKE_CLI" --root "$SOF_ROOT" apply --only oldfix
    assert_success
    assert_output_contains "oldfix is no longer part of steamos-fixes"
    assert_gone
    run "$FAKE_CLI" --root "$SOF_ROOT" apply --only nonesuch
    assert_failure 2
}

@test "apply --slot leaves a retired component alone" {
    old_install
    export SOF_COMPONENTS_DIR="$BATS_TEST_TMPDIR/components"
    mkdir -p "$SOF_COMPONENTS_DIR"
    fake_src self-update rebuild
    slot="$BATS_TEST_TMPDIR/slotB"
    mkdir -p "$slot/usr/lib/modules/7.3.0-valve1-neptune" "$slot/etc" "$slot/var/lib/steamos-fixes"
    cp "$SOF_ROOT/var/lib/steamos-fixes/manifest" "$slot/var/lib/steamos-fixes/manifest"
    run env SOF_SLOT=B "$FAKE_CLI" --root "$SOF_ROOT" apply --slot "$slot"
    assert_success
    [[ "$output" != *"oldfix"* ]]
    [ -n "$(SOF_ROOT=$slot manifest_paths oldfix)" ]
}

@test "full uninstall from an old install removes the retired files" {
    old_install
    export SOF_COMPONENTS_DIR="$BATS_TEST_TMPDIR/components"
    mkdir -p "$SOF_COMPONENTS_DIR"
    fake_src self-update rebuild
    run "$FAKE_CLI" --root "$SOF_ROOT" uninstall --keep-state
    assert_success
    assert_gone
}

@test "uninstall --component <retired> is accepted and removes even a modified file with --force" {
    old_install
    printf 'hand edit\n' >>"$SOF_ROOT$CONF"
    export SOF_COMPONENTS_DIR="$BATS_TEST_TMPDIR/components"
    mkdir -p "$SOF_COMPONENTS_DIR"
    fake_src self-update rebuild
    run "$FAKE_CLI" --root "$SOF_ROOT" uninstall --component oldfix --keep-state
    assert_failure 1
    [ -f "$SOF_ROOT$CONF" ]
    run "$FAKE_CLI" --root "$SOF_ROOT" uninstall --component oldfix --keep-state --force
    assert_success
    assert_gone
}
