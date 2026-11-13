#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# The self-contained uninstaller against every broken state from plan §5.2 rule 6.
load '../test_helper'
load '../update_helper'

UNINSTALL="$REPO_ROOT/uninstall/uninstall.sh"

setup() {
    make_root >/dev/null
    source_libs
    SRC="$BATS_TEST_TMPDIR/payload"
    printf 'ours\n' >"$SRC"
    STATE="$SOF_ROOT/var/lib/steamos-fixes"
}

# modified_entry [grub|bls] : a boot entry modified by lib/slots.sh exactly as
# apply does it (the stock fixture is kept as $PRISTINE), with the early
# initrd manifest-tracked like the audio component installs it. Sets ENTRY
# and IMG (root-relative).
modified_entry() {
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/slots.sh"
    unset SOF_SLOT SOF_BOOT_ENTRY
    PRISTINE="$BATS_TEST_TMPDIR/pristine"
    if [ "${1:-grub}" = bls ]; then
        ENTRY=/esp/loader/entries/steamos-A.conf
        IMG=/esp/steamos-fixes/modules.img
        fixture_bls "$ENTRY"
    else
        ENTRY=/efi/EFI/steamos/grub.cfg
        IMG=/efi/EFI/steamos/steamos-fixes-modules.img
        fixture_grub
    fi
    [ -z "${NOEOL:-}" ] || printf '%s' "$(cat "$SOF_ROOT$ENTRY")" >"$SOF_ROOT$ENTRY"
    cp "$SOF_ROOT$ENTRY" "$PRISTINE"
    fixture_initrd "$IMG"
    cp "$SOF_ROOT$IMG" "$BATS_TEST_TMPDIR/modules.img"
    rm -f "$SOF_ROOT$IMG"
    manifest_install_file "$BATS_TEST_TMPDIR/modules.img" "$IMG" audio 0644 esp
    slots_entry_apply A "firmware_class.path=/etc/steamos-fixes/firmware" "$IMG" 2>/dev/null
    slots_entry_is_modified "$SOF_ROOT$ENTRY"
    ! cmp -s "$SOF_ROOT$ENTRY" "$PRISTINE"
}

run_uninstall() {
    run sh "$UNINSTALL" --root "$SOF_ROOT" --yes "$@"
}

install_demo() {
    manifest_install_file "$SRC" /etc/modprobe.d/steamos-fixes.conf modules 0644
    manifest_install_file "$SRC" /etc/environment.d/90-steamos-fixes-ucm.conf audio 0644
    manifest_install_file "$SRC" /etc/steamos-fixes/load-or-fallback modules 0755
    manifest_install_symlink /var/lib/steamos-fixes/bin/gamescope /home/deck/.local/bin/steamos-fixes-gamescope hdr home
}

@test "full uninstall removes files, symlinks, created dirs and the state dir" {
    install_demo
    [ -f "$SOF_ROOT/etc/modprobe.d/steamos-fixes.conf" ]
    run_uninstall
    assert_success
    [ ! -e "$SOF_ROOT/etc/modprobe.d/steamos-fixes.conf" ]
    [ ! -e "$SOF_ROOT/etc/environment.d/90-steamos-fixes-ucm.conf" ]
    [ ! -L "$SOF_ROOT/home/deck/.local/bin/steamos-fixes-gamescope" ]
    [ ! -d "$SOF_ROOT/home/deck/.local/bin" ]  # created by us, now empty
    [ ! -d "$STATE" ]
    [ -d "$SOF_ROOT/etc" ]
}

@test "the system is byte-identical after install + uninstall" {
    mkdir -p "$SOF_ROOT/etc/modprobe.d" "$SOF_ROOT/usr/lib" "$SOF_ROOT/home/deck"
    fixture_file /etc/modprobe.d/stock.conf "stock"
    fixture_file /etc/fstab "fstab"
    fixture_file /usr/lib/libdisplay-info.so.1 "lib"
    rmdir "$STATE" # a clean system has no state dir; install creates it
    before=$(cd "$SOF_ROOT" && find . | sort | xargs -I{} sh -c 'test -f "{}" && sha256sum "{}" || echo "{}"' | sha256sum)
    install_demo
    run_uninstall
    assert_success
    after=$(cd "$SOF_ROOT" && find . | sort | xargs -I{} sh -c 'test -f "{}" && sha256sum "{}" || echo "{}"' | sha256sum)
    [ "$before" = "$after" ]
}

