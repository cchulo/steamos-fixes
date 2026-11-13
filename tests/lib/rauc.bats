#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# lib/rauc.sh and the RAUC handlers (plan §4.6, §5.2 rule 3b).
load '../test_helper'
load '../update_helper'

CONF=/etc/rauc/system.conf
PRE=/var/lib/steamos-fixes/libexec/rauc-pre-install.hook
POST=/var/lib/steamos-fixes/libexec/rauc-post-install.hook

setup() {
    make_root >/dev/null
    source_libs
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/rauc.sh"
    fixture_rauc_conf 1
    cp "$SOF_ROOT$CONF" "$BATS_TEST_TMPDIR/pristine"
}

# parses_single_handlers <file> <post> : configparser (what
# steamos-atomupd-client uses, strict mode) accepts the file and sees our
# post-install handler. A second [handlers] section or a repeated key would
# raise DuplicateSectionError / DuplicateOptionError.
parses_single_handlers() {
    python3 -I -c 'import configparser, sys
c = configparser.ConfigParser()
c.read(sys.argv[1])
assert c["handlers"]["post-install"] == sys.argv[2], dict(c["handlers"])
assert c["handlers"]["pre-install"] == sys.argv[3], dict(c["handlers"])' "$1" "$2" "$3"
}

@test "register puts one delimited block inside the stock [handlers] section and saves the original with its digest" {
    rauc_register "$PRE" "$POST"
    f="$SOF_ROOT$CONF"
    [ "$(grep -c '^\[handlers\]' "$f")" = 1 ]
    [ "$(grep -c '^# >>> steamos-fixes managed block' "$f")" = 1 ]
    [ "$(grep -c '^# >>> steamos-fixes' "$f")" = 2 ]
    [ "$(grep -c '^# <<< steamos-fixes' "$f")" = 2 ]
    # Our block follows the header; our keys appear once, the stock handler
    # line is kept as a prefixed comment.
    [ "$(grep -n -A1 '^\[handlers\]' "$f" | sed -n 2p | sed 's/^[0-9]*-//')" = "# >>> steamos-fixes managed block (sep=0); original saved as /var/lib/steamos-fixes/backup/rauc/system.conf; remove with \"steamos-fixes uninstall\"" ]
    [ "$(grep -c '^pre-install=' "$f")" = 1 ]
    [ "$(grep -c '^post-install=' "$f")" = 1 ]
    grep -qx "pre-install=$PRE" "$f"
    grep -qx "post-install=$POST" "$f"
    grep -qx '#steamos-fixes-orig:post-install=/usr/lib/rauc/post-install.sh' "$f"
    grep -qx 'bootloader-custom-backend=/usr/lib/rauc/bootloader-custom-backend.sh' "$f"
    # The stock file is still there under our blocks.
    [ "$(rauc_strip_block "$f" | sof_sha256 /dev/stdin)" = "$(sof_sha256 "$BATS_TEST_TMPDIR/pristine")" ]
    b="$SOF_ROOT/var/lib/steamos-fixes/backup/rauc/system.conf"
    cmp "$b" "$BATS_TEST_TMPDIR/pristine"
    [ "$(cat "$b.sha256")" = "$(sof_sha256 "$b")" ]
    rauc_registered "$PRE" "$POST"
}

@test "registered file has one [handlers] section for configparser (steamos-atomupd-client)" {
    command -v python3 >/dev/null || skip "python3 not installed"
    rauc_register "$PRE" "$POST"
    parses_single_handlers "$SOF_ROOT$CONF" "$POST" "$PRE"
    # The same with no stock [handlers] section (block appended with a header).
    fixture_rauc_conf 0
    rauc_register "$PRE" "$POST"
    [ "$(grep -c '^\[handlers\]' "$SOF_ROOT$CONF")" = 1 ]
    parses_single_handlers "$SOF_ROOT$CONF" "$POST" "$PRE"
}

@test "stock pre-install and post-install are both kept as comments and chained" {
    printf '[system]\ncompatible=steamos-amd64\n\n[handlers]\npost-install=/usr/lib/rauc/post-install.sh\npre-install = /usr/lib/rauc/pre.sh\n\n[slot.rootfs.0]\nbootname=A\n' >"$SOF_ROOT$CONF"
    cp "$SOF_ROOT$CONF" "$BATS_TEST_TMPDIR/two"
    rauc_register "$PRE" "$POST"
    f="$SOF_ROOT$CONF"
    [ "$(grep -c '^pre-install' "$f")" = 1 ]
    [ "$(grep -c '^post-install' "$f")" = 1 ]
    grep -qx '#steamos-fixes-orig:pre-install = /usr/lib/rauc/pre.sh' "$f"
    [ "$(rauc_chain_get pre-install)" = /usr/lib/rauc/pre.sh ]
    [ "$(rauc_chain_get post-install)" = /usr/lib/rauc/post-install.sh ]
    rauc_unregister
    cmp "$f" "$BATS_TEST_TMPDIR/two"
}

