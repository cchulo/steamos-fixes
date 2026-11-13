# Uninstall and audit

`steamos-fixes` promises a byte-identical system after removal. This page
describes how that is achieved, what the guarantees are, and how to run the
uninstaller from any state, including without the git checkout.

## Quick reference

```sh
sudo steamos-fixes.sh uninstall --dry-run     # show every action, change nothing
sudo steamos-fixes.sh uninstall               # remove everything, prompt first
sudo steamos-fixes.sh uninstall --superseded  # only components stock SteamOS now provides
sudo steamos-fixes.sh uninstall --component hdmi_frl
sudo steamos-fixes.sh audit                   # manifest vs filesystem; exit 1 on drift

# Without the checkout (recovery media, other slot, broken install):
sudo sh /var/lib/steamos-fixes/uninstall.sh --yes
sudo sh /var/lib/steamos-fixes/uninstall.sh --root /mnt/other-slot --yes
```

## Two layers

1. **`cmd/uninstall.sh`** (needs the checkout): decides *which* components to
   remove (`--superseded` runs every probe and selects those reporting
   `superseded`), runs each component's `_remove` hook (stop services, drop
   caches), then calls the standalone script.
2. **`uninstall/uninstall.sh`**, copied to `/var/lib/steamos-fixes/uninstall.sh`
   at install time: POSIX `sh`, depends only on coreutils, awk, sed, grep,
   find and a sha256 tool. It parses the manifest itself, so it keeps working
   when the checkout is deleted, when `jq`/`python3` are unavailable, and from
   SteamOS recovery media. It parses its whole body before running (`main` at
   the end), so deleting its own file mid-run is safe.

## What the standalone uninstaller does, in order

1. **Restore saved originals** from `/var/lib/steamos-fixes/backup/<id>/`
   (the two documented exceptions: boot entries and the RAUC
   `system.conf` block). Each backup has `original` and `meta`
   (`path=`, `sha256=` of the original, `type=file|block`, optional
   `component=`).
   - `type=file`: restored byte-for-byte, only if `original` still hashes to
     the recorded sha256. A corrupt or missing backup is reported, never
     guessed, except for a boot entry that carries the `lib/slots.sh`
     marker: that one is regenerated from the marker (below).
   - Boot entries (`backup/<slot>/` layout, and also a marked
     `/efi/EFI/steamos/grub.cfg` or `/esp/loader/entries/*.conf` with no
     backup record at all): when the saved copy is missing, corrupt or older
     than the live entry, the original is rebuilt the way
     `slots_entry_restore` does it: drop the `# steamos-fixes…` marker
     lines, remove the kernel args and the early-initrd token the marker
     records, honour its `noeol` flag, and compare the result with its
     `orig-sha256`. A match is written (temp file + rename, `sync`); a
     mismatch is written too, since it no longer carries anything of ours,
     with a warning that it differs from the recorded original digest. A
     file without the marker is never touched.
   - `type=block`: the `# >>> steamos-fixes` … `# <<< steamos-fixes`
     block is stripped from the live file. If the result equals the saved
     original, the file is back to stock; if not (Valve changed it since),
     the stripped file is kept and a warning says so.
   - Backups pointing under `/usr`, `/dev`, `/proc`, `/sys`, `/run` or at a
     relative path are refused.
2. **Walk the manifest newest-first** and remove files and symlinks:
   - a file is removed only if its sha256 still equals what we wrote;
     otherwise it is skipped (reported) unless `--force`;
   - a symlink is removed only if its target still matches; the target is
     never followed;
   - a path that is missing is fine ("already gone"), so a partial manifest
     from an interrupted install is handled;
   - the early initrd override on the efi partition
     (`steamos-fixes-modules.img`, component `modules`) is skipped while a
     boot entry still loads it through our marker (e.g. `--component
     modules` without `update`), so an entry never points at a missing
     initrd. On a full run step 1 has already restored the entry, so the
     image goes.
3. **Remove directories** we created, deepest first, only while empty.
   Top-level and system directories are never removed even if a manifest
   claims we created them.
4. **Update the manifest**: entries of handled components are dropped unless
   the file still exists (skipped), so a re-run is a no-op and `audit` stays
   truthful.
5. **Remove the state directory** `/var/lib/steamos-fixes` (and
   `/opt/steamos-fixes`) on a full run, unless `--keep-state` or anything
   was skipped (then it is kept so the skipped items stay inspectable).
6. **Regenerate `grub.cfg`** when a `/etc/default/grub.d` drop-in was
   removed (live root): `update-grub`, then a comparison with the stock
   copy saved under `backup/grub/<slot>/` (byte-identical unless SteamOS
   changed the stock file in between, which is reported); without
   `update-grub` the saved copy is restored when it verifies. On another
   root it tells you to run `holo-chroot --partset <slot> -- update-grub`
   (or to boot that slot once: the boot service does it).
7. On the live root: `systemctl daemon-reload` (never `depmod` or
   `ldconfig`); reboot only with `--reboot`.

Exit codes: `0` everything removed, `1` finished with skipped items (the
messages say why), `2` usage error or fatal condition.

## Factory reset and leftovers

