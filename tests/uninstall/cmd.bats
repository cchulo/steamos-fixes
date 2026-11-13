#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# The CLI wrappers: uninstall (with --superseded and component hooks) and audit.
load '../test_helper'

setup() {
    make_root >/dev/null
    source_libs
    # Private component tree + overlay (same pattern as tests/lib/component.bats).
    export SOF_SRC="$BATS_TEST_TMPDIR/src"
    export SOF_COMPONENTS_DIR="$SOF_SRC/components"
    mkdir -p "$SOF_COMPONENTS_DIR" "$SOF_SRC/overlay/demo" "$SOF_SRC/cmd"
    ln -s "$REPO_ROOT/lib" "$SOF_SRC/lib"
    ln -s "$REPO_ROOT/uninstall" "$SOF_SRC/uninstall"
    ln -s "$REPO_ROOT/steamos-fixes.sh" "$SOF_SRC/steamos-fixes.sh"
    cp "$REPO_ROOT/cmd/uninstall.sh" "$REPO_ROOT/cmd/audit.sh" "$REPO_ROOT/cmd/help.sh" "$SOF_SRC/cmd/"
    cp "$REPO_ROOT/VERSION" "$SOF_SRC/"
    printf 'one\n' >"$SOF_SRC/overlay/demo/one.conf"
    printf 'two\n' >"$SOF_SRC/overlay/demo/two.conf"
    cat >"$SOF_COMPONENTS_DIR/alpha.sh" <<'C'
COMPONENT_DESCRIPTION="alpha"
alpha_files() { printf 'demo/one.conf\t/etc/modprobe.d/steamos-fixes-alpha.conf\t0644\n'; }
alpha_probe() { [ -e "$(sof_path /usr/share/alpha-native)" ] && return 0; return 1; }
alpha_remove() { touch "$(sof_path /var/lib/steamos-fixes/alpha-remove-hook-ran)"; }
C
    cat >"$SOF_COMPONENTS_DIR/beta.sh" <<'C'
COMPONENT_DESCRIPTION="beta"
beta_files() { printf 'demo/two.conf\t/etc/environment.d/90-steamos-fixes-beta.conf\t0644\n'; }
beta_probe() { return 1; }
C
    CLI="$SOF_SRC/steamos-fixes.sh"
    component_apply alpha
    component_apply beta
}

@test "uninstall --superseded removes only superseded components and runs their remove hook" {
    fixture_file /usr/share/alpha-native
    run "$CLI" --root "$SOF_ROOT" uninstall --superseded
    assert_success
    assert_output_contains "alpha: superseded"
    [ ! -e "$SOF_ROOT/etc/modprobe.d/steamos-fixes-alpha.conf" ]
    [ -f "$SOF_ROOT/etc/environment.d/90-steamos-fixes-beta.conf" ]
    [ -e "$SOF_ROOT/var/lib/steamos-fixes/alpha-remove-hook-ran" ]
    [ -d "$SOF_ROOT/var/lib/steamos-fixes" ] # partial removal keeps the state dir
}

@test "uninstall --superseded with nothing superseded is a no-op" {
    run "$CLI" --root "$SOF_ROOT" uninstall --superseded
    assert_success
    assert_output_contains "nothing to do"
    [ -f "$SOF_ROOT/etc/modprobe.d/steamos-fixes-alpha.conf" ]
}

@test "full uninstall via CLI removes everything and the state dir" {
    run "$CLI" --root "$SOF_ROOT" uninstall
    assert_success
    [ ! -e "$SOF_ROOT/etc/modprobe.d/steamos-fixes-alpha.conf" ]
    [ ! -e "$SOF_ROOT/etc/environment.d/90-steamos-fixes-beta.conf" ]
    [ ! -d "$SOF_ROOT/var/lib/steamos-fixes" ]
}

@test "uninstall --dry-run via CLI changes nothing" {
    run "$CLI" --root "$SOF_ROOT" --dry-run uninstall
    assert_success
    assert_output_contains "[dry-run]"
    [ -f "$SOF_ROOT/etc/modprobe.d/steamos-fixes-alpha.conf" ]
}

@test "uninstall refuses when read-only root was disabled unless --i-know" {
    touch "$SOF_ROOT/.sof-readonly-disabled"
    run "$CLI" --root "$SOF_ROOT" uninstall
    assert_failure
    run "$CLI" --root "$SOF_ROOT" --i-know uninstall
    assert_success
}

@test "uninstall --component unknown is rejected" {
    run "$CLI" --root "$SOF_ROOT" uninstall --component nope
    assert_failure 2
}

@test "audit is clean after apply" {
    run "$CLI" --root "$SOF_ROOT" audit
    assert_success
    assert_output_contains "audit clean"
}

@test "audit reports modified, missing and unexpected files, exit 1" {
    printf 'tampered' >"$SOF_ROOT/etc/modprobe.d/steamos-fixes-alpha.conf"
    rm "$SOF_ROOT/etc/environment.d/90-steamos-fixes-beta.conf"
    fixture_file /etc/default/grub.d/steamos-fixes-stray.cfg "stray"
    fixture_file /home/deck/.config/pipewire/pipewire.conf.d/50-steamos-fixes-stray.conf "stray"
    run "$CLI" --root "$SOF_ROOT" audit
    assert_failure 1
    assert_output_contains "modified   /etc/modprobe.d/steamos-fixes-alpha.conf"
    assert_output_contains "missing    /etc/environment.d/90-steamos-fixes-beta.conf"
    assert_output_contains "unexpected /etc/default/grub.d/steamos-fixes-stray.cfg"
    assert_output_contains "unexpected /home/deck/.config/pipewire/pipewire.conf.d/50-steamos-fixes-stray.conf"
}

@test "audit --json emits valid JSON" {
    rm "$SOF_ROOT/etc/environment.d/90-steamos-fixes-beta.conf"
    run "$CLI" --root "$SOF_ROOT" audit --json
    assert_failure 1
    printf '%s' "$output" | jq -e 'map(select(.state == "missing")) | length == 1' >/dev/null
}