@test "running twice is a no-op" {
    install_demo
    run_uninstall
    assert_success
    run_uninstall
    assert_success
    assert_output_contains "no manifest"
}

@test "dry-run prints actions and changes nothing" {
    install_demo
    run_uninstall --dry-run
    assert_success
    assert_output_contains "[dry-run] rm /etc/modprobe.d/steamos-fixes.conf"
    assert_output_contains "[dry-run] rm -rf"
    [ -f "$SOF_ROOT/etc/modprobe.d/steamos-fixes.conf" ]
    [ -f "$STATE/manifest" ]
}

@test "modified file is skipped without --force, removed with it; state dir kept when anything skipped" {
    install_demo
    printf 'edited by user\n' >"$SOF_ROOT/etc/modprobe.d/steamos-fixes.conf"
    run_uninstall
    assert_failure 1
    assert_output_contains "content changed"
    [ -f "$SOF_ROOT/etc/modprobe.d/steamos-fixes.conf" ]
    [ -d "$STATE" ]
    # The skipped entry is still in the manifest, the removed ones are gone.
    grep -q 'steamos-fixes.conf' "$STATE/manifest"
    ! grep -q '90-steamos-fixes-ucm.conf' "$STATE/manifest"
    run_uninstall --force
    assert_success
    [ ! -e "$SOF_ROOT/etc/modprobe.d/steamos-fixes.conf" ]
    [ ! -d "$STATE" ]
}

@test "partial manifest (interrupted install): missing files are tolerated" {
    install_demo
    rm "$SOF_ROOT/etc/environment.d/90-steamos-fixes-ucm.conf"
    run_uninstall
    assert_success
    assert_output_contains "already gone"
    [ ! -d "$STATE" ]
}

@test "symlinks are removed without following their target" {
    mkdir -p "$STATE/bin"
    printf 'target\n' >"$STATE/bin/gamescope"
    manifest_install_symlink /var/lib/steamos-fixes/bin/gamescope /home/deck/.local/bin/steamos-fixes-gamescope hdr home
    run_uninstall --keep-state
    assert_success
    [ ! -L "$SOF_ROOT/home/deck/.local/bin/steamos-fixes-gamescope" ]
    [ -f "$STATE/bin/gamescope" ]
}

@test "a symlink whose target changed is skipped unless --force" {
    manifest_install_symlink /a /home/deck/.config/steamos-fixes-link hdr home
    ln -sfn /b "$SOF_ROOT/home/deck/.config/steamos-fixes-link"
    run_uninstall --keep-state
    assert_failure 1
    [ -L "$SOF_ROOT/home/deck/.config/steamos-fixes-link" ]
    run_uninstall --keep-state --force
    assert_success
    [ ! -L "$SOF_ROOT/home/deck/.config/steamos-fixes-link" ]
}

@test "directories are removed only when we created them and they are empty" {
    manifest_install_file "$SRC" /etc/inputplumber/devices.d/steamos-fixes-demo.yaml inputplumber
    fixture_file /etc/inputplumber/devices.d/user-added.yaml "keep me"
    run_uninstall
    assert_success
    [ ! -e "$SOF_ROOT/etc/inputplumber/devices.d/steamos-fixes-demo.yaml" ]
    [ -f "$SOF_ROOT/etc/inputplumber/devices.d/user-added.yaml" ]
    [ -d "$SOF_ROOT/etc/inputplumber/devices.d" ]
    assert_output_contains "not empty"
}

@test "protected system directories are never removed even if the manifest says we created them" {
    manifest_record /etc/systemd/system audio dir "" shared false
    manifest_record /etc audio dir "" shared false
    manifest_record /home/deck audio dir "" home false
    manifest_record /esp/loader/entries audio dir "" esp false
    mkdir -p "$SOF_ROOT/etc/systemd/system" "$SOF_ROOT/home/deck" "$SOF_ROOT/esp/loader/entries"
    run_uninstall
    assert_success
    [ -d "$SOF_ROOT/etc/systemd/system" ]
    [ -d "$SOF_ROOT/etc" ]
    [ -d "$SOF_ROOT/home/deck" ]
    [ -d "$SOF_ROOT/esp/loader/entries" ]
}

