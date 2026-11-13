#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# steamos-fixes — ROG Xbox Ally X20 support for stock SteamOS.
#
# Dispatcher only. Each sub-command lives in cmd/<name>.sh and defines
# cmd_<name_with_underscores>; `help` lists them from their "# summary:" line.
set -eu

SOF_SRC=$(cd "$(dirname "$(readlink "$0" 2>/dev/null || printf '%s' "$0")")" && pwd)
export SOF_SRC
# shellcheck source=lib/common.sh
. "$SOF_SRC/lib/common.sh"

usage() {
    cat <<USAGE
usage: $SOF_NAME [global options] <command> [args]

Global options:
  --root <dir>   operate on a fixture/mounted root instead of / (tests, other slot)
  --dry-run      print actions without performing them
  --verbose      debug logging
  --yes          assume yes on confirmations
  --i-know       proceed even if the root filesystem has been made writable
  --version      print version and exit
  -h, --help     this help

Run '$SOF_NAME help' for the list of commands.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --root)
            [ $# -ge 2 ] || die "--root needs a directory"
            SOF_ROOT=$2
            shift 2
            ;;
        --root=*)
            SOF_ROOT=${1#--root=}
            shift
            ;;
        --dry-run)
            SOF_DRY_RUN=1
            shift
            ;;
        --verbose | -v)
            SOF_VERBOSE=1
            shift
            ;;
        --yes | -y)
            SOF_ASSUME_YES=1
            shift
            ;;
        --i-know)
            SOF_I_KNOW=1
            shift
            ;;
        --version)
            sof_version
            exit 0
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*) die 2 "unknown global option: $1 (see --help)" ;;
        *) break ;;
    esac
done
case "${SOF_ROOT:-}" in */) SOF_ROOT=${SOF_ROOT%/} ;; esac
export SOF_ROOT SOF_DRY_RUN SOF_VERBOSE SOF_ASSUME_YES SOF_I_KNOW

if [ $# -eq 0 ]; then
    usage >&2
    exit 2
fi

cmd=$1
shift
case "$cmd" in
    *[!a-z0-9-]*) die 2 "unknown command: $cmd" ;;
esac
cmd_file="$SOF_SRC/cmd/$cmd.sh"
[ -f "$cmd_file" ] || die 2 "unknown command: $cmd (run '$SOF_NAME help')"
# shellcheck disable=SC1090
. "$cmd_file"
fn="cmd_$(printf '%s' "$cmd" | tr '-' '_')"
declare -F "$fn" >/dev/null 2>&1 || die "cmd/$cmd.sh does not define $fn"
"$fn" "$@"
