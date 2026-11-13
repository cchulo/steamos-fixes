# SPDX-License-Identifier: GPL-2.0-only
# lib/modules.sh — version-gated substitution of the patched kernel modules.
#
# Plan §3, §4.2c, §4.3, §4.5. The patched modules for kernel <kver> live in
#   /etc/steamos-fixes/modules/<kver>/{<module>.ko.zst,BUILD-INFO}
# and are loaded by the modprobe.d `install` hooks through
#   /etc/steamos-fixes/load-or-fallback  (must exist at udev time: /etc, not /var)
# only when `uname -r` has a matching directory; otherwise stock modules load.
#
# The module set is never hard-coded: it comes from the machine-readable
# lists patches/kernel/modules*.list, one line per patch:
#   <patch-file> <TAB> <make M= dir> <TAB> <ko name>
# Blank lines and lines starting with '#' are ignored. Several patches may
# name the same module (they are applied in file-name order).
#
# Path convention: functions that print a location print it WITHOUT the
# SOF_ROOT prefix (like manifest paths); resolve with sof_path.
#
# Failure policy: modules_resolve and its helpers log and return non-zero,
# they never die, because the boot service and the RAUC hook must carry on
# with stock modules when no patched build is available.

# shellcheck source=lib/common.sh
. "${SOF_SRC:-$(dirname "${BASH_SOURCE[0]}")/..}/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$SOF_SRC/lib/manifest.sh"
# shellcheck source=lib/probes.sh
. "$SOF_SRC/lib/probes.sh"
# shellcheck source=lib/slots.sh
. "$SOF_SRC/lib/slots.sh"

SOF_MODULES_REL="${SOF_EARLY_REL}/modules"
SOF_MODULES_CACHE_REL="${SOF_STATE_REL}/cache"
SOF_HELPER_REL="${SOF_EARLY_REL}/load-or-fallback"
SOF_MODPROBE_CONF_REL="/etc/modprobe.d/${SOF_NAME}-modules.conf"
SOF_MODULES_COMPONENT=modules
# Release assets: <base>/modules-<kver>.tar.zst and .sha256. CI attaches every
# kernel in build/kernels.txt to every release, so "latest" always works.
SOF_MODULES_RELEASE_URL="${SOF_MODULES_RELEASE_URL:-https://github.com/cchulo/${SOF_NAME}/releases/latest/download}"
# The release of this checkout's VERSION is tried before "latest": a newer
# release's artifact may be built from other patches and would be refused.
SOF_MODULES_RELEASE_BASE="${SOF_MODULES_RELEASE_BASE:-https://github.com/cchulo/${SOF_NAME}/releases/download}"
# The stock initramfs of a slot and our early-initrd override next to the
# slot's grub.cfg (see "modules loaded from the initramfs" below). The
# initramfs is named after the kernel package: initramfs-linux-neptune-72.img
# on SteamOS 3.9 (measured on a Steam Machine), initramfs-linux-neptune.img
# on older images; SOF_INITRAMFS_REL pins it, otherwise it is found by glob.
SOF_INITRAMFS_REL="${SOF_INITRAMFS_REL:-}"
SOF_OVERRIDE_INITRD_REL="${SLOTS_GRUB_DIR_REL}/${SOF_NAME}-modules.img"
export SOF_MODULES_REL SOF_MODULES_CACHE_REL SOF_HELPER_REL SOF_MODPROBE_CONF_REL
export SOF_INITRAMFS_REL SOF_OVERRIDE_INITRD_REL

# modules_patches_dir : where the patches and modules*.list files live.
modules_patches_dir() {
    printf '%s\n' "${SOF_PATCHES_DIR:-$SOF_SRC/patches/kernel}"
}

# modules_list_files : the list files, sorted (may print nothing).
modules_list_files() {
    local f
    for f in "$(modules_patches_dir)"/modules*.list; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    return 0
}