@test "every ancestor directory we created is recorded and removed again" {
    mkdir -p "$SOF_ROOT/home/deck"
    manifest_install_file "$SRC" /home/deck/.config/pipewire/pipewire.conf.d/50-steamos-fixes-headphones.conf audio_dsp 0644 home
    manifest_has /home/deck/.config
    manifest_has /home/deck/.config/pipewire
    manifest_has /home/deck/.config/pipewire/pipewire.conf.d
    run_uninstall
    assert_success
    [ ! -d "$SOF_ROOT/home/deck/.config" ]
    [ -d "$SOF_ROOT/home/deck" ]
}

@test "deny-list: crafted manifest entries are refused and reported" {
    fixture_file /usr/lib/steamos-fixes-evil.so "stock"
    fixture_file /etc/fstab "fstab"
    fixture_file /home/deck/.steam/steamos-fixes-x "steam"
    fixture_file /etc/rauc/system.conf "rauc"
    fixture_file /efi/EFI/steamos/steamcl.efi "loader"
    fixture_file /etc/no-marker.conf "x"
    for p in /usr/lib/steamos-fixes-evil.so /etc/fstab /home/deck/.steam/steamos-fixes-x /etc/rauc/system.conf /efi/EFI/steamos/steamcl.efi /etc/no-marker.conf; do
        manifest_record "$p" evil file "$(sof_sha256 "$SOF_ROOT$p")" shared false
    done
    manifest_record "../etc/steamos-fixes-rel" evil file 0 shared false
    manifest_record "/etc/steamos-fixes/../fstab" evil file 0 shared false
    run_uninstall --force
    assert_failure 1
    for p in /usr/lib/steamos-fixes-evil.so /etc/fstab /home/deck/.steam/steamos-fixes-x /etc/rauc/system.conf /efi/EFI/steamos/steamcl.efi /etc/no-marker.conf; do
        [ -f "$SOF_ROOT$p" ]
        assert_output_contains "REFUSED $p"
    done
    assert_output_contains "relative manifest path"
    assert_output_contains "path with .."
    [ -d "$STATE" ]
}

@test "our own ESP file is allowed" {
    manifest_install_file "$SRC" /efi/EFI/steamos/steamos-fixes-modules.img audio 0644 esp
    run_uninstall
    assert_success
    [ ! -e "$SOF_ROOT/efi/EFI/steamos/steamos-fixes-modules.img" ]
}

@test "--component removes only that component and keeps the manifest for the rest" {
    install_demo
    run_uninstall --component audio
    assert_success
    [ ! -e "$SOF_ROOT/etc/environment.d/90-steamos-fixes-ucm.conf" ]
    [ -f "$SOF_ROOT/etc/modprobe.d/steamos-fixes.conf" ]
    [ -d "$STATE" ]
    ! grep -q '90-steamos-fixes-ucm' "$STATE/manifest"
    grep -q 'modprobe.d/steamos-fixes.conf' "$STATE/manifest"
    # Remaining manifest is still parseable by the library.
    [ "$(manifest_paths modules | wc -l | tr -d ' ')" = 4 ] # 2 files + 2 created dirs
}

@test "backups of type=file are restored byte-for-byte, hash verified" {
    fixture_file /esp/loader/entries/steamos-A.conf "title SteamOS A
options root=/dev/sda2 steamos-fixes-modified initrd=/EFI/steamos/steamos-fixes-modules.img"
    mkdir -p "$STATE/backup/boot-entry-A"
    printf 'title SteamOS A\noptions root=/dev/sda2\n' >"$STATE/backup/boot-entry-A/original"
    printf 'path=/esp/loader/entries/steamos-A.conf\nsha256=%s\ntype=file\ncomponent=update\n' "$(sof_sha256 "$STATE/backup/boot-entry-A/original")" >"$STATE/backup/boot-entry-A/meta"
    run_uninstall
    assert_success
    assert_output_contains "restored byte-for-byte"
    [ "$(cat "$SOF_ROOT/esp/loader/entries/steamos-A.conf")" = "$(printf 'title SteamOS A\noptions root=/dev/sda2')" ]
}