@test "old layout (block appended with a second [handlers]) is migrated by register, unregister restores pristine" {
    f="$SOF_ROOT$CONF"
    {
        cat "$BATS_TEST_TMPDIR/pristine"
        printf '%s\n' "# >>> steamos-fixes managed block (sep=0); original saved as /var/lib/steamos-fixes/backup/rauc/system.conf; remove with \"steamos-fixes uninstall\"" \
            '# stock handlers are chained, see /var/lib/steamos-fixes/state/rauc-chain' \
            '[handlers]' "pre-install=$PRE" "post-install=$POST" '# <<< steamos-fixes'
    } >"$f"
    [ "$(grep -c '^\[handlers\]' "$f")" = 2 ]
    run rauc_registered "$PRE" "$POST"
    assert_failure
    rauc_register "$PRE" "$POST"
    [ "$(grep -c '^\[handlers\]' "$f")" = 1 ]
    [ "$(tail -n1 "$f")" = "bootname=A" ]
    rauc_registered "$PRE" "$POST"
    cmp "$SOF_ROOT/var/lib/steamos-fixes/backup/rauc/system.conf" "$BATS_TEST_TMPDIR/pristine"
    rauc_unregister
    cmp "$f" "$BATS_TEST_TMPDIR/pristine"
}

@test "existing stock handlers are chained, not replaced" {
    rauc_register "$PRE" "$POST"
    [ "$(rauc_chain_get post-install)" = /usr/lib/rauc/post-install.sh ]
    [ -z "$(rauc_chain_get pre-install)" ]
    # The stock value is still what the file says outside our block.
    [ "$(rauc_handler_value "$SOF_ROOT$CONF" post-install)" = /usr/lib/rauc/post-install.sh ]
}

@test "relative handler paths are resolved against /etc/rauc" {
    fixture_rauc_conf 1
    sed -i.bak 's#^post-install=.*#post-install=hooks/post.sh#' "$SOF_ROOT$CONF"
    rm -f "$SOF_ROOT$CONF.bak"
    rauc_register "$PRE" "$POST"
    [ "$(rauc_chain_get post-install)" = /etc/rauc/hooks/post.sh ]
}

@test "without a stock [handlers] section nothing is chained" {
    fixture_rauc_conf 0
    cp "$SOF_ROOT$CONF" "$BATS_TEST_TMPDIR/nohandlers"
    rauc_register "$PRE" "$POST"
    [ -z "$(rauc_chain_get post-install)" ]
    [ -z "$(rauc_chain_get pre-install)" ]
    rauc_unregister
    cmp "$SOF_ROOT$CONF" "$BATS_TEST_TMPDIR/nohandlers"
}

@test "register is idempotent (run twice = same bytes)" {
    rauc_register "$PRE" "$POST"
    first=$(sof_sha256 "$SOF_ROOT$CONF")
    rauc_register "$PRE" "$POST"
    [ "$(sof_sha256 "$SOF_ROOT$CONF")" = "$first" ]
    [ "$(grep -c '^# >>> steamos-fixes managed block' "$SOF_ROOT$CONF")" = 1 ]
    [ "$(grep -c '^\[handlers\]' "$SOF_ROOT$CONF")" = 1 ]
}

@test "never chains to itself when our handler is the stock value" {
    sed -i.bak "s#^post-install=.*#post-install=$POST#" "$SOF_ROOT$CONF"
    rm -f "$SOF_ROOT$CONF.bak"
    rauc_register "$PRE" "$POST"
    [ -z "$(rauc_chain_get post-install)" ]
}

@test "unregister restores the original byte-for-byte and drops the chain file" {
    rauc_register "$PRE" "$POST"
    rauc_unregister
    cmp "$SOF_ROOT$CONF" "$BATS_TEST_TMPDIR/pristine"
    [ ! -e "$SOF_ROOT/var/lib/steamos-fixes/state/rauc-chain" ]
    ! rauc_block_present
    # idempotent
    rauc_unregister
    cmp "$SOF_ROOT$CONF" "$BATS_TEST_TMPDIR/pristine"
}