# modules_list_entries : normalised "<patch>\t<mdir>\t<ko>" lines from every
# list. <ko> loses any .ko/.ko.zst suffix, <mdir> any leading ./ or trailing /.
# Returns 1 (after logging) on a malformed line.
modules_list_entries() {
    local f
    for f in $(modules_list_files); do
        awk -v file="$f" '
            /^[ \t]*(#|$)/ { next }
            {
                if (NF != 3) {
                    printf "%s:%d: expected 3 fields (patch, M= dir, ko name), got %d\n", file, NR, NF > "/dev/stderr"
                    bad = 1; exit 1
                }
                p = $1; m = $2; k = $3
                sub(/^\.\//, "", m); sub(/\/+$/, "", m)
                sub(/\.ko(\.zst|\.xz|\.gz)?$/, "", k)
                if (m ~ /^\// || m ~ /(^|\/)\.\.(\/|$)/ || p ~ /\// || k ~ /\//) {
                    printf "%s:%d: unsafe entry\n", file, NR > "/dev/stderr"
                    bad = 1; exit 1
                }
                printf "%s\t%s\t%s\n", p, m, k
            }
            END { exit bad }
        ' "$f" || {
            log_error "malformed module list: $f"
            return 1
        }
    done
}

# modules_list_names : distinct module names, sorted.
modules_list_names() {
    local entries
    entries=$(modules_list_entries) || return 1
    [ -n "$entries" ] || return 0
    printf '%s\n' "$entries" | cut -f3 | sort -u
}

# modules_dir_for <kver>
modules_dir_for() {
    printf '%s/%s\n' "$SOF_MODULES_REL" "$1"
}

# modules_build_info_get <file> <key> : value of "key=value" (first match).
modules_build_info_get() {
    [ -f "$1" ] || return 1
    awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); found = 1; exit } END { exit !found }' "$1"
}

# _modules_has_module <build-dir> <name> : the build provides the module, or
# records it as superseded (every patch for it is already in Valve's tree,
# so the stock module is the right one and no .ko.zst is shipped).
_modules_has_module() {
    [ -s "$1/$2.ko.zst" ] && return 0
    [ "$(modules_build_info_get "$1/BUILD-INFO" "module.$2" 2>/dev/null)" = superseded ]
}

# modules_superseded_names <kver> : modules the staged build marks superseded.
modules_superseded_names() {
    local f
    f="$(sof_path "$(modules_dir_for "$1")")/BUILD-INFO"
    [ -f "$f" ] || return 0
    sed -n 's/^module\.\([^=]*\)=superseded$/\1/p' "$f" | sort -u
}

# modules_all_superseded <kver> : the staged build for kver marks every
# listed module superseded (Valve's kernel already carries all our patches).
modules_all_superseded() {
    local names n sup
    names=$(modules_list_names) || return 1
    [ -n "$names" ] || return 1
    sup=$(modules_superseded_names "$1")
    for n in $names; do
        printf '%s\n' "$sup" | grep -Fxq -- "$n" || return 1
    done
    return 0
}

# modules_build_matches_patches <build-dir> : the build was made from the
# patches this checkout ships. BUILD-INFO records patch.<name>=<sha256> for
# every patch it applied (build/build-modules.sh); each listed patch must be
# there with the checkout's hash. Without that check a release that changes
# only a patch (ally-x20-steamos v0.1.7) kept loading the previous build,
# because the kernel version had not changed. Prints the first mismatch.
modules_build_matches_patches() {
    local dir=$1 entries p want got
    entries=$(modules_list_entries) || return 1
    for p in $(printf '%s\n' "$entries" | cut -f1 | sort -u); do
        want=$(sof_sha256 "$(modules_patches_dir)/$p" 2>/dev/null || true)
        got=$(modules_build_info_get "$dir/BUILD-INFO" "patch.$p" 2>/dev/null || true)
        if [ -z "$got" ]; then
            printf '%s: not in the build\n' "$p"
            return 1
        fi
        if [ "$got" != "$want" ]; then
            printf '%s: built from a different version of the patch\n' "$p"
            return 1
        fi
    done
    return 0
}

# modules_available <kver> : 0 if a complete staged build exists for kver,
# made from this checkout's patches.
modules_available() {
    local kver=$1 dir names n
    dir=$(sof_path "$(modules_dir_for "$kver")")
    [ -f "$dir/BUILD-INFO" ] || return 1
    [ "$(modules_build_info_get "$dir/BUILD-INFO" kver)" = "$kver" ] || return 1
    names=$(modules_list_names) || return 1
    [ -n "$names" ] || return 1
    for n in $names; do
        _modules_has_module "$dir" "$n" || return 1
    done
    modules_build_matches_patches "$dir" >/dev/null || return 1
    return 0
}

# modules_staged_stale <kver> : a build is staged for kver but not from this
# checkout's patches; prints why.
modules_staged_stale() {
    local dir
    dir=$(sof_path "$(modules_dir_for "$1")")
    [ -f "$dir/BUILD-INFO" ] || return 1
    [ "$(modules_build_info_get "$dir/BUILD-INFO" kver)" = "$1" ] || return 1
    ! modules_build_matches_patches "$dir"
}

