# SPDX-License-Identifier: GPL-2.0-only
# lib/common.sh — shared constants, logging, path helpers for steamos-fixes.
#
# Sourced by the CLI dispatcher, every cmd/*.sh, every components/*.sh and
# the test helper. Must stay compatible with bash 3.2 (macOS dev hosts) and
# bash 5 (SteamOS). No associative arrays, no mapfile, no ${var,,}.
#
# Path contract
# -------------
# Every filesystem path we touch is built from SOF_ROOT so that the whole
# tool can be exercised against a fixture tree in tests ("--root <dir>"):
#   sof_path /etc/modprobe.d/x.conf   ->  ${SOF_ROOT}/etc/modprobe.d/x.conf
# SOF_ROOT is empty on a real system. Never hard-code an absolute path
# without going through sof_path (a policy test greps for offenders).

if [ -n "${SOF_COMMON_LOADED:-}" ]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi
SOF_COMMON_LOADED=1

SOF_NAME="steamos-fixes"
export SOF_NAME

# Resolve the source checkout root (the directory holding steamos-fixes.sh).
if [ -z "${SOF_SRC:-}" ]; then
    _sof_lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    SOF_SRC=$(cd "${_sof_lib_dir}/.." && pwd)
    unset _sof_lib_dir
fi
export SOF_SRC

# Fixture root prefix. Empty on a live system. Normalised to have no
# trailing slash so "${SOF_ROOT}/etc" is always well formed.
SOF_ROOT="${SOF_ROOT:-}"
case "$SOF_ROOT" in
    */) SOF_ROOT="${SOF_ROOT%/}" ;;
esac
export SOF_ROOT

# Behavioural flags (set by the dispatcher from global options).
SOF_DRY_RUN="${SOF_DRY_RUN:-0}"
SOF_VERBOSE="${SOF_VERBOSE:-0}"
SOF_I_KNOW="${SOF_I_KNOW:-0}"
SOF_ASSUME_YES="${SOF_ASSUME_YES:-0}"
export SOF_DRY_RUN SOF_VERBOSE SOF_I_KNOW SOF_ASSUME_YES

# Canonical locations (all relative to SOF_ROOT; use sof_path to resolve).
SOF_STATE_REL="/var/lib/${SOF_NAME}"
# Files the kernel/udev need BEFORE /var and /home are mounted (the modprobe
# install helper, the staged .ko.zst). /etc is an
# overlay set up by the initramfs, so it exists when udev loads modules; its
# upper dir lives in the slot's var and is rsynced to the other slot on
# update. Measured on the ROG Xbox Ally X20 (ally-x20-steamos): a helper under /var/lib (-> /home) gave
# "No such file or directory" at udev time and no module loaded at all.
SOF_EARLY_REL="/etc/${SOF_NAME}"
SOF_OPT_REL="/opt/${SOF_NAME}"
SOF_MANIFEST_REL="${SOF_STATE_REL}/manifest"
SOF_STATUS_JSON_REL="${SOF_STATE_REL}/state/status.json"
SOF_LOG_REL="${SOF_STATE_REL}/log/${SOF_NAME}.log"
export SOF_STATE_REL SOF_EARLY_REL SOF_OPT_REL SOF_MANIFEST_REL SOF_STATUS_JSON_REL SOF_LOG_REL