@test "corrupt backup is not restored; missing original is reported" {
    fixture_file /esp/loader/entries/steamos-A.conf "live"
    mkdir -p "$STATE/backup/b1" "$STATE/backup/b2"
    printf 'orig' >"$STATE/backup/b1/original"
    printf 'path=/esp/loader/entries/steamos-A.conf\nsha256=0000\ntype=file\n' >"$STATE/backup/b1/meta"
    printf 'path=/esp/loader/entries/steamos-B.conf\nsha256=1111\ntype=file\n' >"$STATE/backup/b2/meta"
    run_uninstall
    assert_failure 1
    assert_output_contains "corrupt"
    assert_output_contains "saved original missing"
    [ "$(cat "$SOF_ROOT/esp/loader/entries/steamos-A.conf")" = live ]
}

@test "backups of type=block strip only our delimited block" {
    orig='[system]
compatible=steamos-amd64
bootloader=grub
'
    fixture_file /etc/rauc/system.conf "${orig}# >>> steamos-fixes
[handlers]
post-install=/var/lib/steamos-fixes/src/overlay/rauc/post-install.hook
# <<< steamos-fixes
"
    mkdir -p "$STATE/backup/rauc"
    printf '%s' "$orig" >"$STATE/backup/rauc/original"
    printf 'path=/etc/rauc/system.conf\nsha256=%s\ntype=block\n' "$(sof_sha256 "$STATE/backup/rauc/original")" >"$STATE/backup/rauc/meta"
    run_uninstall
    assert_success
    assert_output_contains "identical to saved original"
    [ "$(cat "$SOF_ROOT/etc/rauc/system.conf")" = "$(printf '%s' "$orig")" ]
}

@test "type=block keeps upstream changes when the stripped file differs from the original" {
    fixture_file /etc/rauc/system.conf "[system]
compatible=steamos-amd64
new-valve-key=1
# >>> steamos-fixes
[handlers]
post-install=/x
# <<< steamos-fixes
"
    mkdir -p "$STATE/backup/rauc"
    printf '[system]\ncompatible=steamos-amd64\n' >"$STATE/backup/rauc/original"
    printf 'path=/etc/rauc/system.conf\nsha256=%s\ntype=block\n' "$(sof_sha256 "$STATE/backup/rauc/original")" >"$STATE/backup/rauc/meta"
    run_uninstall
    assert_success
    assert_output_contains "differs from the saved original"
    [ "$(cat "$SOF_ROOT/etc/rauc/system.conf")" = "$(printf '[system]\ncompatible=steamos-amd64\nnew-valve-key=1')" ]
}

@test "backups under /usr are refused" {
    mkdir -p "$STATE/backup/evil"
    printf 'x' >"$STATE/backup/evil/original"
    printf 'path=/usr/bin/gamescope\nsha256=%s\ntype=file\n' "$(sof_sha256 "$STATE/backup/evil/original")" >"$STATE/backup/evil/meta"
    run_uninstall
    assert_failure 1
    assert_output_contains "refusing to restore under /usr"
    [ ! -e "$SOF_ROOT/usr/bin/gamescope" ]
}

@test "works when the git checkout is gone (standalone copy from the state dir)" {
    install_demo
    cp "$UNINSTALL" "$STATE/uninstall.sh"
    run sh "$STATE/uninstall.sh" --root "$SOF_ROOT" --yes
    assert_success
    [ ! -d "$STATE" ]
}

@test "manifest paths with escaped quotes, backslashes and tabs round-trip through the awk parser" {
    weird='/etc/steamos-fixes/we"ird\pa	th.conf'
    mkdir -p "$SOF_ROOT/etc/steamos-fixes"
    printf 'x' >"$SOF_ROOT$weird"
    manifest_record "$weird" audio file "$(sof_sha256 "$SOF_ROOT$weird")" shared false
    run_uninstall
    assert_success
    [ ! -e "$SOF_ROOT$weird" ]
}

@test "refuses to run on the live root without root privileges, except dry-run" {
    if [ "$(id -u)" = 0 ]; then skip "running as root"; fi
    run sh "$UNINSTALL" --yes
    assert_failure 2
    assert_output_contains "must run as root"
}

@test "--root must be a directory; unknown options are rejected" {
    run sh "$UNINSTALL" --root "$BATS_TEST_TMPDIR/nope" --yes
    assert_failure 2
    run sh "$UNINSTALL" --bogus
    assert_failure 2
}

