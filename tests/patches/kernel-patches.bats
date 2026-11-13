#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# Static checks for patches/kernel/: format-patch shape, attribution, the
# Valve-Upstream line, touched paths against the module lists, and that the
# hdmi-frl patch applies to Valve's 7.2.7-valve2 function (a fixture copy of
# it). No kernel tree is needed; `git apply` only parses the patch.
load '../test_helper'

KDIR="$REPO_ROOT/patches/kernel"
FRL=0001-drm-amd-display-use-dc_is_hdmi_signal-in-freesync-caps.patch

kernel_patches() {
    find "$KDIR" -maxdepth 1 -type f -name '*.patch' | sort
}

# touched_paths <patch> : every a/ and b/ path named in a diff --git header.
touched_paths() {
    awk '/^diff --git a\// { sub(/^a\//, "", $3); sub(/^b\//, "", $4); print $3; print $4 }' "$1" | sort -u
}

# outside_mdirs <patch> : files the patch touches that are under none of the
# M= dirs it is listed with in modules-*.list, nor under their parent
# directory when that parent is at least three components deep
# (build-modules.sh bm_check_patch_scope; include/ and Documentation/ exempt).
outside_mdirs() {
    local f
    for f in $(touched_paths "$KDIR/$1" | grep -v -e '^include/' -e '^Documentation/'); do
        cat "$KDIR"/modules*.list | awk -F'\t' -v p="$1" -v f="$f" '
            $1 == p { m = $2; sub(/\/[^\/]*$/, "", m); if (index(f, $2 "/") == 1 || (gsub(/\//, "/", m) >= 2 && index(f, m "/") == 1)) ok = 1 }
            END { if (!ok) print f }'
    done
}

@test "the hdmi-frl patch exists, keeps its author and says where it comes from" {
    [ -f "$KDIR/$FRL" ]
    grep -q '^From: =?UTF-8?q?Tomasz=20Paku=C5=82a?= <forest10pl@gmail.com>$' "$KDIR/$FRL"
    grep -q '^Derived from: Tomasz Pakuła, commit 21d564d5a104e37deea7cba5fca24776915fd36d$' "$KDIR/$FRL"
    grep -q 'Lawstorant/linux' "$KDIR/$FRL"
    grep -q 'beaglemoo/steam-machine-hdmi21' "$KDIR/$FRL"
    grep -q 'ValveSoftware/SteamOS/issues/2809' "$KDIR/$FRL"
    # the tag must sit in the description, where build-modules.sh reads it
    [ "$(awk '/^---$/ { exit } /^Valve-Upstream: / { print $2 }' "$KDIR/$FRL")" = 7.2.10-valve1 ]
}

@test "the hdmi-frl patch is the one-line freesync-caps change and applies to Valve's 7.2.7-valve2 function" {
    [ "$(git apply --numstat "$KDIR/$FRL")" = "$(printf '1\t1\tdrivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm.c')" ]
    grep -q '^-	} else if (sink->sink_signal == SIGNAL_TYPE_HDMI_TYPE_A) {$' "$KDIR/$FRL"
    grep -q '^+	} else if (dc_is_hdmi_signal(sink->sink_signal)) {$' "$KDIR/$FRL"
    t="$BATS_TEST_TMPDIR/tree"
    mkdir -p "$t/drivers/gpu/drm/amd/display/amdgpu_dm"
    cp "$REPO_ROOT/tests/patches/fixtures/amdgpu_dm-7.2.7-valve2-freesync-caps.c" "$t/drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm.c"
    (cd "$t" && git apply --check --unsafe-paths "$KDIR/$FRL")
    (cd "$t" && git apply --unsafe-paths "$KDIR/$FRL")
    grep -q 'dc_is_hdmi_signal(sink->sink_signal)' "$t/drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm.c"
    # applied already: only the reverse applies now
    (cd "$t" && ! git apply --check --unsafe-paths "$KDIR/$FRL")
    (cd "$t" && git apply --check --reverse --unsafe-paths "$KDIR/$FRL")
}

@test "modules-hdmi-frl.list builds amdgpu.ko from drivers/gpu/drm/amd/amdgpu for it" {
    grep -qxF "$FRL$(printf '\t')drivers/gpu/drm/amd/amdgpu$(printf '\t')amdgpu.ko" "$KDIR/modules-hdmi-frl.list"
}

@test "every kernel patch has git format-patch headers" {
    local p n=0
    for p in $(kernel_patches); do
        n=$((n + 1))
        head -n 1 "$p" | grep -q '^From [0-9a-f]\{40\} ' || {
            echo "bad first line: $p"
            false
        }
        grep -q '^From: .\+ <.\+@.\+>$' "$p" || {
            echo "no From: author line: $p"
            false
        }
        grep -q '^Subject: ' "$p" || {
            echo "no Subject: $p"
            false
        }
        grep -qx -- '---' "$p" || {
            echo "no --- separator: $p"
            false
        }
        grep -q '^diff --git a/' "$p" || {
            echo "no diff --git: $p"
            false
        }
    done
    [ "$n" -gt 0 ]
}

@test "every kernel patch parses with git apply --numstat" {
    local p
    for p in $(kernel_patches); do
        run git apply --numstat "$p"
        assert_success
        [ -n "$output" ] || {
            echo "empty numstat: $p"
            false
        }
    done
}

@test "kernel patches only touch sound/, drivers/, include/ or Documentation/" {
    local p f
    for p in $(kernel_patches); do
        for f in $(touched_paths "$p") $(git apply --numstat "$p" | cut -f3); do
            case "$f" in
                sound/* | drivers/* | include/* | Documentation/*) ;;
                *)
                    echo "$p touches $f"
                    false
                    ;;
            esac
        done
    done
}

@test "kernel patches cite their sources" {
    local p
    for p in $(kernel_patches); do
        grep -q '^Derived from:' "$p" || {
            echo "no 'Derived from:' section: $p"
            false
        }
    done
}

@test "kernel patches carry no AI or co-author attribution" {
    run bash -c 'grep -inE "(signed-off-by|co-authored-by|assisted-by|generated-by|helped-by): .*(claude|anthropic|openai|chatgpt|copilot|gpt-)|^(co-authored-by|assisted-by):|generated with|noreply@anthropic" "$@"' _ $(kernel_patches)
    [ "$status" -eq 1 ] || {
        echo "$output"
        false
    }
}

@test "every modules-*.list is well-formed and references existing patches" {
    local l line patch mdir ko rest n=0
    for l in "$KDIR"/modules*.list; do
        [ -f "$l" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in '' | '#'*) continue ;; esac
            n=$((n + 1))
            [ "$(printf '%s' "$line" | awk -F'\t' '{print NF}')" -eq 3 ] || {
                echo "$l line $n: expected 3 tab-separated fields: $line"
                false
            }
            patch=$(printf '%s' "$line" | cut -f1)
            mdir=$(printf '%s' "$line" | cut -f2)
            ko=$(printf '%s' "$line" | cut -f3)
            [ -f "$KDIR/$patch" ] || {
                echo "$l line $n: missing patch $patch"
                false
            }
            case "$mdir" in
                sound/* | drivers/*) ;;
                *)
                    echo "$l line $n: M= dir outside sound/ or drivers/: $mdir"
                    false
                    ;;
            esac
            case "$mdir" in */) echo "$l line $n: trailing slash in $mdir" && false ;; esac
            case "$ko" in
                *.ko) ;;
                *)
                    echo "$l line $n: not a .ko name: $ko"
                    false
                    ;;
            esac
            rest=$(outside_mdirs "$patch")
            [ -z "$rest" ] || {
                echo "$l line $n: $patch touches files outside its M= dirs: $rest"
                false
            }
        done <"$l"
    done
    [ "$n" -gt 0 ]
}

@test "every kernel patch is listed in a modules*.list, one list per fix" {
    local p l
    for p in $(kernel_patches); do
        cat "$KDIR"/modules*.list | cut -f1 | grep -qxF "$(basename "$p")" || {
            echo "not in any modules*.list: $p"
            false
        }
    done
    for l in "$KDIR"/modules-*.list; do
        [ -f "$l" ] || continue
        [ -f "$REPO_ROOT/fixes/$(basename "$l" .list | sed 's/^modules-//')/component.sh" ] || {
            echo "no fix for $l"
            false
        }
    done
}
