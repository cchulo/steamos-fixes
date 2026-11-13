# SPDX-License-Identifier: GPL-2.0-only
# Shared bats helper. Load with:  load '../test_helper'   (path relative to the .bats file)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SOF_SRC="$REPO_ROOT"
export PATH="$REPO_ROOT:$PATH"
CLI="$REPO_ROOT/steamos-fixes.sh"
export CLI

# make_root : create an empty fixture root and export SOF_ROOT to it. The
# real fixes/ are not discovered unless a test sets SOF_FIXES_DIR itself
# (the framework suites use throwaway components only).
make_root() {
    SOF_ROOT="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/sofroot.XXXXXX")"
    export SOF_ROOT
    mkdir -p "$SOF_ROOT/var/lib/steamos-fixes" "$SOF_ROOT/etc" "$SOF_ROOT/.nofixes"
    export SOF_FIXES_DIR="${SOF_FIXES_DIR:-$SOF_ROOT/.nofixes}"
    printf '%s\n' "$SOF_ROOT"
}

# fixture_file <abs-path-in-root> [content] : create a file inside SOF_ROOT.
fixture_file() {
    local p="$SOF_ROOT$1"
    mkdir -p "$(dirname "$p")"
    printf '%s' "${2:-fixture}" >"$p"
}

# source_libs : load the shell libraries into the test shell.
source_libs() {
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/common.sh"
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/manifest.sh"
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/probes.sh"
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/component.sh"
}

# assert_success / assert_failure / assert_output_contains : tiny subset of
# bats-assert so we do not need a submodule.
# shellcheck disable=SC2154  # status/output are set by bats' run
assert_success() {
    if [ "$status" -ne 0 ]; then
        printf 'expected success, got status %s\noutput:\n%s\n' "$status" "$output" >&2
        return 1
    fi
}
assert_failure() {
    if [ "$status" -eq 0 ]; then
        printf 'expected failure, got success\noutput:\n%s\n' "$output" >&2
        return 1
    fi
    if [ -n "${1:-}" ] && [ "$status" -ne "$1" ]; then
        printf 'expected status %s, got %s\noutput:\n%s\n' "$1" "$status" "$output" >&2
        return 1
    fi
}
assert_output_contains() {
    case "$output" in
        *"$1"*) return 0 ;;
    esac
    printf 'expected output to contain: %s\noutput:\n%s\n' "$1" "$output" >&2
    return 1
}
assert_equal() {
    if [ "$1" != "$2" ]; then
        printf 'expected: %s\nactual:   %s\n' "$2" "$1" >&2
        return 1
    fi
}
