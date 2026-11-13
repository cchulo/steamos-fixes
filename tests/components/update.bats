#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# components/update.sh: the SteamOS keep list (docs/update-survival.md).
# The rest of the component is covered by tests/cmd/apply.bats and
# tests/lib/rauc.bats.
load '../test_helper'
load '../update_helper'

KEEP=/etc/atomic-update.conf.d/steamos-fixes.conf

setup() {
    make_root >/dev/null
    source_libs
    unset SOF_SLOT SOF_KVER
    export SOF_KVER=7.2.7-valve2-test
    component_load update
}

@test "the keep-list globs cover our naming conventions and become anchored regexes" {
    run update_keep_patterns
    assert_success
    assert_output_contains "/etc/steamos-fixes/**"
    assert_output_contains "/etc/modprobe.d/steamos-fixes-*.conf"
    assert_output_contains "/etc/default/grub.d/steamos-fixes-*.cfg"
    [ "$(_update_keep_regex '/etc/default/grub.d/steamos-fixes-*.cfg')" = '^/etc/default/grub\.d/steamos-fixes-[^/]*\.cfg$' ]
    [ "$(_update_keep_regex '/etc/steamos-fixes/**')" = '^/etc/steamos-fixes/.*$' ]
}

@test "manifest paths outside the globs are listed explicitly; /etc/rauc and systemd units are not" {
    printf 'x\n' >"$BATS_TEST_TMPDIR/f"
    manifest_install_file "$BATS_TEST_TMPDIR/f" /etc/modprobe.d/steamos-fixes-modules.conf modules
    manifest_install_file "$BATS_TEST_TMPDIR/f" /etc/steamos-fixes/modules/k/a.ko.zst modules
    manifest_install_file "$BATS_TEST_TMPDIR/f" /etc/systemd/system/steamos-fixes.service update
    manifest_install_symlink ../steamos-fixes.service /etc/systemd/system/multi-user.target.wants/steamos-fixes.service update
    manifest_install_file "$BATS_TEST_TMPDIR/f" /etc/rauc/steamos-fixes-note update
    manifest_install_file "$BATS_TEST_TMPDIR/f" /etc/odd.d/steamos-fixes-odd.conf demo
    manifest_install_file "$BATS_TEST_TMPDIR/f" /var/lib/steamos-fixes/x demo
    run update_keep_uncovered
    assert_success
    [ "$output" = /etc/odd.d/steamos-fixes-odd.conf ]
    run update_render_keep_list
    assert_success
    assert_output_contains "/etc/odd.d/steamos-fixes-odd.conf"
    [[ "$output" != *"/etc/rauc"* ]]
    [[ "$output" != *"multi-user.target.wants"* ]]
}

@test "apply installs the keep list, status goes stock when it is stale and detail says so" {
    fixture_partsets A
    fixture_grub
    fixture_rauc_conf
    component_apply update
    [ -f "$SOF_ROOT$KEEP" ]
    manifest_has "$KEEP"
    grep -qx '/etc/default/grub.d/steamos-fixes-\*.cfg' "$SOF_ROOT$KEEP"
    [ "$(component_status update)" = active ]
    printf 'x\n' >"$BATS_TEST_TMPDIR/f"
    manifest_install_file "$BATS_TEST_TMPDIR/f" /etc/odd.d/steamos-fixes-odd.conf demo
    [ "$(component_status update)" = stock ]
    run update_status_detail
    assert_output_contains "keep list is out of date"
    component_apply update
    grep -qx '/etc/odd.d/steamos-fixes-odd.conf' "$SOF_ROOT$KEEP"
    [ "$(component_status update)" = active ]
    [ "$(manifest_paths update | grep -c "$KEEP")" = 1 ]
}