# modules_validate_build_dir <kver> <dir> : the directory holds a build for
# kver with every listed module.
modules_validate_build_dir() {
    local kver=$1 src=$2 names n got why
    if [ ! -f "$src/BUILD-INFO" ]; then
        log_error "no BUILD-INFO in $src"
        return 1
    fi
    got=$(modules_build_info_get "$src/BUILD-INFO" kver || true)
    if [ "$got" != "$kver" ]; then
        log_error "BUILD-INFO in $src is for kernel '$got', not '$kver'"
        return 1
    fi
    names=$(modules_list_names) || return 1
    if [ -z "$names" ]; then
        log_error "no modules are listed in $(modules_patches_dir)/modules*.list"
        return 1
    fi
    for n in $names; do
        if ! _modules_has_module "$src" "$n"; then
            log_error "build in $src lacks $n.ko.zst"
            return 1
        fi
    done
    if ! why=$(modules_build_matches_patches "$src"); then
        log_warn "build in $src does not match this checkout's patches ($why); not staging it"
        return 1
    fi
    return 0
}

# _modules_forget_under <rel-dir> : drop manifest entries below a directory.
_modules_forget_under() {
    local p
    for p in $(manifest_paths "$SOF_MODULES_COMPONENT"); do
        case "$p" in
            "$1"/*) manifest_forget "$p" ;;
        esac
    done
}

# modules_ensure_base_dir : create /etc/steamos-fixes/modules, recorded.
modules_ensure_base_dir() {
    local base state
    base=$(sof_path "$SOF_MODULES_REL")
    state=$(sof_mkdir_p "$base")
    if [ "$state" = created ]; then
        manifest_record "$SOF_MODULES_REL" "$SOF_MODULES_COMPONENT" dir "" shared false
    fi
}

# modules_stage <kver> <src-dir> : install <src-dir>/{*.ko.zst,BUILD-INFO} as
# the build for kver. The new directory is assembled next to the final one
# and renamed into place, so a reader sees the old set or the new set.
modules_stage() {
    local kver=$1 src=$2 rel dir base tmp old f
    case "$kver" in
        '' | */* | .*)
            log_error "modules_stage: bad kernel version '$kver'"
            return 1
            ;;
    esac
    modules_validate_build_dir "$kver" "$src" || return 1
    rel=$(modules_dir_for "$kver")
    dir=$(sof_path "$rel")
    base=$(dirname "$dir")
    if [ "$SOF_DRY_RUN" = 1 ]; then
        printf '[dry-run] stage %s -> %s\n' "$src" "$dir" >&2
        return 0
    fi
    modules_ensure_base_dir
    tmp=$(mktemp -d "$base/.stage.XXXXXX") || return 1
    for f in "$src"/*.ko.zst "$src/BUILD-INFO"; do
        [ -f "$f" ] || continue
        if ! cp "$f" "$tmp/"; then
            rm -rf "$tmp"
            log_error "copy of $f failed"
            return 1
        fi
    done
    chmod 0755 "$tmp"
    chmod 0644 "$tmp"/*
    old=""
    if [ -d "$dir" ]; then
        old="$base/.old.$kver.$$"
        rm -rf "$old"
        mv "$dir" "$old" || {
            rm -rf "$tmp"
            return 1
        }
    fi
    if ! mv "$tmp" "$dir"; then
        [ -n "$old" ] && mv "$old" "$dir"
        rm -rf "$tmp"
        log_error "could not move staged modules into $dir"
        return 1
    fi
    [ -n "$old" ] && rm -rf "$old"
    _modules_forget_under "$rel"
    manifest_record "$rel" "$SOF_MODULES_COMPONENT" dir "" shared false
    for f in "$dir"/*; do
        manifest_record "$rel/$(basename "$f")" "$SOF_MODULES_COMPONENT" file "$(sof_sha256 "$f")" shared false
    done
    log_info "staged patched modules for $kver"
}

# modules_lockdown_active : 0 if kernel lockdown (integrity/confidentiality)
# is in force, in which case our unsigned modules can never load.
modules_lockdown_active() {
    local f
    f=$(sof_path /sys/kernel/security/lockdown)
    [ -r "$f" ] || return 1
    grep -Eq '\[(integrity|confidentiality)\]' "$f"
}

# modules_render_modprobe_conf : the modprobe.d drop-in, one install hook per
# listed module. Generated from the lists so it can never drift from them.
modules_render_modprobe_conf() {
    local names n helper
    names=$(modules_list_names) || return 1
    helper=$SOF_HELPER_REL
    printf '# Generated by %s (component modules) from patches/kernel/modules*.list.\n' "$SOF_NAME"
    printf '# Loads the patched build for the running kernel when one exists in\n'
    printf '# %s/<uname -r>/, otherwise the stock module.\n' "$SOF_MODULES_REL"
    printf '# Do not edit: re-run "%s apply" instead.\n' "$SOF_NAME"
    for n in $names; do
        # $CMDLINE_OPTS is expanded by modprobe itself, not by us. The inner
        # "|| exec modprobe --ignore-install" guarantees the stock module
        # still loads if the helper is missing or fails for any reason
        # (exit 127 at early boot must never leave the device driverless).
        # shellcheck disable=SC2016
        printf 'install %s /bin/sh -c '"'"'%s %s "$@" || exec modprobe --ignore-install %s "$@"'"'"' -- $CMDLINE_OPTS\n' "$n" "$helper" "$n" "$n"
    done
}

# ----------------------------------------------------------- resolution --

# modules_online : best-effort connectivity check (SOF_OFFLINE=1 forces off).
modules_online() {
    [ "${SOF_OFFLINE:-0}" = 1 ] && return 1
    sof_have curl || return 1
    curl -fsS --max-time 5 -o /dev/null -I https://github.com >/dev/null 2>&1
}

# _modules_fetch <url> <dest> : download (stubbed in tests).
_modules_fetch() {
    sof_have curl || return 1
    curl -fsSL --retry 3 --connect-timeout 10 -o "$2" "$1"
}

# modules_detect_channel : SteamOS package repo searched first for headers.
# SOF_CHANNEL wins. Otherwise the branch (steamos-atomupd preferences.conf
# "Branch=", or the older /var/lib/steamos-branch) decides: a stable/rel
# device reads its per-release repo from VERSION_ID in /etc/os-release
# (3.9.5 -> jupiter-3.9, where the stable kernel actually lives; jupiter-rel
# only has very old kernels), staging -> jupiter-staging, anything else ->
# jupiter-main. The build script searches the other repos too, so this only
# sets the order.
modules_detect_channel() {
    local branch="" f vid=""
    if [ -n "${SOF_CHANNEL:-}" ]; then
        printf '%s\n' "$SOF_CHANNEL"
        return 0
    fi
    f=$(sof_path /etc/steamos-atomupd/preferences.conf)
    if [ -r "$f" ]; then
        branch=$(sed -n 's/^[Bb]ranch *= *//p' "$f" | head -n1 | tr -d ' \r')
    fi
    if [ -z "$branch" ]; then
        for f in /var/lib/steamos-branch /etc/steamos-branch; do
            if [ -r "$(sof_path "$f")" ]; then
                branch=$(tr -d ' \n' <"$(sof_path "$f")")
                break
            fi
        done
    fi
    f=$(sof_path /etc/os-release)
    [ -r "$f" ] && vid=$(sed -n 's/^VERSION_ID=//p' "$f" | tr -d '"' | head -n1)
    case "$branch" in
        staging) printf 'jupiter-staging\n' ;;
        main | beta | bc | preview | pc) printf 'jupiter-main\n' ;;
        *)
            case "$vid" in
                [0-9]*.[0-9]*) printf 'jupiter-%s\n' "$(printf '%s' "$vid" | cut -d. -f1,2)" ;;
                *) printf 'jupiter-main\n' ;;
            esac
            ;;
    esac
}

