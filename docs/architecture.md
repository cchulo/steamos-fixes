# Architecture

How the code is organised so that independent fixes can be developed and
tested separately, and how they fit together at install, boot, update and
uninstall time. The *why* behind every decision is in
[`STEAMOS-FIXES-PLAN.md`](../STEAMOS-FIXES-PLAN.md). The framework comes
from [ally-x20-steamos](https://github.com/cchulo/ally-x20-steamos).

## 1. One CLI, many commands

`steamos-fixes.sh` is a thin dispatcher. It parses global options
(`--root`, `--dry-run`, `--verbose`, `--yes`, `--i-know`), sources
`lib/common.sh`, then sources `cmd/<command>.sh` and calls
`cmd_<command>` (dashes become underscores). Adding a command means adding a
file; nothing else changes. The second line of each command file is
`# summary: ...`, which `help` prints.

## 2. The fixture-root contract

Every path the tool touches is built with `sof_path /absolute/path`, which
prefixes `SOF_ROOT`. On a live system `SOF_ROOT` is empty. In tests it is a
temporary directory; for the RAUC post-install hook it is the freshly staged
slot's mount point (`apply --slot <mount>`, which also exports
`SOF_APPLY_SLOT=1` so `lib/grub.sh` defers `update-grub`). Consequences:

- Code that hard-codes `/etc/...` or `/var/lib/...` without `sof_path` is a
  bug. Tests build fixture trees with `make_root` and `fixture_file`.
- "Is this SteamOS?" and "is this the right hardware?" questions are
  answered from files under the root (`/sys`, `/proc/cmdline`,
  `/usr/lib/modules`, …), never from the running system, so probes can be
  unit-tested with fixture trees.