# sof_path <absolute-path> : prefix with SOF_ROOT.
sof_path() {
    case "$1" in
        /*) printf '%s%s\n' "$SOF_ROOT" "$1" ;;
        *) printf '%s/%s\n' "$SOF_ROOT" "$1" ;;
    esac
}

sof_state_dir() { sof_path "$SOF_STATE_REL"; }

# Where the state really lives. SteamOS has a separate var-A/var-B partition
# per slot (256 MiB, rsynced across on update), so /var/lib/steamos-fixes
# is a symlink into the shared /home partition, like SteamOS's own
# /home/.steamos/offload. SOF_STATE_REL stays the canonical path everywhere.
SOF_STATE_REAL_REL="/home/.${SOF_NAME}"
export SOF_STATE_REAL_REL

# sof_state_dir_ensure : make sure the state dir exists on this root. If
# /var/lib/steamos-fixes is absent and the root has a /home, create the
# real directory under /home and the symlink; if a real directory is already
# there (older install, fixture roots) it is kept as is. Prints the path.
sof_state_dir_ensure() {
    local link real
    link=$(sof_state_dir)
    real=$(sof_path "$SOF_STATE_REAL_REL")
    if [ -L "$link" ] || [ -d "$link" ]; then
        printf '%s\n' "$link"
        return 0
    fi
    if [ -d "$(sof_path /home)" ]; then
        if [ "$SOF_DRY_RUN" = 1 ]; then
            printf '[dry-run] mkdir -p %s; ln -s ../..%s %s\n' "$real" "$SOF_STATE_REAL_REL" "$link" >&2
        else
            mkdir -p "$real" "$(dirname "$link")" || die "cannot create $real"
            # Relative, so it resolves inside a mounted slot or a fixture root too.
            ln -s "../..$SOF_STATE_REAL_REL" "$link" || die "cannot create symlink $link"
        fi
    else
        sof_mkdir_p "$link" >/dev/null
    fi
    printf '%s\n' "$link"
}
sof_manifest_file() { sof_path "$SOF_MANIFEST_REL"; }

# ---------------------------------------------------------------- logging --
_sof_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

_sof_log_to_file() {
    local f
    f=$(sof_path "$SOF_LOG_REL")
    if [ -d "$(dirname "$f")" ] && [ -w "$(dirname "$f")" ]; then
        printf '%s %s %s\n' "$(_sof_ts)" "$1" "$2" >>"$f" 2>/dev/null || true
    fi
}

log_info() {
    printf '%s: %s\n' "$SOF_NAME" "$*" >&2
    _sof_log_to_file INFO "$*"
}
log_warn() {
    printf '%s: warning: %s\n' "$SOF_NAME" "$*" >&2
    _sof_log_to_file WARN "$*"
}
log_error() {
    printf '%s: error: %s\n' "$SOF_NAME" "$*" >&2
    _sof_log_to_file ERROR "$*"
}
log_debug() {
    if [ "$SOF_VERBOSE" = 1 ]; then
        printf '%s: debug: %s\n' "$SOF_NAME" "$*" >&2
    fi
}
# die [exit-code] <message>
die() {
    local code=1
    case "$1" in
        '' | *[!0-9]*) ;;
        *)
            code=$1
            shift
            ;;
    esac
    log_error "$*"
    exit "$code"
}

# -------------------------------------------------------------- utilities --
sof_have() { command -v "$1" >/dev/null 2>&1; }

# sof_sha256 <file> : hex digest only. Works with coreutils and macOS.
# Reads via stdin: GNU sha256sum escapes file names containing a backslash
# or newline and prefixes the digest line with "\".
sof_sha256() {
    if sof_have sha256sum; then
        sha256sum <"$1" | cut -d' ' -f1
    elif sof_have shasum; then
        shasum -a 256 <"$1" | cut -d' ' -f1
    else
        die "no sha256 tool available"
    fi
}

# sof_sha256_string <string>
sof_sha256_string() {
    if sof_have sha256sum; then
        printf '%s' "$1" | sha256sum | cut -d' ' -f1
    else
        printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
    fi
}

# sof_version_ge <a> <b> : true if a >= b (dotted versions, sort -V).
sof_version_ge() {
    [ "$1" = "$2" ] && return 0
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# sof_is_root : true when running as uid 0.
sof_is_root() { [ "$(id -u)" = 0 ]; }

# require_root : die unless root, or unless operating on a fixture root
# (SOF_ROOT set) where privileges are meaningless.
require_root() {
    if [ -n "$SOF_ROOT" ] || [ "${SOF_ALLOW_UNPRIVILEGED:-0}" = 1 ]; then
        return 0
    fi
    sof_is_root || die "this command must run as root (try: sudo $SOF_NAME $*)"
}

# sof_run <cmd...> : execute, or print when dry-running.
sof_run() {
    if [ "$SOF_DRY_RUN" = 1 ]; then
        printf '[dry-run] %s\n' "$*" >&2
        return 0
    fi
    log_debug "run: $*"
    "$@"
}

# sof_mkdir_p <dir> : create directory chain; prints "created" if the leaf
# did not exist before (so callers can record created_dir in the manifest).
sof_mkdir_p() {
    if [ -d "$1" ]; then
        printf 'existed\n'
        return 0
    fi
    if [ "$SOF_DRY_RUN" = 1 ]; then
        printf '[dry-run] mkdir -p %s\n' "$1" >&2
        printf 'created\n'
        return 0
    fi
    mkdir -p "$1" || die "cannot create directory $1"
    printf 'created\n'
}

# sof_mkdir_p_list <dir> : like sof_mkdir_p, but prints every directory
# that had to be created, top-most first, one per line (nothing if all
# existed). Used by the manifest so uninstall can remove each of them again.
sof_mkdir_p_list() {
    local d=$1 missing="" out
    while [ -n "$d" ] && [ "$d" != / ] && [ ! -d "$d" ]; do
        missing="$d
$missing"
        d=$(dirname "$d")
    done
    [ -n "$missing" ] || return 0
    if [ "$SOF_DRY_RUN" = 1 ]; then
        printf '[dry-run] mkdir -p %s\n' "$1" >&2
    else
        mkdir -p "$1" || die "cannot create directory $1"
    fi
    out=$(printf '%s' "$missing" | grep -v '^$')
    printf '%s\n' "$out"
}

# sof_atomic_write <dest> [mode] : write stdin to dest via temp+rename.
sof_atomic_write() {
    local dest=$1 mode=${2:-0644} tmp
    if [ "$SOF_DRY_RUN" = 1 ]; then
        cat >/dev/null
        printf '[dry-run] write %s (mode %s)\n' "$dest" "$mode" >&2
        return 0
    fi
    tmp=$(mktemp "${dest}.XXXXXX") || die "cannot create temp file next to $dest"
    if ! cat >"$tmp"; then
        rm -f "$tmp"
        die "write to $dest failed"
    fi
    chmod "$mode" "$tmp"
    # Flush before the rename: a crash right after mv must not leave a
    # zero-filled file (measured on an Ally X20: a hard reboot during a write
    # padded the manifest with NUL bytes).
    sof_fsync "$tmp"
    mv -f "$tmp" "$dest" || {
        rm -f "$tmp"
        die "rename into $dest failed"
    }
    sof_fsync "$(dirname "$dest")"
}

# sof_fsync <path> : best-effort fsync of a file or directory. coreutils
# sync(1) accepts paths on Linux; macOS sync ignores arguments (then this is a
# whole-system sync, which is fine for a dev host).
sof_fsync() {
    sync "$1" 2>/dev/null || sync 2>/dev/null || true
}

# sof_copy_atomic <src> <dest> [mode]
sof_copy_atomic() {
    local src=$1 dest=$2 mode=${3:-0644}
    [ -f "$src" ] || die "source file missing: $src"
    sof_atomic_write "$dest" "$mode" <"$src"
}

# --------------------------------------------------- read-only root policy --
# SteamOS keeps / read-only. We never toggle it (policy test greps for the
# toggling commands). If someone else disabled it, stock files may have been
# altered by other tools, so refuse to operate unless --i-know was given.
sof_check_readonly_root() {
    local status_cmd="" state c
    # SteamOS 3.9 ships holo-readonly (steamos-readonly is the older name).
    for c in holo-readonly steamos-readonly; do
        if [ -x "$(sof_path "/usr/bin/$c")" ]; then
            status_cmd=$(sof_path "/usr/bin/$c")
            break
        fi
    done
    if [ -n "$SOF_ROOT" ]; then
        # Fixture roots: honour a marker file so tests can simulate both states.
        if [ -f "$(sof_path /.sof-readonly-disabled)" ]; then
            state=disabled
        else
            state=enabled
        fi
    elif [ -n "$status_cmd" ]; then
        state=$("$status_cmd" status 2>/dev/null || echo unknown)
    else
        # Not SteamOS (or fixture) – nothing to check.
        return 0
    fi
    case "$state" in
        *disabled*)
            if [ "$SOF_I_KNOW" = 1 ]; then
                log_warn "root filesystem is writable (read-only mode is off); continuing because --i-know was given"
                return 0
            fi
            die "root filesystem is writable (read-only mode is disabled). $SOF_NAME never needs this and refuses to run in that state; re-enable read-only mode, or pass --i-know if you understand the risk"
            ;;
    esac
    return 0
}

# sof_version : the repo version (VERSION file + git describe when available).
sof_version() {
    local v
    v=$(cat "$SOF_SRC/VERSION" 2>/dev/null || echo unknown)
    if sof_have git && git -C "$SOF_SRC" rev-parse --short HEAD >/dev/null 2>&1; then
        v="$v ($(git -C "$SOF_SRC" rev-parse --short HEAD))"
    fi
    printf '%s\n' "$v"
}