# _modules_sha256_file_ok <file> <sha256-file>
_modules_sha256_file_ok() {
    local want got
    want=$(awk 'NR == 1 { print $1 }' "$2" 2>/dev/null)
    [ -n "$want" ] || return 1
    got=$(sof_sha256 "$1")
    [ "$want" = "$got" ]
}

# _modules_install_tarball <kver> <tar.zst> : verify layout, extract, stage.
_modules_install_tarball() {
    local kver=$1 tarball=$2 x listing bad
    sof_have zstd || {
        log_warn "zstd not available; cannot unpack $tarball"
        return 1
    }
    listing=$(zstd -dc "$tarball" 2>/dev/null | tar -tf - 2>/dev/null) || {
        log_warn "$tarball is not a valid tar.zst"
        return 1
    }
    bad=$(printf '%s\n' "$listing" | awk -v k="$kver" '
        { sub(/^\.\//, "") }
        $0 == "" || $0 == k || $0 == k "/" { next }
        index($0, k "/") != 1 || $0 ~ /(^|\/)\.\.(\/|$)/ || $0 ~ /^\// { print; exit }')
    if [ -n "$bad" ]; then
        log_warn "$tarball contains an unexpected entry: $bad"
        return 1
    fi
    x=$(mktemp -d "${TMPDIR:-/tmp}/sof-modules.XXXXXX") || return 1
    if ! zstd -dc "$tarball" | tar -xf - -C "$x"; then
        rm -rf "$x"
        return 1
    fi
    if ! modules_stage "$kver" "$x/$kver"; then
        rm -rf "$x"
        return 1
    fi
    rm -rf "$x"
}

# _modules_artifact_dir : where downloaded release artifacts are kept.
_modules_artifact_dir() {
    sof_path "$SOF_MODULES_CACHE_REL/artifacts"
}

# _modules_try_cache <kver>
_modules_try_cache() {
    local kver=$1 a
    if [ "${SOF_MODULES_FORCE:-0}" != 1 ]; then
        modules_available "$kver" && return 0
    fi
    a="$(_modules_artifact_dir)/modules-$kver.tar.zst"
    [ -f "$a" ] && [ -f "$a.sha256" ] || return 1
    if ! _modules_sha256_file_ok "$a" "$a.sha256"; then
        log_warn "cached artifact $a fails its checksum; ignoring it"
        return 1
    fi
    _modules_install_tarball "$kver" "$a"
}

# _modules_release_urls : download bases to try, one per line: the release
# matching this checkout's VERSION (when the file exists), then "latest".
_modules_release_urls() {
    local v
    if [ -f "$SOF_SRC/VERSION" ]; then
        v=$(tr -d '[:space:]' <"$SOF_SRC/VERSION")
        [ -n "$v" ] && printf '%s/v%s\n' "${SOF_MODULES_RELEASE_BASE%/}" "$v"
    fi
    printf '%s\n' "${SOF_MODULES_RELEASE_URL%/}"
}

# _modules_try_release <kver>
_modules_try_release() {
    local kver=$1 name url dir tmp base
    modules_online || {
        log_info "offline: skipping release download for $kver"
        return 1
    }
    name="modules-$kver.tar.zst"
    dir=$(_modules_artifact_dir)
    if [ "$SOF_DRY_RUN" = 1 ]; then
        printf '[dry-run] download %s\n' "$(_modules_release_urls | head -n1)/$name" >&2
        return 1
    fi
    mkdir -p "$dir" || return 1
    tmp=$(mktemp -d "$dir/.dl.XXXXXX") || return 1
    url=""
    for base in $(_modules_release_urls); do
        if _modules_fetch "$base/$name.sha256" "$tmp/$name.sha256" && _modules_fetch "$base/$name" "$tmp/$name"; then
            url="$base/$name"
            break
        fi
        log_debug "no release artifact at $base/$name"
    done
    if [ -z "$url" ]; then
        log_info "no release artifact for $kver (tried: $(_modules_release_urls | tr '\n' ' '))"
        rm -rf "$tmp"
        return 1
    fi
    if ! _modules_sha256_file_ok "$tmp/$name" "$tmp/$name.sha256"; then
        log_warn "release artifact for $kver fails its checksum"
        rm -rf "$tmp"
        return 1
    fi
    mv -f "$tmp/$name" "$tmp/$name.sha256" "$dir/" && rm -rf "$tmp"
    _modules_install_tarball "$kver" "$dir/$name"
}

# _modules_build_uid : uid the container build runs as for rootful podman.
_modules_build_uid() { printf '%s\n' "${SOF_BUILD_UID:-1000}"; }

# modules_container_build <kver> <channel> <out-dir> : run build/Containerfile
# with build/build-modules.sh as entrypoint. Rootless when invoked as a user
# (image cached in ~/.local/share/containers); rootful under the boot service
# (image cached in /var/lib/containers). Both live on /var or /home and
# survive SteamOS updates. TODO(vm): measure rootful podman on SteamOS.
modules_container_build() {
    local kver=$1 channel=$2 out=$3 image cache digest vmlinuz commit
    sof_have podman || return 1
    image=${SOF_BUILD_IMAGE:-localhost/${SOF_NAME}-build:latest}
    cache=$(sof_path "$SOF_MODULES_CACHE_REL/build")
    commit=$(git -C "$SOF_SRC" rev-parse HEAD 2>/dev/null || echo unknown)
    sof_run mkdir -p "$cache" "$out" || return 1
    sof_run podman build -t "$image" -f "$SOF_SRC/build/Containerfile" "$SOF_SRC/build" || return 1
    digest=$(podman image inspect --format '{{.Digest}}' "$image" 2>/dev/null || echo unknown)
    set -- podman run --rm --security-opt label=disable \
        -v "$SOF_SRC:/src:ro" -v "$cache:/cache" -v "$out:/out" \
        -e "KVER=$kver" -e "CHANNEL=$channel" -e OUT_DIR=/out -e CACHE_DIR=/cache \
        -e PATCHES_DIR=/src/patches/kernel -e HOME=/tmp -e "SOF_COMMIT=$commit" \
        -e "CONTAINER_IMAGE=$image" -e "CONTAINER_IMAGE_DIGEST=$digest"
    if sof_is_root; then
        sof_run chown -R "$(_modules_build_uid)" "$cache" "$out" || return 1
        set -- "$@" --user "$(_modules_build_uid)"
    else
        set -- "$@" --userns=keep-id
    fi
    vmlinuz=$(sof_path "/usr/lib/modules/$kver/vmlinuz")
    if [ -f "$vmlinuz" ]; then
        set -- "$@" -v "$vmlinuz:/vmlinuz:ro" -e VMLINUZ=/vmlinuz
    fi
    sof_run "$@" "$image"
}

# _modules_try_container <kver> <channel>
_modules_try_container() {
    local kver=$1 channel=$2 out rc
    sof_have podman || {
        log_info "podman not available: skipping container build for $kver"
        return 1
    }
    modules_online || {
        log_info "offline: skipping container build for $kver"
        return 1
    }
    [ -n "$channel" ] || channel=$(modules_detect_channel)
    out=$(sof_path "$SOF_MODULES_CACHE_REL/build-out/$kver")
    rm -rf "$out"
    log_info "building patched modules for $kver in a container (channel $channel); this takes a few minutes"
    rc=0
    modules_container_build "$kver" "$channel" "$out" || rc=$?
    if [ "$rc" != 0 ]; then
        log_warn "container build for $kver failed (exit $rc)"
        return 1
    fi
    [ "$SOF_DRY_RUN" = 1 ] && return 0
    modules_stage "$kver" "$out/$kver"
}

# _modules_try_source <cache|release|container> <kver> <channel>
_modules_try_source() {
    case "$1" in
        cache) _modules_try_cache "$2" ;;
        release) _modules_try_release "$2" ;;
        container) _modules_try_container "$2" "$3" ;;
        *) return 2 ;;
    esac
}