@test "state dir behind the /home symlink is removed together with its target" {
    rm -rf "$STATE"
    mkdir -p "$SOF_ROOT/home/deck"
    sof_state_dir_ensure >/dev/null
    [ -L "$STATE" ]
    install_demo
    [ -f "$SOF_ROOT/home/.steamos-fixes/manifest" ]
    run_uninstall
    assert_success
    [ ! -L "$STATE" ] && [ ! -e "$STATE" ]
    [ ! -e "$SOF_ROOT/home/.steamos-fixes" ]
    [ -d "$SOF_ROOT/home/deck" ]
}

@test "a state symlink pointing somewhere unexpected is removed but its target is left alone" {
    rm -rf "$STATE"
    mkdir -p "$SOF_ROOT/srv/elsewhere"
    ln -s /srv/elsewhere "$STATE"
    run_uninstall
    assert_success
    assert_output_contains "unexpected"
    [ -d "$SOF_ROOT/srv/elsewhere" ]
    [ ! -L "$STATE" ]
}

@test "lib/slots.sh backup layout (backup/<slot>/<file> + .sha256 + entry-path) is restored" {
    orig='menuentry SteamOS {
	steamenv_boot	linux /boot/vmlinuz console=tty1 quiet
	initrd	/boot/amd-ucode.img /boot/initramfs.img
}
'
    fixture_file /efi/EFI/steamos/grub.cfg "# steamos-fixes: boot entry modified by steamos-fixes
menuentry SteamOS {
	steamenv_boot	linux /boot/vmlinuz console=tty1 quiet firmware_class.path=/etc/steamos-fixes/firmware
	initrd	\${cmdpath}/steamos-fixes-modules.img /boot/amd-ucode.img /boot/initramfs.img
}
"
    mkdir -p "$STATE/backup/B"
    printf '%s' "$orig" >"$STATE/backup/B/grub.cfg"
    sof_sha256 "$STATE/backup/B/grub.cfg" >"$STATE/backup/B/grub.cfg.sha256"
    printf '/efi/EFI/steamos/grub.cfg\n' >"$STATE/backup/B/entry-path"
    run_uninstall
    assert_success
    assert_output_contains "restored byte-for-byte"
    [ "$(cat "$SOF_ROOT/efi/EFI/steamos/grub.cfg")" = "$(printf '%s' "$orig")" ]
}

@test "slots layout: a regenerated stock entry without our marker is left alone" {
    fixture_file /efi/EFI/steamos/grub.cfg "menuentry NewSteamOS { linux /boot/vmlinuz-new }"
    mkdir -p "$STATE/backup/B"
    printf 'old original\n' >"$STATE/backup/B/grub.cfg"
    sof_sha256 "$STATE/backup/B/grub.cfg" >"$STATE/backup/B/grub.cfg.sha256"
    printf '/efi/EFI/steamos/grub.cfg\n' >"$STATE/backup/B/entry-path"
    run_uninstall
    assert_success
    assert_output_contains "carries no steamos-fixes change; leaving it alone"
    [ "$(cat "$SOF_ROOT/efi/EFI/steamos/grub.cfg")" = "menuentry NewSteamOS { linux /boot/vmlinuz-new }" ]
}

@test "lib/rauc.sh backup layout (backup/rauc/system.conf) strips the block" {
    orig='[system]
compatible=steamos-amd64

[handlers]
post-install=/usr/lib/rauc/post-install.sh
'
    fixture_file /etc/rauc/system.conf "${orig}# >>> steamos-fixes managed block (sep=0); original saved as ...
[handlers]
pre-install=/var/lib/steamos-fixes/libexec/rauc-pre-install.hook
post-install=/var/lib/steamos-fixes/libexec/rauc-post-install.hook
# <<< steamos-fixes
"
    mkdir -p "$STATE/backup/rauc"
    printf '%s' "$orig" >"$STATE/backup/rauc/system.conf"
    sof_sha256 "$STATE/backup/rauc/system.conf" >"$STATE/backup/rauc/system.conf.sha256"
    run_uninstall
    assert_success
    assert_output_contains "identical to saved original"
    [ "$(cat "$SOF_ROOT/etc/rauc/system.conf")" = "$(printf '%s' "$orig")" ]
}

