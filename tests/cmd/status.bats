#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
load '../test_helper'

STATE=/var/lib/steamos-fixes

# Same throwaway "demo" component as tests/lib/component.bats, plus a
# probe_details hook.
setup() {
    make_root >/dev/null
    export SOF_KVER="7.2.7-valve2-1-neptune-72"
    export SOF_COMPONENTS_DIR="$BATS_TEST_TMPDIR/components"
    mkdir -p "$SOF_COMPONENTS_DIR" "$BATS_TEST_TMPDIR/overlay/demo"
    printf 'demo file\n' >"$BATS_TEST_TMPDIR/overlay/demo/demo.conf"
    cat >"$SOF_COMPONENTS_DIR/demo.sh" <<'C'
COMPONENT_DESCRIPTION="demo component"
demo_files() {
    printf 'demo/demo.conf\t/etc/demo.d/steamos-fixes.conf\t0644\n'
}
demo_probe() {
    [ -e "$(sof_path /usr/share/demo-native)" ] && return 0
    [ -e "$(sof_path /usr/share/demo-unknown)" ] && return 2
    return 1
}
demo_probe_details() { printf 'looked for demo-native\n'; }
demo_status_detail() { printf 'demo detail line\n'; }
C
}

json_ok() {
    if command -v jq >/dev/null 2>&1; then
        jq -e . "$1" >/dev/null
    else
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1"
    fi
}

json_get() {
    if command -v jq >/dev/null 2>&1; then
        jq -r "$2" "$1"
    else
        python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
expr = sys.argv[2].lstrip(".")
for part in expr.replace("[", ".").replace("]", "").split("."):
    if part == "":
        continue
    d = d[int(part)] if part.isdigit() else d[part]
print(str(d).lower() if isinstance(d, bool) else d)
PY
    fi
}

install_demo() {
    (
        source_libs
        manifest_install_file "$BATS_TEST_TMPDIR/overlay/demo/demo.conf" /etc/demo.d/steamos-fixes.conf demo
    )
}

@test "status prints header and one row per component, exit 0" {
    run "$CLI" status
    assert_success
    assert_output_contains "running kernel:"
    assert_output_contains "$SOF_KVER"
    assert_output_contains "update policy:           degrade"
    assert_output_contains "last self-update check:  never"
    echo "$output" | grep -Eq '^demo +stock +demo component$'
}

@test "status follows the component lifecycle: stock, active, superseded, n/a" {
    install_demo
    run "$CLI" status
    echo "$output" | grep -Eq '^demo +active '
    fixture_file /usr/share/demo-native
    run "$CLI" status
    echo "$output" | grep -Eq '^demo +superseded '
    rm -f "$SOF_ROOT/usr/share/demo-native" "$SOF_ROOT/etc/demo.d/steamos-fixes.conf"
    rm -f "$SOF_ROOT$STATE/manifest"
    fixture_file /usr/share/demo-unknown
    run "$CLI" status
    echo "$output" | grep -Eq '^demo +n/a '
}

@test "--verbose adds <name>_probe_details output" {
    run "$CLI" status --verbose
    assert_success
    assert_output_contains "    looked for demo-native"
    run "$CLI" status
    [[ "$output" != *"looked for demo-native"* ]]
}

@test "header reads policy, pending check, staged modules, last check" {
    fixture_file "$STATE/state/update-policy" "block
"
    fixture_file "$STATE/state/pending-reboot-check" ""
    fixture_file "/etc/steamos-fixes/modules/$SOF_KVER/BUILD-INFO" "commit=abc"
    fixture_file "$STATE/state/last-update-check" "$(printf '2026-10-30T10:00:00Z\t1793354400\tavailable\tv0.2.0')"
    run "$CLI" status
    assert_success
    assert_output_contains "modules staged for it:   yes"
    assert_output_contains "update policy:           block"
    assert_output_contains "pending reboot check:    yes"
    assert_output_contains "2026-10-30T10:00:00Z (available v0.2.0)"
}