# modules_resolve <kver> [--source cache|release|container] [--channel <c>]
# Makes modules for kver available, trying cache -> release -> container (or
# only the named source). Prints the source that succeeded. Returns 1 after
# logging when nothing worked; never dies.
modules_resolve() {
    local kver=$1 only="" channel="" order m
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --source)
                only=${2:-}
                shift 2 || return 2
                ;;
            --channel)
                channel=${2:-}
                shift 2 || return 2
                ;;
            *)
                log_error "modules_resolve: unknown argument '$1'"
                return 2
                ;;
        esac
    done
    case "$only" in
        '') order="cache release container" ;;
        cache | release | container) order=$only ;;
        *)
            log_error "unknown module source '$only' (cache|release|container)"
            return 2
            ;;
    esac
    for m in $order; do
        if _modules_try_source "$m" "$kver" "$channel"; then
            printf '%s\n' "$m"
            return 0
        fi
    done
    log_warn "no patched modules for kernel $kver (tried: $order); stock modules will be used"
    return 1
}

# ------------------------------------------- modules in the initramfs --
# A module that the initramfs loads is already in the kernel when the root
# filesystem's modprobe.d is read, so the install hook never runs for it
# (load-or-fallback exits 0 when /sys/module/<mod> exists, on purpose).
# SteamOS 3.9 builds its initramfs with the hooks "base udev plymouth holo
# steam-deck modconf keyboard block filesystems resume", whose module list
# has no amdgpu; measured on the device, not assumed (docs/kernel-modules.md).
# For a listed module that *is* in the initramfs, the staged .ko is packed
# into an uncompressed newc cpio placed after the stock initramfs in the
# boot entry (lib/slots.sh): the kernel extracts the archives in order, so
# our file replaces the stock one at the same path before udev loads it.

