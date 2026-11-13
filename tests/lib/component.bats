#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
load '../test_helper'

setup() {
    make_root >/dev/null
    source_libs
    # A throwaway component tree so the suite does not depend on real components.
    export SOF_COMPONENTS_DIR="$BATS_TEST_TMPDIR/components"
    mkdir -p "$SOF_COMPONENTS_DIR" "$BATS_TEST_TMPDIR/overlay/demo"
    printf 'demo file\n' >"$BATS_TEST_TMPDIR/overlay/demo/demo.conf"
    # Point overlay lookups at the temp overlay by overriding SOF_SRC/overlay via symlink.
    export SOF_SRC="$BATS_TEST_TMPDIR/src"
    mkdir -p "$SOF_SRC"
    ln -s "$REPO_ROOT/lib" "$SOF_SRC/lib"
    ln -s "$BATS_TEST_TMPDIR/overlay" "$SOF_SRC/overlay"
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
demo_apply() { touch "$(sof_path /var/lib/steamos-fixes/demo-applied)"; }
C
}

@test "component_list and description" {
    [ "$(component_list)" = demo ]
    [ "$(component_description demo)" = "demo component" ]
}

@test "component_load rejects malformed components" {
    printf 'COMPONENT_DESCRIPTION=x\n' >"$SOF_COMPONENTS_DIR/bad.sh"
    run component_load bad
    assert_failure
    assert_output_contains "bad_probe"
}

@test "status is stock before apply, active after, superseded when probe says so" {
    [ "$(component_status demo)" = stock ]
    component_apply demo
    [ -f "$SOF_ROOT/etc/demo.d/steamos-fixes.conf" ]
    [ -f "$SOF_ROOT/var/lib/steamos-fixes/demo-applied" ]
    [ "$(component_status demo)" = active ]
    fixture_file /usr/share/demo-native
    [ "$(component_status demo)" = superseded ]
}

@test "status is n/a when probe is unknown and nothing installed" {
    fixture_file /usr/share/demo-unknown
    [ "$(component_status demo)" = n/a ]
}

@test "drifted install reports stock (needs re-apply)" {
    component_apply demo
    printf 'tampered' >"$SOF_ROOT/etc/demo.d/steamos-fixes.conf"
    [ "$(component_status demo)" = stock ]
}

@test "component_apply is idempotent" {
    component_apply demo
    component_apply demo
    [ "$(manifest_paths demo | grep -c 'steamos-fixes.conf')" = 1 ]
}

# --- fixes/<name>/component.sh -------------------------------------------

make_fix() {
    # make_fix <dir-name> <applies-rc> : a fix under a throwaway fixes dir.
    export SOF_FIXES_DIR="$BATS_TEST_TMPDIR/fixes"
    mkdir -p "$SOF_FIXES_DIR/$1"
    local fn
    fn=$(printf '%s' "$1" | tr '-' '_')
    cat >"$SOF_FIXES_DIR/$1/component.sh" <<C
COMPONENT_DESCRIPTION="fix $1"
${fn}_files() { printf 'demo/demo.conf\t/etc/demo.d/steamos-fixes-$1.conf\t0644\n'; }
${fn}_applies() { printf 'hardware check for $1\n'; return $2; }
${fn}_probe() { return 1; }
${fn}_status_detail() { printf 'detail of $1\n'; }
C
}

@test "fixes/<dir>/component.sh is discovered next to components/, dashes become underscores" {
    make_fix hdmi-demo 0
    [ "$(component_list | tr '\n' ' ')" = "demo hdmi_demo " ]
    component_exists hdmi_demo
    component_is_fix hdmi_demo
    ! component_is_fix demo || false
    [ "$(component_description hdmi_demo)" = "fix hdmi-demo" ]
    [ "$(component_status_detail hdmi_demo)" = "detail of hdmi-demo" ]
    [ -z "$(component_status_detail demo)" ]
}

@test "a fix must declare which hardware it applies to" {
    make_fix bare 0
    sed -i.bak '/_applies/d' "$SOF_FIXES_DIR/bare/component.sh"
    run component_load bare
    assert_failure
    assert_output_contains "bare_applies"
}

@test "a fix that does not apply here is n/a; a framework component always applies" {
    make_fix other-hw 1
    run component_applies other_hw
    [ "$status" -eq 1 ]
    assert_output_contains "hardware check for other-hw"
    [ "$(component_status other_hw)" = n/a ]
    run component_applies demo
    [ "$status" -eq 0 ]
    make_fix this-hw 0
    [ "$(component_status this_hw)" = stock ]
    component_apply this_hw
    [ "$(component_status this_hw)" = active ]
}