@test "lib/rauc.sh single-[handlers] layout: blocks go, commented stock handler comes back" {
    orig='[system]
compatible=steamos-amd64

[handlers]
bootloader-custom-backend=/usr/lib/rauc/bootloader-custom-backend.sh
post-install=/usr/lib/rauc/post-install.sh

[slot.rootfs.0]
device=/dev/disk/by-partsets/A/rootfs
'
    fixture_file /etc/rauc/system.conf '[system]
compatible=steamos-amd64

[handlers]
# >>> steamos-fixes managed block (sep=0); original saved as /var/lib/steamos-fixes/backup/rauc/system.conf; remove with "steamos-fixes uninstall"
# stock handlers are chained, see /var/lib/steamos-fixes/state/rauc-chain
pre-install=/var/lib/steamos-fixes/libexec/rauc-pre-install.hook
post-install=/var/lib/steamos-fixes/libexec/rauc-post-install.hook
# <<< steamos-fixes
bootloader-custom-backend=/usr/lib/rauc/bootloader-custom-backend.sh
# >>> steamos-fixes stock handler, chained by the block above
#steamos-fixes-orig:post-install=/usr/lib/rauc/post-install.sh
# <<< steamos-fixes

[slot.rootfs.0]
device=/dev/disk/by-partsets/A/rootfs
'
    mkdir -p "$STATE/backup/rauc"
    printf '%s' "$orig" >"$STATE/backup/rauc/system.conf"
    sof_sha256 "$STATE/backup/rauc/system.conf" >"$STATE/backup/rauc/system.conf.sha256"
    run_uninstall
    assert_success
    assert_output_contains "identical to saved original"
    [ "$(cat "$SOF_ROOT/etc/rauc/system.conf")" = "$(printf '%s' "$orig")" ]
}

@test "lib/rauc.sh layout with sep=1: the original without a final newline comes back exactly" {
    printf '[system]\ncompatible=steamos-amd64\n\n[handlers]\npost-install=/usr/lib/rauc/post-install.sh' >"$BATS_TEST_TMPDIR/orig"
    mkdir -p "$SOF_ROOT/etc/rauc"
    printf '[system]\ncompatible=steamos-amd64\n\n[handlers]\n# >>> steamos-fixes managed block (sep=1); original saved as ...\npre-install=/p\npost-install=/q\n# <<< steamos-fixes\n# >>> steamos-fixes stock handler, chained by the block above\n#steamos-fixes-orig:post-install=/usr/lib/rauc/post-install.sh\n# <<< steamos-fixes\n' >"$SOF_ROOT/etc/rauc/system.conf"
    mkdir -p "$STATE/backup/rauc"
    cp "$BATS_TEST_TMPDIR/orig" "$STATE/backup/rauc/system.conf"
    sof_sha256 "$STATE/backup/rauc/system.conf" >"$STATE/backup/rauc/system.conf.sha256"
    run_uninstall
    assert_success
    assert_output_contains "identical to saved original"
    cmp "$SOF_ROOT/etc/rauc/system.conf" "$BATS_TEST_TMPDIR/orig"
}

@test "boot entry with our marker and no backup at all (state dir gone) is regenerated byte-identical" {
    modified_entry
    rm -rf "$STATE"
    run_uninstall
    assert_success
    assert_output_contains "no saved original exists; regenerating"
    assert_output_contains "matches the recorded original digest"
    cmp "$SOF_ROOT$ENTRY" "$PRISTINE"
}

@test "boot entry whose saved original is missing or corrupt is regenerated from the marker" {
    modified_entry
    cp "$SOF_ROOT$ENTRY" "$BATS_TEST_TMPDIR/modified"
    rm -f "$STATE/backup/A/grub.cfg"
    run_uninstall --keep-state
    assert_success
    assert_output_contains "saved original missing; regenerating"
    cmp "$SOF_ROOT$ENTRY" "$PRISTINE"
    # Corrupt saved copy (hash mismatch) on a fresh modified entry.
    cp "$BATS_TEST_TMPDIR/modified" "$SOF_ROOT$ENTRY"
    printf 'garbage\n' >"$STATE/backup/A/grub.cfg"
    printf '0000\n' >"$STATE/backup/A/grub.cfg.sha256"
    run_uninstall
    assert_success
    assert_output_contains "corrupt (hash mismatch); regenerating"
    cmp "$SOF_ROOT$ENTRY" "$PRISTINE"
    [ ! -d "$STATE" ]
}