# modules_initramfs_file [kver] : the root-relative stock initramfs, if
# present: SOF_INITRAMFS_REL, else /boot/initramfs-linux-neptune*.img,
# preferring the one whose suffix matches the kernel flavour (neptune-72)
# when several exist.
modules_initramfs_file() {
    local kver=${1:-} flavour="" f best=""
    if [ -n "$SOF_INITRAMFS_REL" ]; then
        [ -f "$(sof_path "$SOF_INITRAMFS_REL")" ] || return 1
        printf '%s\n' "$SOF_INITRAMFS_REL"
        return 0
    fi
    [ -n "$kver" ] || kver=$(probe_running_kver 2>/dev/null || true)
    # 7.2.7-valve2-2-neptune-72-g... -> neptune-72
    flavour=$(printf '%s' "$kver" | sed -n 's/.*-\(neptune[-0-9]*\)\(-g[0-9a-f]*\)\{0,1\}$/\1/p')
    for f in "$(sof_path /boot)"/initramfs-linux-neptune*.img; do
        [ -f "$f" ] || continue
        f=${f#"$SOF_ROOT"}
        case "$f" in
            *-fallback.img) continue ;;
        esac
        if [ -n "$flavour" ] && [ "$f" = "/boot/initramfs-linux-$flavour.img" ]; then
            printf '%s\n' "$f"
            return 0
        fi
        [ -n "$best" ] || best=$f
    done
    [ -n "$best" ] || return 1
    printf '%s\n' "$best"
}