- Privilege checks (`require_root`) are skipped when `SOF_ROOT` is set.
- The kernel version comes from `probe_running_kver`, which honours
  `SOF_KVER` (fixtures, and the new slot's kernel in post-install).

## 3. Components and fixes

A component is one self-contained piece. Framework components live in
`components/<name>.sh`; a fix lives in `fixes/<dir>/component.sh` (component
name = directory name with `-` → `_`). Each defines:

| symbol | required | role |
|---|---|---|
| `COMPONENT_DESCRIPTION` | yes | one line for `status`/`components` |
| `<name>_files` | yes | prints `src<TAB>dest<TAB>mode[<TAB>slot]` lines; `src` is relative to `overlay/`, `dest` is absolute without root prefix; may print nothing |
| `<name>_applies` | fixes | 0 = this hardware needs the fix, 1 = not applicable, 2 = cannot tell; prints a one-line reason. `apply` skips a fix that does not apply (never installs it); `status` says `n/a` |
| `<name>_probe` | yes | exit 0 if stock SteamOS now provides this (superseded), 1 if still needed, 2 unknown |
| `<name>_apply` | no | extra idempotent steps after files are copied (generated files, `grub.d` drop-ins, `systemctl enable`, downloads) |
| `<name>_status` | no | override the default `active / stock / superseded / n/a`; a fix adds `degraded` (installed, not effective on this kernel) |
| `<name>_status_detail` | no | one line explaining the status, shown under the row and in `status.json` |
| `<name>_remove` | no | extra cleanup before the manifest-driven file removal |

`lib/component.sh` drives them: `component_apply` copies every listed file
through `manifest_install_file`, then calls `<name>_apply`.
`component_status` runs the hardware probe and the superseded probe first,
then verifies every manifest entry for the component.

| component | plan | what it owns |
|---|---|---|
| `modules` | §4.1 | version-gated kernel module substitution for every `patches/kernel/modules-<fix>.list`: `load-or-fallback`, the generated modprobe.d drop-in, staging of built `.ko.zst`, lockdown detection, the early initrd override for modules the initramfs loads ([kernel-modules.md](kernel-modules.md)) |
| `update` | §4.3–4.5 | RAUC pre/post-install handlers, `system.conf` delimited block, the SteamOS keep list, boot service, user notifier, boot-entry reconcile, factory-reset fail-safes ([update-survival.md](update-survival.md)) |
| `hdmi_frl` (`fixes/hdmi-frl`) | §6 | the `grub.d` drop-in for `amdgpu.dcfeaturemask=0x402`, set only while a patched amdgpu is staged; the `hdmi-frl` command ([fixes/hdmi-frl.md](fixes/hdmi-frl.md)) |

Shared libraries: `lib/slots.sh` (A/B slots, boot-entry save/edit/restore
for the early initrd token, composite slot mount), `lib/grub.sh`
(`grub.d` drop-ins, `update-grub`/`holo-chroot` regeneration, `grub.cfg`
backup), `lib/rauc.sh` (handler registration), `lib/modules.sh` (module
lists, staging, resolution, initramfs detection, override rendering),
`lib/selfupdate.sh` and `lib/notify.sh` (release verification, notification
queue), `lib/status.sh` (the single `status.json` writer), `lib/retired.sh`
(removal of components a version no longer ships).

## 4. State directory and manifest

Everything persistent lives under `/var/lib/steamos-fixes` (`SOF_STATE_REL`,
the canonical path used everywhere). On SteamOS that path is a **relative
symlink to `/home/.steamos-fixes`**: `var-A`/`var-B` are separate
partitions that RAUC rsyncs across on update, while `/home` is shared and
large. `install` creates the symlink, `apply --slot` re-creates it in a
freshly staged slot, and the standalone uninstaller removes both the target
and the link. Fixture roots in tests keep a plain directory.

Files that the kernel needs before `/var` and `/home` are mounted (the
modprobe helper, staged modules) live under `/etc/steamos-fixes/`
(`SOF_EARLY_REL`) instead; see [kernel-modules.md](kernel-modules.md). Every
`/etc` path we own is on the generated SteamOS keep list
([update-survival.md](update-survival.md)).

`/var/lib/steamos-fixes/manifest` is JSON lines, one object per path we
created: `path`, `component`, `kind` (`file|symlink|dir`), `sha256`, `slot`,
`created_dir`, `ts`. `lib/manifest.sh` is the only writer. Rules enforced
there:

- `manifest_install_file` refuses to overwrite a path that exists but is not
  in the manifest. Since every path we own has a `steamos-fixes` prefix
  and lives in a drop-in directory, this can only fire on operator error.
- Parent directories we had to create are recorded as `dir` entries so
  uninstall can remove them if they end up empty.
- `manifest_verify` compares the current content with what we wrote; this is
  what `audit`, `status` and the boot service use to detect drift.
- Dry-run mode (`--dry-run`) performs no writes anywhere, including the
  manifest.

`uninstall` consumes the manifest newest-first, removes only entries whose
digest still matches (or `--force`), and hard-refuses a deny-list of paths
regardless of what the manifest says. The uninstaller is shipped as a
self-contained POSIX script at `/var/lib/steamos-fixes/uninstall.sh` so it
keeps working when the git checkout is gone.

## 5. Probes

`lib/probes.sh` has the generic building blocks (`probe_file_exists`,
`probe_file_contains`, `probe_stock_module_contains`, `probe_version_ge`).
Each fix composes them in `_applies` (hardware) and `_probe` (superseded).
A positive superseded probe makes `apply` run the fix's retire step (for
`hdmi-frl`: remove the kernel argument) and `status` report `superseded`;
the staged module and hooks are only removed by `uninstall --superseded`.

## 6. Install, boot, update, uninstall flows

```
install   = bootstrap clone -> apply (this slot) -> enable boot service -> register RAUC handlers
apply     = for each component: applies? -> probe -> install files via manifest, run _apply; write status.json
boot      = steamos-fixes.service: verify manifest, re-apply missing, pending update-grub,
            ensure modules for uname -r (detached rebuild), run probes, notify
update    = RAUC pre-install: self-update, make sure modules exist for the incoming kernel (policy degrade|block)
            RAUC post-install: apply --slot <new slot>, stage modules, holo-chroot update-grub for it
uninstall = reverse manifest, restore saved system.conf + boot entry, regenerate grub.cfg, daemon-reload
reset     = steamos-fixes-reset-cleanup.service: efi-cleanup.sh --all-slots on a pending factory reset
```

## 7. Conventions

- Bash 3.2 compatible shell (macOS dev hosts) and POSIX `sh` for anything
  that must run from recovery media (the standalone uninstaller, the EFI
  clean-up, `load-or-fallback`).
- `set -eu` in executables; libraries never call `exit` except through `die`.
- Tests: bats under `tests/<area>/*.bats`. `make check` runs lint and all
  tests; CI runs the same on Ubuntu.
- Policy tests in `tests/policy/hardening.bats` fail the build on
  `steamos-readonly`/`holo-readonly disable|enable`, writes under `/usr`,
  host `pacman`, tracked binaries, missing SPDX headers, and bash-4-only
  constructs.
