#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
load '../test_helper'

setup() {
    make_root >/dev/null
    source_libs
}

@test "sof_path prefixes SOF_ROOT" {
    [ "$(sof_path /etc/x)" = "$SOF_ROOT/etc/x" ]
    [ "$(sof_path etc/x)" = "$SOF_ROOT/etc/x" ]
}

@test "sof_path with empty root yields absolute path" {
    SOF_ROOT=""
    [ "$(sof_path /etc/x)" = "/etc/x" ]
}

@test "sof_version_ge compares dotted versions" {
    sof_version_ge 0.4.0 0.4.0
    sof_version_ge 0.4.1 0.4.0
    sof_version_ge 1.0 0.9.9
    ! sof_version_ge 0.3.9 0.4.0
    sof_version_ge 7.2.7-valve2 7.2.7
}

@test "sof_sha256 matches a known digest" {
    printf 'abc' >"$SOF_ROOT/f"
    [ "$(sof_sha256 "$SOF_ROOT/f")" = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" ]
}

@test "sof_atomic_write writes via temp file with mode" {
    printf 'hello' | sof_atomic_write "$SOF_ROOT/out" 0600
    [ "$(cat "$SOF_ROOT/out")" = hello ]
    ! ls "$SOF_ROOT"/out.?????? 2>/dev/null
}

@test "sof_atomic_write in dry-run writes nothing" {
    SOF_DRY_RUN=1
    printf 'hello' | sof_atomic_write "$SOF_ROOT/out" 2>/dev/null
    [ ! -e "$SOF_ROOT/out" ]
}

@test "sof_mkdir_p reports created vs existed" {
    [ "$(sof_mkdir_p "$SOF_ROOT/new/dir")" = created ]
    [ "$(sof_mkdir_p "$SOF_ROOT/new/dir")" = existed ]
}

@test "sof_mkdir_p_list prints created ancestors top-most first" {
    mkdir -p "$SOF_ROOT/a"
    run sof_mkdir_p_list "$SOF_ROOT/a/b/c"
    assert_success
    [ "$output" = "$SOF_ROOT/a/b
$SOF_ROOT/a/b/c" ]
    [ -d "$SOF_ROOT/a/b/c" ]
    run sof_mkdir_p_list "$SOF_ROOT/a/b/c"
    assert_success
    [ -z "$output" ]
}

@test "readonly check passes on an untouched fixture root" {
    sof_check_readonly_root
}

@test "readonly check refuses when steamos-readonly is disabled" {
    touch "$SOF_ROOT/.sof-readonly-disabled"
    run sof_check_readonly_root
    assert_failure
    assert_output_contains "refuses"
}

@test "readonly check continues with --i-know" {
    touch "$SOF_ROOT/.sof-readonly-disabled"
    SOF_I_KNOW=1
    run sof_check_readonly_root
    assert_success
}

@test "require_root is a no-op on fixture roots" {
    require_root
}

@test "die uses the given exit code" {
    run die 7 "boom"
    [ "$status" -eq 7 ]
    assert_output_contains "boom"
}

@test "sof_state_dir_ensure keeps an existing real state dir" {
    [ "$(sof_state_dir_ensure)" = "$SOF_ROOT/var/lib/steamos-fixes" ]
    [ -d "$SOF_ROOT/var/lib/steamos-fixes" ] && [ ! -L "$SOF_ROOT/var/lib/steamos-fixes" ]
}

@test "sof_state_dir_ensure creates /home/.steamos-fixes and a symlink when /home exists" {
    rmdir "$SOF_ROOT/var/lib/steamos-fixes"
    mkdir -p "$SOF_ROOT/home/deck"
    sof_state_dir_ensure >/dev/null
    [ -L "$SOF_ROOT/var/lib/steamos-fixes" ]
    [ "$(readlink "$SOF_ROOT/var/lib/steamos-fixes")" = ../../home/.steamos-fixes ]
    [ -d "$SOF_ROOT/home/.steamos-fixes" ]
    # writing through the canonical path lands in /home
    touch "$SOF_ROOT/var/lib/steamos-fixes/x"
    [ -f "$SOF_ROOT/home/.steamos-fixes/x" ]
    # idempotent
    sof_state_dir_ensure >/dev/null
    [ -L "$SOF_ROOT/var/lib/steamos-fixes" ]
}

@test "sof_state_dir_ensure falls back to a real dir without /home, and dry-run creates nothing" {
    rmdir "$SOF_ROOT/var/lib/steamos-fixes"
    sof_state_dir_ensure >/dev/null
    [ -d "$SOF_ROOT/var/lib/steamos-fixes" ] && [ ! -L "$SOF_ROOT/var/lib/steamos-fixes" ]
    rmdir "$SOF_ROOT/var/lib/steamos-fixes"
    mkdir -p "$SOF_ROOT/home"
    SOF_DRY_RUN=1 sof_state_dir_ensure >/dev/null 2>&1
    [ ! -e "$SOF_ROOT/var/lib/steamos-fixes" ]
    [ ! -e "$SOF_ROOT/home/.steamos-fixes" ]
}