# _modules_decompress <file> : the archive on stdout, whatever it is
# compressed with (zstd, gzip, xz, lz4 or none), by magic bytes.
_modules_decompress() {
    local magic
    magic=$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')
    case "$magic" in
        28b52ffd) zstd -dc "$1" ;;
        1f8b*) gzip -dc "$1" ;;
        fd377a58) xz -dc "$1" ;;
        04224d18) lz4 -dc "$1" ;;
        *) cat "$1" ;;
    esac
}

# modules_initramfs_list <abs-file> : the archive's member paths, one per
# line, without a leading "./". Uses lsinitcpio (mkinitcpio) when present,
# else bsdtar, else a decompress | cpio -t pipeline. Returns 1 when none of
# them can read the file.
modules_initramfs_list() {
    local f=$1 out
    [ -f "$f" ] || return 1
    if sof_have lsinitcpio; then
        out=$(lsinitcpio "$f" 2>/dev/null) && [ -n "$out" ] && {
            printf '%s\n' "$out" | sed 's|^\./||'
            return 0
        }
    fi
    if sof_have bsdtar; then
        out=$(bsdtar -tf "$f" 2>/dev/null) && [ -n "$out" ] && {
            printf '%s\n' "$out" | sed 's|^\./||'
            return 0
        }
    fi
    if sof_have cpio; then
        out=$(_modules_decompress "$f" 2>/dev/null | cpio -t 2>/dev/null) && [ -n "$out" ] && {
            printf '%s\n' "$out" | sed 's|^\./||'
            return 0
        }
    fi
    return 1
}

# modules_in_initramfs <module> [initramfs-abs] : prints the member path of
# the module inside the initramfs (e.g. usr/lib/modules/<kver>/kernel/.../
# amdgpu.ko.zst). 0 found, 1 not in the initramfs, 2 cannot tell (no
# initramfs, or no tool can list it).
modules_in_initramfs() {
    local mod=$1 img=${2:-} listing re hit
    if [ -z "$img" ]; then
        img=$(modules_initramfs_file) || return 2
        img=$(sof_path "$img")
    fi
    listing=$(modules_initramfs_list "$img") || return 2
    # kmod treats - and _ alike in module names.
    re=$(printf '%s' "$mod" | sed 's/[-_]/[-_]/g')
    hit=$(printf '%s\n' "$listing" | grep -E "(^|/)${re}\.ko(\.zst|\.xz|\.gz)?\$" | head -n1)
    [ -n "$hit" ] || return 1
    printf '%s\n' "$hit"
}

# modules_initramfs_members <kver> : "<module>\t<member path>" for every
# listed module that the initramfs carries (nothing when none does or the
# initramfs cannot be read).
modules_initramfs_members() {
    local names n p
    names=$(modules_list_names) || return 1
    for n in $names; do
        p=$(modules_in_initramfs "$n" 2>/dev/null) || continue
        printf '%s\t%s\n' "$n" "$p"
    done
    return 0
}

# modules_load_path <module> : "early-initrd" when the module comes from the
# initramfs (our override applies), "modprobe-hook" otherwise or when
# unknown.
modules_load_path() {
    if modules_in_initramfs "$1" >/dev/null 2>&1; then
        printf 'early-initrd\n'
    else
        printf 'modprobe-hook\n'
    fi
}

# _modules_cpio_newc <dir> <out> : pack <dir> (relative paths) as an
# uncompressed newc cpio; GNU and bsd cpio spell the format differently.
_modules_cpio_newc() {
    local fmt
    if cpio --version 2>/dev/null | grep -qi gnu; then
        fmt="-H newc"
    else
        fmt="--format newc"
    fi
    # shellcheck disable=SC2086  # fmt is two words on purpose
    (cd "$1" && find . -type f | LC_ALL=C sort | sed 's|^\./||' | cpio -o $fmt --quiet 2>/dev/null) >"$2"
}