@test "original without a final newline round-trips byte-for-byte" {
    printf '%s' "$(cat "$SOF_ROOT$CONF")" >"$SOF_ROOT$CONF"
    cp "$SOF_ROOT$CONF" "$BATS_TEST_TMPDIR/noeol"
    rauc_register "$PRE" "$POST"
    grep -q '^# >>> steamos-fixes managed block (sep=1)' "$SOF_ROOT$CONF"
    rm -rf "$SOF_ROOT/var/lib/steamos-fixes/backup"
    rauc_unregister
    cmp "$SOF_ROOT$CONF" "$BATS_TEST_TMPDIR/noeol"
    # The same when the unterminated last line is the stock handler we comment out.
    printf '[system]\ncompatible=steamos-amd64\n\n[handlers]\npost-install=/usr/lib/rauc/post-install.sh' >"$SOF_ROOT$CONF"
    cp "$SOF_ROOT$CONF" "$BATS_TEST_TMPDIR/noeol2"
    rauc_register "$PRE" "$POST"
    [ "$(rauc_chain_get post-install)" = /usr/lib/rauc/post-install.sh ]
    rauc_register "$PRE" "$POST"
    rauc_unregister
    cmp "$SOF_ROOT$CONF" "$BATS_TEST_TMPDIR/noeol2"
}

@test "corrupted backup: unregister strips only our block, still byte-identical" {
    rauc_register "$PRE" "$POST"
    printf 'tampered\n' >"$SOF_ROOT/var/lib/steamos-fixes/backup/rauc/system.conf"
    run rauc_unregister
    assert_success
    assert_output_contains "no valid backup"
    cmp "$SOF_ROOT$CONF" "$BATS_TEST_TMPDIR/pristine"
}

@test "stock file changed under our block: backup refreshed on register, new stock restored" {
    rauc_register "$PRE" "$POST"
    # A SteamOS update shipped a new stock system.conf; apply re-registers.
    fixture_rauc_conf 1
    printf '[slot.rootfs.1]\ndevice=/dev/disk/by-partsets/B/rootfs\n' >>"$SOF_ROOT$CONF"
    cp "$SOF_ROOT$CONF" "$BATS_TEST_TMPDIR/newstock"
    rauc_register "$PRE" "$POST"
    cmp "$SOF_ROOT/var/lib/steamos-fixes/backup/rauc/system.conf" "$BATS_TEST_TMPDIR/newstock"
    rauc_unregister
    cmp "$SOF_ROOT$CONF" "$BATS_TEST_TMPDIR/newstock"
}

@test "missing system.conf (not SteamOS): register skips with a warning" {
    rm -f "$SOF_ROOT$CONF"
    run rauc_register "$PRE" "$POST"
    assert_success
    assert_output_contains "not found"
    [ ! -e "$SOF_ROOT$CONF" ]
}

@test "dry-run register writes nothing" {
    before=$(tree_digest "$SOF_ROOT")
    SOF_DRY_RUN=1
    rauc_register "$PRE" "$POST" 2>/dev/null
    SOF_DRY_RUN=0
    [ "$(tree_digest "$SOF_ROOT")" = "$before" ]
}

@test "incoming kernel version: override, bundle manifest hint, unknown" {
    SOF_INCOMING_KVER=7.3.0-valve1 run rauc_incoming_kver
    assert_success
    [ "$output" = 7.3.0-valve1 ]
    mkdir -p "$BATS_TEST_TMPDIR/bundle"
    printf '[update]\ncompatible=steamos-amd64\n' >"$BATS_TEST_TMPDIR/bundle/manifest.raucm"
    RAUC_BUNDLE_MOUNT_POINT="$BATS_TEST_TMPDIR/bundle" run rauc_incoming_kver
    assert_failure
    printf 'kernel-version=7.3.1-valve1\n' >>"$BATS_TEST_TMPDIR/bundle/manifest.raucm"
    RAUC_BUNDLE_MOUNT_POINT="$BATS_TEST_TMPDIR/bundle" run rauc_incoming_kver
    [ "$output" = 7.3.1-valve1 ]
}

# ---------------------------------------------------------------- handlers --

hook_env() {
    fake_src self-update rebuild
    export SOF_SRC="$BATS_TEST_TMPDIR/src"
    export SOF_HANDLER_SELF_UPDATED=1
    STOCK_LOG="$BATS_TEST_TMPDIR/stock.log"
    export STOCK_LOG
    mkdir -p "$SOF_ROOT/usr/lib/rauc"
    printf '#!/bin/sh\necho "stock $0 $*" >>"$STOCK_LOG"\nexit ${STOCK_RC:-0}\n' >"$SOF_ROOT/usr/lib/rauc/post-install.sh"
    chmod +x "$SOF_ROOT/usr/lib/rauc/post-install.sh"
    rauc_register "$PRE" "$POST"
}

@test "pre-install hook: default policy degrade lets an update through and notes the pending rebuild" {
    hook_env
    SOF_INCOMING_KVER=7.9.0-test run "$REPO_ROOT/overlay/rauc/pre-install.hook"
    assert_success
    assert_output_contains "policy: degrade"
    grep -q '^kver=7.9.0-test$' "$SOF_ROOT/var/lib/steamos-fixes/state/pending-rebuild"
    [ ! -e "$SOF_ROOT/var/lib/steamos-fixes/state/update-blocked" ]
}

