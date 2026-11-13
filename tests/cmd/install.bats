#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
load '../test_helper'
load 'git_helper'

STATE=/var/lib/steamos-fixes

# A fake upstream: a stub CLI that records how it was called, stub apply and
# status commands, placeholder keys and a standalone uninstaller.
setup() {
    make_root >/dev/null
    git_isolate
    W="$BATS_TEST_TMPDIR/upstream"
    mkdir -p "$W/cmd" "$W/keys" "$W/uninstall"
    cat >"$W/steamos-fixes.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$(cd "$(dirname "$0")" && pwd -P)" "$*" >>"$SOF_ROOT/calls"
STUB
    printf 'cmd_apply() { :; }\n' >"$W/cmd/apply.sh"
    printf 'cmd_status() { :; }\n' >"$W/cmd/status.sh"
    printf '# placeholder\n' >"$W/keys/allowed_signers"
    printf '#!/bin/sh\necho uninstall\n' >"$W/uninstall/uninstall.sh"
    git -C "$W" init --quiet
    commit_all "$W" "initial"
    git -C "$W" tag -a v0.1.0 -m v0.1.0
    ORIGIN="$BATS_TEST_TMPDIR/origin.git"
    make_bare_origin "$W" "$ORIGIN"
    SRC="$SOF_ROOT$STATE/src"
}

@test "install clones into the state dir, creates the tree, records installed-from, applies" {
    run "$CLI" install --repo "$ORIGIN" --ref v0.1.0
    assert_success
    [ -d "$SRC/.git" ]
    [ "$(head_of "$SRC")" = "$(head_of "$W" v0.1.0)" ]
    for d in modules cache backup state log bin; do
        [ -d "$SOF_ROOT$STATE/$d" ]
    done
    grep -qx "url=$ORIGIN" "$SOF_ROOT$STATE/state/installed-from"
    grep -qx "ref=v0.1.0" "$SOF_ROOT$STATE/state/installed-from"
    grep -qx "commit=$(head_of "$W" v0.1.0)" "$SOF_ROOT$STATE/state/installed-from"
    grep -q '^date=20' "$SOF_ROOT$STATE/state/installed-from"
    [ -f "$SOF_ROOT$STATE/keys/allowed_signers" ]
    [ -x "$SOF_ROOT$STATE/uninstall.sh" ]
    # apply then status, both from the installed checkout.
    src_real=$(cd "$SRC" && pwd -P)
    [ "$(sed -n 1p "$SOF_ROOT/calls")" = "$src_real apply" ]
    [ "$(sed -n 2p "$SOF_ROOT/calls")" = "$src_real status" ]
}

@test "--dry-run writes nothing" {
    run "$CLI" --dry-run install --repo "$ORIGIN" --ref v0.1.0
    assert_success
    assert_output_contains "[dry-run]"
    [ ! -e "$SRC" ]
    [ ! -e "$SOF_ROOT$STATE/state" ]
    [ ! -e "$SOF_ROOT$STATE/keys" ]
    [ ! -e "$SOF_ROOT/calls" ]
}

@test "--no-apply stops after clone and pinning" {
    run "$CLI" install --no-apply --repo "$ORIGIN" --ref v0.1.0
    assert_success
    [ -f "$SOF_ROOT$STATE/state/installed-from" ]
    [ ! -e "$SOF_ROOT/calls" ]
}

@test "re-running install updates the existing checkout to a newer ref" {
    run "$CLI" install --no-apply --repo "$ORIGIN" --ref v0.1.0
    assert_success
    printf 'next\n' >"$W/NEXT"
    commit_all "$W" "next"
    git -C "$W" tag -a v0.2.0 -m v0.2.0
    git -C "$W" push --quiet origin main --tags
    run "$CLI" install --no-apply --repo "$ORIGIN" --ref v0.2.0
    assert_success
    [ "$(head_of "$SRC")" = "$(head_of "$W" v0.2.0)" ]
    grep -qx "ref=v0.2.0" "$SOF_ROOT$STATE/state/installed-from"
}

@test "re-install refuses to touch a checkout with local modifications" {
    run "$CLI" install --no-apply --repo "$ORIGIN" --ref v0.1.0
    assert_success
    printf 'mine\n' >>"$SRC/keys/allowed_signers"
    run "$CLI" install --no-apply --repo "$ORIGIN" --ref v0.1.0
    assert_failure
    assert_output_contains "local modifications"
    grep -q mine "$SRC/keys/allowed_signers"
}

@test "pinned keys are kept on re-install unless --repin-keys" {
    run "$CLI" install --no-apply --repo "$ORIGIN" --ref v0.1.0
    assert_success
    printf 'pinned-by-owner\n' >"$SOF_ROOT$STATE/keys/allowed_signers"
    run "$CLI" install --no-apply --repo "$ORIGIN" --ref v0.1.0
    assert_success
    grep -q pinned-by-owner "$SOF_ROOT$STATE/keys/allowed_signers"
    assert_output_contains "keeping the pinned ones"
    run "$CLI" install --no-apply --repin-keys --repo "$ORIGIN" --ref v0.1.0
    assert_success
    ! grep -q pinned-by-owner "$SOF_ROOT$STATE/keys/allowed_signers"
}

@test "placeholder pins are replaced by real keys without --repin-keys" {
    run "$CLI" install --no-apply --repo "$ORIGIN" --ref v0.1.0
    assert_success
    printf 'owner@example.invalid namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderReplacedByARealLookingKey test\n' >"$W/keys/allowed_signers"
    commit_all "$W" "real key"
    git -C "$W" tag -a v0.1.1 -m v0.1.1
    git -C "$W" push --quiet origin main --tags
    run "$CLI" install --no-apply --repo "$ORIGIN" --ref v0.1.1
    assert_success
    assert_output_contains "placeholders only; pinning the real keys"
    grep -q 'AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderReplacedByARealLookingKey' "$SOF_ROOT$STATE/keys/allowed_signers"
    # A real pin is kept afterwards.
    printf 'owner@example.invalid namespaces="git" ssh-ed25519 AAAAOther test\n' >"$W/keys/allowed_signers"
    commit_all "$W" "rotate"
    git -C "$W" tag -a v0.1.2 -m v0.1.2
    git -C "$W" push --quiet origin main --tags
    run "$CLI" install --no-apply --repo "$ORIGIN" --ref v0.1.2
    assert_success
    assert_output_contains "keeping the pinned ones"
    grep -q 'AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderReplacedByARealLookingKey' "$SOF_ROOT$STATE/keys/allowed_signers"
}

@test "install refuses when read-only mode was disabled, unless --i-know" {
    fixture_file /.sof-readonly-disabled
    run "$CLI" install --no-apply --repo "$ORIGIN" --ref v0.1.0
    assert_failure
    assert_output_contains "read-only"
    run "$CLI" --i-know install --no-apply --repo "$ORIGIN" --ref v0.1.0
    assert_success
}

@test "bootstrap.sh clones the newest release tag and runs install" {
    printf 'next\n' >"$W/NEXT"
    commit_all "$W" "next"
    git -C "$W" tag -a v0.10.0 -m v0.10.0
    git -C "$W" push --quiet origin main --tags
    # The fake upstream's stub CLI stands in for the real installer here.
    SOF_REPO_URL="$ORIGIN" run sh "$REPO_ROOT/bootstrap.sh" --no-apply
    assert_success
    assert_output_contains "v0.10.0"
    grep -q " install --repo $ORIGIN --ref v0.10.0 --no-apply\$" "$SOF_ROOT/calls"
}