@test "a regenerated entry that differs from the recorded digest is still stripped, with a warning" {
    modified_entry
    rm -rf "$STATE/backup"
    # Someone edited the entry after we modified it.
    sed 's/rd.luks=0/rd.luks=1/' "$SOF_ROOT$ENTRY" >"$BATS_TEST_TMPDIR/edited"
    cat "$BATS_TEST_TMPDIR/edited" >"$SOF_ROOT$ENTRY"
    run_uninstall
    assert_success
    assert_output_contains "differs from the recorded original digest"
    ! grep -q 'steamos-fixes' "$SOF_ROOT$ENTRY"
    [ "$(cat "$SOF_ROOT$ENTRY")" = "$(sed 's/rd.luks=0/rd.luks=1/' "$PRISTINE")" ]
}

@test "BLS entry with our marker and no backup is regenerated byte-identical" {
    modified_entry bls
    rm -rf "$STATE/backup"
    run_uninstall
    assert_success
    assert_output_contains "matches the recorded original digest"
    cmp "$SOF_ROOT$ENTRY" "$PRISTINE"
    [ ! -e "$SOF_ROOT$IMG" ]
}

@test "an entry without a final newline is regenerated byte-identical" {
    NOEOL=1 modified_entry
    rm -rf "$STATE/backup"
    run_uninstall
    assert_success
    cmp "$SOF_ROOT$ENTRY" "$PRISTINE"
}

@test "dry-run reports the regeneration and the image removal and writes nothing" {
    modified_entry
    rm -rf "$STATE/backup"
    before=$(tree_digest "$SOF_ROOT")
    run_uninstall --dry-run
    assert_success
    assert_output_contains "[dry-run] regenerate /efi/EFI/steamos/grub.cfg"
    assert_output_contains "[dry-run] rm /efi/EFI/steamos/steamos-fixes-modules.img"
    [ "$(tree_digest "$SOF_ROOT")" = "$before" ]
}

@test "the early initrd goes after its boot entry is restored, never while an entry still loads it" {
    modified_entry
    run_uninstall --component audio
    assert_failure 1
    assert_output_contains "still loads it as early initrd"
    [ -f "$SOF_ROOT$IMG" ]
    slots_entry_is_modified "$SOF_ROOT$ENTRY"
    run_uninstall
    assert_success
    cmp "$SOF_ROOT$ENTRY" "$PRISTINE"
    [ ! -e "$SOF_ROOT$IMG" ]
    [ ! -d "$STATE" ]
}

@test "a stock entry without our marker is never touched, with or without a backup record" {
    fixture_grub
    printf '# steamos-fixes mentioned in a comment, but no marker\n' >>"$SOF_ROOT/efi/EFI/steamos/grub.cfg"
    cp "$SOF_ROOT/efi/EFI/steamos/grub.cfg" "$BATS_TEST_TMPDIR/stock"
    fixture_bls /esp/loader/entries/steamos-B.conf
    cp "$SOF_ROOT/esp/loader/entries/steamos-B.conf" "$BATS_TEST_TMPDIR/stock-bls"
    run_uninstall --keep-state
    assert_success
    [[ "$output" != *regenerat* ]]
    cmp "$SOF_ROOT/efi/EFI/steamos/grub.cfg" "$BATS_TEST_TMPDIR/stock"
    cmp "$SOF_ROOT/esp/loader/entries/steamos-B.conf" "$BATS_TEST_TMPDIR/stock-bls"
    # A backup record whose saved copy is gone does not make it ours either.
    mkdir -p "$STATE/backup/A"
    printf '/efi/EFI/steamos/grub.cfg\n' >"$STATE/backup/A/entry-path"
    run_uninstall
    assert_failure 1
    assert_output_contains "saved original missing; cannot restore"
    cmp "$SOF_ROOT/efi/EFI/steamos/grub.cfg" "$BATS_TEST_TMPDIR/stock"
}

@test "an entry whose early initrd was placed last (module override) is regenerated from the marker too" {
    modified_entry
    slots_entry_apply A "demo_arg=1" "$IMG" last 2>/dev/null
    grep -q 'initramfs-linux-neptune.img ${cmdpath}/steamos-fixes-modules.img$' "$SOF_ROOT$ENTRY"
    rm -rf "$STATE/backup"
    run_uninstall
    assert_success
    cmp "$SOF_ROOT$ENTRY" "$PRISTINE"
    [ ! -e "$SOF_ROOT$IMG" ]
}
