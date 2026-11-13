#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# vm/guest/*: pure logic only.
# Syntax and style of the scripts are covered by `make lint` (shellcheck/shfmt).
load '../test_helper'

ES="$REPO_ROOT/vm/guest/measure-etc-survival.sh"

# make_tree <dir> : a small stock-like /etc.
make_tree() {
    mkdir -p "$1/etc/modprobe.d" "$1/etc/udev/rules.d" "$1/etc/systemd/system" "$1/etc/keep"
    printf 'a\n' >"$1/etc/stock"
    printf 'b\n' >"$1/etc/gone"
    printf 'c\n' >"$1/etc/mod"
    printf 'k\n' >"$1/etc/keep/file"
    ln -s stock "$1/etc/link"
}

@test "snapshot records type and digest; compare classifies two fixture trees" {
    a="$BATS_TEST_TMPDIR/a"
    b="$BATS_TEST_TMPDIR/b"
    make_tree "$a"
    make_tree "$b"
    rm "$b/etc/gone"
    printf 'changed\n' >"$b/etc/mod"
    printf 'new\n' >"$b/etc/added"
    rm "$b/etc/link"
    ln -s mod "$b/etc/link"
    "$ES" snapshot "$a/etc" /etc >"$BATS_TEST_TMPDIR/a.tsv"
    "$ES" snapshot "$b/etc" /etc >"$BATS_TEST_TMPDIR/b.tsv"
    grep -q "^/etc/keep	d	-$" "$BATS_TEST_TMPDIR/a.tsv"
    grep -q "^/etc/link	l	stock$" "$BATS_TEST_TMPDIR/a.tsv"
    grep -Eq "^/etc/stock	f	[0-9a-f]{64}$" "$BATS_TEST_TMPDIR/a.tsv"

    run "$ES" compare "$BATS_TEST_TMPDIR/a.tsv" "$BATS_TEST_TMPDIR/b.tsv"
    assert_success
    assert_output_contains "same	/etc/stock"
    assert_output_contains "same	/etc/keep/file"
    assert_output_contains "changed	/etc/mod"
    assert_output_contains "changed	/etc/link"
    assert_output_contains "removed	/etc/gone"
    assert_output_contains "added	/etc/added"
}

@test "identical trees compare as all same" {
    a="$BATS_TEST_TMPDIR/a"
    make_tree "$a"
    "$ES" snapshot "$a/etc" /etc >"$BATS_TEST_TMPDIR/1.tsv"
    "$ES" snapshot "$a/etc" /etc >"$BATS_TEST_TMPDIR/2.tsv"
    run bash -c '"$1" compare "$2" "$3" | grep -v "^same	"' _ "$ES" "$BATS_TEST_TMPDIR/1.tsv" "$BATS_TEST_TMPDIR/2.tsv"
    assert_failure 1
}

@test "before/after on a fixture root emits the etc-survival table" {
    r="$BATS_TEST_TMPDIR/root"
    make_tree "$r"
    run "$ES" before --root "$r"
    assert_success
    [ -f "$r/etc/steamos-fixes-probe.d/marker-plain" ]
    [ -L "$r/etc/steamos-fixes-probe.d/marker-symlink" ]
    [ -f "$r/etc/modprobe.d/steamos-fixes-probe.conf" ]
    [ -f "$r/etc/systemd/system/steamos-fixes-probe.marker" ]
    # drop-in dirs that do not exist are not created
    [ ! -e "$r/etc/rauc" ]
    [ -f "$r/var/lib/steamos-fixes-probe/before.tsv" ]

    # "update": lose a drop-in marker and a nested marker, change stock files
    rm "$r/etc/udev/rules.d/99-steamos-fixes-probe.rules"
    rm -r "$r/etc/steamos-fixes-probe.d/subdir"
    rm "$r/etc/gone"
    printf 'z\n' >>"$r/etc/mod"
    printf '/etc/modprobe.d/steamos-fixes-probe.conf\n' >"$BATS_TEST_TMPDIR/restored"

    run "$ES" after --root "$r" --restored "$BATS_TEST_TMPDIR/restored"
    assert_success
    assert_output_contains "| path | survives update? | restored by hook/service? | notes |"
    assert_output_contains '| `/etc/steamos-fixes-probe.d/marker-plain` | yes | - | marker |'
    assert_output_contains '| `/etc/steamos-fixes-probe.d/subdir/marker-nested` | no | - | marker |'
    assert_output_contains '| `/etc/udev/rules.d/99-steamos-fixes-probe.rules` | no | - | marker |'
    assert_output_contains '| `/etc/modprobe.d/steamos-fixes-probe.conf` | yes | yes | marker |'
    assert_output_contains "1 changed, 1 removed, 0 added"
    assert_output_contains '`/etc/gone`'

    run "$ES" before --root "$r"
    assert_failure 2

    run "$ES" cleanup --root "$r"
    assert_success
    [ ! -e "$r/etc/steamos-fixes-probe.d" ]
    [ ! -e "$r/etc/modprobe.d/steamos-fixes-probe.conf" ]
    [ ! -e "$r/var/lib/steamos-fixes-probe" ]
    [ -f "$r/etc/stock" ]
}

@test "table --all lists stock paths too" {
    a="$BATS_TEST_TMPDIR/a"
    make_tree "$a"
    "$ES" snapshot "$a/etc" /etc >"$BATS_TEST_TMPDIR/1.tsv"
    rm "$a/etc/gone"
    "$ES" snapshot "$a/etc" /etc >"$BATS_TEST_TMPDIR/2.tsv"
    run "$ES" table "$BATS_TEST_TMPDIR/1.tsv" "$BATS_TEST_TMPDIR/2.tsv" --all
    assert_success
    assert_output_contains '| `/etc/gone` | no | - | stock |'
    assert_output_contains '| `/etc/stock` | yes | - | stock |'
}

@test "roundtrip-test parses manifest paths and skips when the CLI lacks install" {
    # shellcheck disable=SC1091
    . "$REPO_ROOT/vm/guest/roundtrip-test.sh"
    m="$BATS_TEST_TMPDIR/manifest"
    printf '%s\n' '{"path":"/etc/modprobe.d/steamos-fixes.conf","component":"audio","kind":"file"}' \
        '{"component":"rgb","path":"/var/lib/steamos-fixes/x","kind":"file"}' >"$m"
    run rt_manifest_paths "$m"
    assert_success
    assert_output_contains "/etc/modprobe.d/steamos-fixes.conf"
    assert_output_contains "/var/lib/steamos-fixes/x"

    printf '%s\n' '^/etc/ld\.so\.cache$' >"$BATS_TEST_TMPDIR/ex"
    run rt_filter "$BATS_TEST_TMPDIR/ex" < <(printf '/etc/ld.so.cache\tf\tx\n/etc/keep\tf\ty\n')
    assert_success
    assert_output_contains "/etc/keep"
    case "$output" in *ld.so.cache*) false ;; esac

    # A CLI without install/uninstall: exit 77 (skip) before touching anything.
    fake="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$fake"
    printf '#!/bin/sh\necho "help version components"\n' >"$fake/steamos-fixes.sh"
    chmod +x "$fake/steamos-fixes.sh"
    run "$REPO_ROOT/vm/guest/roundtrip-test.sh" --repo "$fake" --out "$BATS_TEST_TMPDIR/rt"
    assert_failure 77
    assert_output_contains "skipping"
    [ ! -e "$BATS_TEST_TMPDIR/rt" ]
}

