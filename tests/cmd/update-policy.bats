#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# cmd/update-policy.sh (plan §4.6).
load '../test_helper'
load '../update_helper'

setup() {
    make_root >/dev/null
    STATE="$SOF_ROOT/var/lib/steamos-fixes/state"
}

@test "default policy is degrade (never block a SteamOS update)" {
    run "$CLI" --root "$SOF_ROOT" update-policy
    assert_success
    [ "$output" = degrade ]
    run "$CLI" --root "$SOF_ROOT" update-policy effective
    [ "$output" = degrade ]
}

@test "block is persisted; degrade switches back" {
    run "$CLI" --root "$SOF_ROOT" update-policy block
    assert_success
    [ "$(cat "$STATE/update-policy")" = block ]
    run "$CLI" --root "$SOF_ROOT" update-policy show
    [ "$output" = block ]
    "$CLI" --root "$SOF_ROOT" update-policy degrade 2>/dev/null
    run "$CLI" --root "$SOF_ROOT" update-policy show
    [ "$output" = degrade ]
}

@test "degrade --once applies to the next update only" {
    "$CLI" --root "$SOF_ROOT" update-policy block 2>/dev/null
    "$CLI" --root "$SOF_ROOT" update-policy degrade --once 2>/dev/null
    run "$CLI" --root "$SOF_ROOT" update-policy show
    [ "$output" = "block (next update: degrade once)" ]
    run "$CLI" --root "$SOF_ROOT" update-policy effective
    [ "$output" = degrade ]
    # peeking does not consume
    [ -f "$STATE/update-policy-once" ]
    run "$CLI" --root "$SOF_ROOT" update-policy effective --consume
    [ "$output" = degrade ]
    [ ! -e "$STATE/update-policy-once" ]
    run "$CLI" --root "$SOF_ROOT" update-policy effective
    [ "$output" = block ]
}

@test "block clears a pending --once" {
    "$CLI" --root "$SOF_ROOT" update-policy degrade --once 2>/dev/null
    "$CLI" --root "$SOF_ROOT" update-policy block 2>/dev/null
    [ ! -e "$STATE/update-policy-once" ]
}

@test "garbage in the state file falls back to degrade" {
    mkdir -p "$STATE"
    printf 'yolo\n' >"$STATE/update-policy"
    run "$CLI" --root "$SOF_ROOT" update-policy
    [ "$output" = degrade ]
}

@test "bad arguments exit 2" {
    run "$CLI" --root "$SOF_ROOT" update-policy maybe
    assert_failure 2
    run "$CLI" --root "$SOF_ROOT" update-policy block --once
    assert_failure 2
    run "$CLI" --root "$SOF_ROOT" update-policy degrade --forever
    assert_failure 2
}

@test "idempotent: setting the same policy twice is a no-op" {
    "$CLI" --root "$SOF_ROOT" update-policy block 2>/dev/null
    d1=$(tree_digest "$SOF_ROOT")
    "$CLI" --root "$SOF_ROOT" update-policy block 2>/dev/null
    [ "$(tree_digest "$SOF_ROOT")" = "$d1" ]
}

@test "dry-run writes nothing" {
    before=$(tree_digest "$SOF_ROOT")
    run "$CLI" --root "$SOF_ROOT" --dry-run update-policy degrade
    assert_success
    run "$CLI" --root "$SOF_ROOT" --dry-run update-policy degrade --once
    assert_success
    [ "$(tree_digest "$SOF_ROOT")" = "$before" ]
}