# modules_override_render <kver> <out-abs> : the override cpio for every
# listed module that is both staged for <kver> and present in the initramfs,
# each at the initramfs's own path and with its compression (the member name
# says which). 0 written, 1 nothing to pack (caller drops the initrd), 2 error.
modules_override_render() {
    local kver=$1 out=$2 dir tree members n p ko dst n_packed=0
    dir=$(sof_path "$(modules_dir_for "$kver")")
    members=$(modules_initramfs_members "$kver") || return 2
    [ -n "$members" ] || return 1
    sof_have cpio || {
        log_warn "cpio not available: cannot build the early initrd override"
        return 2
    }
    tree=$(mktemp -d "${TMPDIR:-/tmp}/sof-override.XXXXXX") || return 2
    while IFS="$(printf '\t')" read -r n p; do
        [ -n "$n" ] || continue
        ko="$dir/$n.ko.zst"
        [ -s "$ko" ] || continue # superseded or not staged: stock stays
        case "$p" in
            /* | *../*)
                log_warn "refusing odd initramfs member path for $n: $p"
                continue
                ;;
        esac
        dst="$tree/$p"
        mkdir -p "$(dirname "$dst")" || continue
        case "$p" in
            *.ko.zst) cp "$ko" "$dst" ;;
            *.ko.xz) zstd -dc "$ko" | xz -c >"$dst" ;;
            *.ko.gz) zstd -dc "$ko" | gzip -c >"$dst" ;;
            *.ko) zstd -dc "$ko" >"$dst" ;;
            *) continue ;;
        esac && n_packed=$((n_packed + 1))
    done <<EOF
$members
EOF
    if [ "$n_packed" = 0 ]; then
        rm -rf "$tree"
        return 1
    fi
    if ! _modules_cpio_newc "$tree" "$out" || [ ! -s "$out" ]; then
        rm -rf "$tree"
        rm -f "$out"
        log_error "building the early initrd override failed"
        return 2
    fi
    rm -rf "$tree"
    log_info "early initrd override: $n_packed module(s) for $kver"
    return 0
}

# modules_override_sync <kver> : make the slot's boot entry carry the
# override exactly when a staged build for <kver> has modules that the
# initramfs loads; otherwise drop it. Logs and returns non-zero on failure,
# never dies. Only touches the entry when the slot is known.
modules_override_sync() {
    local kver=$1 slot tmp rc=0 rel real args
    rel=$SOF_OVERRIDE_INITRD_REL
    real=$(sof_path "$rel")
    slot=$(slots_active 2>/dev/null) || slot=""
    tmp=$(mktemp "${TMPDIR:-/tmp}/sof-override.XXXXXX") || return 1
    if modules_available "$kver" && modules_override_render "$kver" "$tmp"; then
        if [ "$SOF_DRY_RUN" = 1 ]; then
            printf '[dry-run] install early initrd override %s\n' "$rel" >&2
            rm -f "$tmp"
            return 0
        fi
        if ! [ -d "$(dirname "$real")" ]; then
            log_warn "no $(dirname "$rel") on this root; early initrd override not installed"
            rm -f "$tmp"
            return 1
        fi
        manifest_install_file "$tmp" "$rel" "$SOF_MODULES_COMPONENT" 0644 esp || rc=1
        rm -f "$tmp"
        [ "$rc" = 0 ] || return 1
        if [ -n "$slot" ]; then
            slot_set_early_initrd "$slot" "$rel" "" last || rc=1
        else
            log_warn "early initrd override staged, but the booted slot is unknown; run '$SOF_NAME boot-entry set --initrd $rel'"
        fi
        return "$rc"
    fi
    rm -f "$tmp"
    # Nothing to override (nothing staged, all superseded, or no listed
    # module in the initramfs): the entry must not reference the image.
    if [ "$(slots_desired_get initrd 2>/dev/null || true)" = "$rel" ]; then
        args=$(slots_desired_get args 2>/dev/null || true)
        if [ -n "$args" ]; then
            slots_desired_set "$args" "" first
        else
            slots_desired_clear
        fi
        [ -n "$slot" ] && slots_entry_reconcile "$slot"
    fi
    if manifest_has "$rel"; then
        [ "$SOF_DRY_RUN" = 1 ] || rm -f "$real"
        manifest_forget "$rel"
        log_info "early initrd override removed (no patched module to load that way for $kver)"
    fi
    return 0
}