@test "pre-install hook: blocks under the opt-in policy block when modules are missing" {
    hook_env
    "$FAKE_CLI" --root "$SOF_ROOT" update-policy block
    SOF_INCOMING_KVER=7.9.0-test run "$REPO_ROOT/overlay/rauc/pre-install.hook"
    assert_failure
    assert_output_contains "blocking this SteamOS update"
    grep -q '^kver=7.9.0-test$' "$SOF_ROOT/var/lib/steamos-fixes/state/update-blocked"
}

@test "pre-install hook: degrade --once lets exactly one update through under block" {
    hook_env
    "$FAKE_CLI" --root "$SOF_ROOT" update-policy block
    "$FAKE_CLI" --root "$SOF_ROOT" update-policy degrade --once
    SOF_INCOMING_KVER=7.9.0-test run "$REPO_ROOT/overlay/rauc/pre-install.hook"
    assert_success
    grep -q '^kver=7.9.0-test$' "$SOF_ROOT/var/lib/steamos-fixes/state/pending-rebuild"
    SOF_INCOMING_KVER=7.9.0-test run "$REPO_ROOT/overlay/rauc/pre-install.hook"
    assert_failure
}

@test "pre-install hook: passes when modules exist or the kernel is unknown" {
    hook_env
    mkdir -p "$SOF_ROOT/etc/steamos-fixes/modules/7.9.0-test"
    SOF_INCOMING_KVER=7.9.0-test run "$REPO_ROOT/overlay/rauc/pre-install.hook"
    assert_success
    run "$REPO_ROOT/overlay/rauc/pre-install.hook"
    assert_success
    assert_output_contains "cannot tell the incoming kernel"
}

@test "pre-install hook: a rebuild command, when present, produces the modules" {
    hook_env
    cat >"$SOF_SRC/cmd/rebuild.sh" <<'C'
# summary: fake
cmd_rebuild() { mkdir -p "$(sof_path "$SOF_MODULES_REL")/$2"; }
C
    SOF_INCOMING_KVER=7.9.0-test run "$REPO_ROOT/overlay/rauc/pre-install.hook"
    assert_success
    [ -d "$SOF_ROOT/etc/steamos-fixes/modules/7.9.0-test" ]
}

@test "pre-install hook: without a checkout it never blocks" {
    hook_env
    SOF_SRC="$BATS_TEST_TMPDIR/nowhere" SOF_INCOMING_KVER=7.9.0-test run "$REPO_ROOT/overlay/rauc/pre-install.hook"
    assert_success
    assert_output_contains "checkout not found"
}

@test "post-install hook: runs the stock handler first, then re-applies to the new slot" {
    hook_env
    slot="$BATS_TEST_TMPDIR/slotB"
    mkdir -p "$slot/usr/lib/modules/7.9.0-test" "$slot/etc" "$slot/var/lib/steamos-fixes"
    mkdir -p "$SOF_ROOT/etc/steamos-fixes/modules/7.9.0-test"
    printf 'ko\n' >"$SOF_ROOT/etc/steamos-fixes/modules/7.9.0-test/x.ko"
    # Fake components dir with nothing in it keeps this test about the flow.
    mkdir -p "$BATS_TEST_TMPDIR/nocomponents"
    SOF_COMPONENTS_DIR="$BATS_TEST_TMPDIR/nocomponents" SOF_SLOT=A \
        run "$REPO_ROOT/overlay/rauc/post-install.hook"
    # No partsets in the fixture, so mounting the new slot fails: the hook
    # still succeeds (never fails an update), after running the stock handler.
    assert_success
    assert_output_contains "will retry on first boot"
    grep -q 'stock' "$STOCK_LOG"
    # Now drive our part directly with a prepared slot root.
    SOF_COMPONENTS_DIR="$BATS_TEST_TMPDIR/nocomponents" SOF_SLOT=A \
        run "$FAKE_CLI" --root "$SOF_ROOT" rauc-handler post-install --slot-root "$slot"
    assert_success
    [ -f "$slot/etc/steamos-fixes/modules/7.9.0-test/x.ko" ]
    grep -q '^to=B$' "$slot/var/lib/steamos-fixes/state/pending-reboot-check"
    grep -q '^kver=7.9.0-test$' "$slot/var/lib/steamos-fixes/state/pending-reboot-check"
    [ -f "$slot/var/lib/steamos-fixes/state/status.json" ]
}

@test "post-install hook: a failing stock handler is propagated and we stay out" {
    hook_env
    STOCK_RC=3 run "$REPO_ROOT/overlay/rauc/post-install.hook"
    assert_failure 3
    assert_output_contains "not touching the new slot"
}