@test "--json is valid JSON with the same facts, and status.json is written" {
    install_demo
    fixture_file "$STATE/state/last-update-check" "$(printf '2026-10-30T10:00:00Z\t1793354400\tup-to-date\tv0.1.0')"
    run "$CLI" status --json
    assert_success
    printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/out.json"
    json_ok "$BATS_TEST_TMPDIR/out.json"
    [ "$(json_get "$BATS_TEST_TMPDIR/out.json" .components[0].name)" = demo ]
    [ "$(json_get "$BATS_TEST_TMPDIR/out.json" .components[0].status)" = active ]
    [ "$(json_get "$BATS_TEST_TMPDIR/out.json" .kernel.running)" = "$SOF_KVER" ]
    [ "$(json_get "$BATS_TEST_TMPDIR/out.json" .kernel.modules_staged)" = false ]
    [ "$(json_get "$BATS_TEST_TMPDIR/out.json" .update_policy)" = degrade ]
    [ "$(json_get "$BATS_TEST_TMPDIR/out.json" .last_update_check.result)" = up-to-date ]
    json_ok "$SOF_ROOT$STATE/state/status.json"
    [ "$(json_get "$SOF_ROOT$STATE/state/status.json" .components[0].status)" = active ]
}

@test "plain status also refreshes status.json; --dry-run does not" {
    run "$CLI" status
    assert_success
    json_ok "$SOF_ROOT$STATE/state/status.json"
    rm -f "$SOF_ROOT$STATE/state/status.json"
    run "$CLI" --dry-run status --json
    assert_success
    [ ! -e "$SOF_ROOT$STATE/state/status.json" ]
}

@test "JSON escapes awkward descriptions" {
    cat >"$SOF_COMPONENTS_DIR/quote.sh" <<'C'
COMPONENT_DESCRIPTION='has "quotes" and \ backslash'
quote_files() { :; }
quote_probe() { return 1; }
C
    run "$CLI" status --json
    assert_success
    printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/out.json"
    json_ok "$BATS_TEST_TMPDIR/out.json"
    [ "$(json_get "$BATS_TEST_TMPDIR/out.json" .components[1].description)" = 'has "quotes" and \ backslash' ]
}

@test "a broken component shows as error without failing status" {
    printf 'COMPONENT_DESCRIPTION=broken\n' >"$SOF_COMPONENTS_DIR/broken.sh"
    run "$CLI" status
    assert_success
    echo "$output" | grep -Eq '^broken +error'
    echo "$output" | grep -Eq '^demo +stock'
}

@test "lib/status.sh status_write_json is the writer of status.json" {
    # Stand-in for the slots/RAUC package's writer, in a private copy of the tree.
    src="$BATS_TEST_TMPDIR/src"
    mkdir -p "$src"
    cp -R "$REPO_ROOT/steamos-fixes.sh" "$REPO_ROOT/VERSION" "$REPO_ROOT/lib" "$REPO_ROOT/cmd" "$src/"
    cat >>"$src/lib/status.sh" <<'L'
status_write_json() {
    printf '{"writer":"lib/status.sh"}\n' | sof_atomic_write "$(sof_path "$SOF_STATUS_JSON_REL")"
}
L
    mkdir -p "$SOF_ROOT$STATE/state"
    run "$src/steamos-fixes.sh" status --json
    assert_success
    grep -q '"writer":"lib/status.sh"' "$SOF_ROOT$STATE/state/status.json"
}

@test "status shows each component's detail line and the JSON carries detail and applies" {
    run "$CLI" status
    assert_success
    echo "$output" | grep -Eq '^ +demo detail line$'
    run "$CLI" status --json
    assert_success
    printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/d.json"
    json_ok "$BATS_TEST_TMPDIR/d.json"
    [ "$(json_get "$BATS_TEST_TMPDIR/d.json" .components[0].detail)" = "demo detail line" ]
    [ "$(json_get "$BATS_TEST_TMPDIR/d.json" .components[0].applies)" = yes ]
}