A SteamOS factory reset wipes the `var` partitions of both slots (and with
them the `/etc` overlay, whose upper dir lives on `var`) and `/home`, so our
state directory, manifest, backups and the standalone uninstaller copy are
gone, and so is the `grub.d` drop-in with our kernel argument (it lives in
`/etc`). It does not touch the efi partitions: the slot's
`/efi/EFI/steamos/grub.cfg` can still carry our marker lines and the
early-initrd token, and the module override image
`/efi/EFI/steamos/steamos-fixes-modules.img` can still sit next to it (the
same applies to anyone who deleted the state directory by hand). Both
`steamos-fixes.sh uninstall` and the standalone uninstaller rebuild the
original entry from the marker when no usable backup exists, as described
in step 1. Run the uninstaller before a factory reset anyway: with the
state directory still there everything is removed and verified against its
recorded hashes.

Two fail-safes cover a reset without an uninstall (both installed by the
`update` component, which owns the boot entry):

- **The EFI clean-up script.** `uninstall/efi-cleanup.sh` is copied next to
  the entry it restores, as `/efi/EFI/steamos/steamos-fixes-cleanup.sh`,
  on every slot whose `grub.cfg` we modify (the booted slot on `apply`, the
  new slot from the RAUC post-install handler). It lives on the efi
  partition, so it survives the reset. After a reset, run it on the booted
  slot (vfat has no exec bit, hence `sh`):

  ```sh
  sudo sh /efi/EFI/steamos/steamos-fixes-cleanup.sh            # this slot
  sudo sh /efi/EFI/steamos/steamos-fixes-cleanup.sh --all-slots # both slots
  ```

  It rebuilds `grub.cfg` from the marker (same strip as the uninstaller,
  compared to the recorded original digest, written via temp file and
  rename; a digest mismatch is reported but the stripped entry is still
  written), deletes `steamos-fixes-modules.img` once no `*.cfg` in that
  directory references it, then deletes itself (`--keep` keeps it,
  `--dry-run` only prints). It never touches a file without our marker,
  nor anything outside its own directory (or the directory given as
  argument; `--all-slots` mounts `/dev/disk/by-partsets/{A,B}/efi`
  privately under `/run`). Nothing to do is exit 0.
- **The shutdown hook.** `steamos-fixes-reset-cleanup.service` is a
  oneshot that does nothing while the system runs. When it is stopped at
  shutdown or reboot and a factory reset is pending (Steam's reset leaves
  `efi/steamos/factory-reset/*.cfg` on the ESP and wipes at the next boot),
  it runs the clean-up with `--all-slots`, so the reset boots into a
  stock grub.cfg on both slots, without the override image and without the
  clean-up script itself (nothing of ours is left on the EFI partitions). Without a
  pending reset the stop only mounts the ESP privately, finds no marker and
  returns (bounded by `TimeoutStopSec=20s` in any case). The partitions are
  mounted from `/dev/disk/by-partsets` rather than through the `/efi` and
  `/esp` automounts, which may have expired or be going away during
  shutdown. Only the clean-up script itself stays behind on each efi
  partition; it has nothing left to do and can be deleted with
  `sudo sh /efi/EFI/steamos/steamos-fixes-cleanup.sh --all-slots`.

The uninstaller removes both as recorded manifest files (the remove hook
stops the unit first).

## Deny-list (applied even to manifest entries)

A manifest can be corrupted or crafted. Regardless of what it says, the
uninstaller refuses to touch:

- anything under `/usr`, `/boot`, `/dev`, `/proc`, `/sys`, `/run`;
- `/etc/fstab`, `/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/hostname`,
  `/etc/machine-id`;
- `/etc/rauc/**` (only the delimited-block strip may change
  `system.conf`: our blocks go, a stock handler line we commented out
  inside one comes back);
- Steam data (`~/.steam`, `~/.local/share/Steam`);
- the ESP (`/efi`, `/esp`) except files whose name contains
  `steamos-fixes`;
- stock systemd `.wants`/`.target` wiring;
- relative paths, paths containing `..`;
- **any path that does not contain `steamos-fixes`** in its name. Every
  file this project installs carries that marker (drop-ins are prefixed;
  the early initrd override is `steamos-fixes-modules.img`, the EFI
  clean-up script `steamos-fixes-cleanup.sh`). A component that installs a
  file without the marker is a bug: `tests/uninstall` will refuse to
  remove it.

Refused entries are printed as `REFUSED <path>: <reason>` and counted as
skipped.

## Audit

`steamos-fixes.sh audit [--json]` prints one line per problem:

| state | meaning |
|---|---|
| `modified` | file content differs from what we wrote (user edit, or another tool) |
| `missing` | manifest entry whose file is gone (boot service will re-apply) |
| `unexpected` | a file named like ours in a drop-in directory or `~/.config` that is not in the manifest |

Clean audits print a one-line summary and exit 0; any problem exits 1.

## Tests

`tests/uninstall/standalone.bats` covers the broken states from the plan
(§5.2 rule 6): partial manifest, modified files, mid-update, running from the
state-dir copy with the checkout gone, foreign symlink targets, crafted
manifests against the deny-list, corrupt/missing backups, boot entries
regenerated from the marker with no backup (grub, BLS, no final newline,
digest mismatch, dry-run, the early initrd kept while referenced), block stripping
with and without upstream changes, byte-identical before/after snapshots and
idempotent re-runs. `tests/uninstall/cmd.bats` covers `--superseded`,
component hooks, `--dry-run`, the read-only-root refusal and `audit`.
