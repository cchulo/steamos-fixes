# steamos-fixes — out-of-tree fixes for stock SteamOS, design plan

Project name: **`steamos-fixes`** everywhere: repository, CLI
(`steamos-fixes.sh`), systemd units, drop-in file names, state directory
(`/var/lib/steamos-fixes`), early-boot directory (`/etc/steamos-fixes`),
shell prefix `SOF_` / `sof_`. Final.

Goal: carry small fixes for stock SteamOS (stable channel; today 3.9.5 with
`linux-neptune-72`) that Valve has not shipped yet, built from source,
surviving A/B updates, fully reversible, and hardware-agnostic: every fix
declares which hardware it applies to and is a no-op elsewhere. The first
fix targets the Valve Steam Machine; the framework is not tied to it.

Sibling project: [ally-x20-steamos](https://github.com/cchulo/ally-x20-steamos).
Its framework (CLI dispatcher, component model, manifest, RAUC handlers,
boot re-apply service, signed self-update, CI module builds, bats and VM
test harness, SPDX and policy tests) is reused here with the X20-specific
parts removed. Where this plan differs from the X20 plan it says so.

Conventions for the implementing agent:

- All git commits are authored by the repository owner only. No AI
  co-author or attribution lines in commits or patches.
- License: **GPL-2.0-only** (kernel patches are derivative works of GPL-2.0
  code). SPDX header on every source and script file; third-party files
  keep their license verbatim and are listed in `LICENSE.md` and
  `scripts/spdx-exceptions.txt`.
- Never ship a prebuilt `.ko` in git. CI attaches prebuilt artifacts to
  releases with SHA-256 sums and the exact source commit.
- Never edit a stock SteamOS file in place. Add prefixed drop-ins only,
  recorded in the manifest. Two documented exceptions (§4.4).
- Never toggle `steamos-readonly` / `holo-readonly`, not even for testing;
  a policy test fails the build if the toggling string appears anywhere.
  No `depmod`, no `mkinitcpio` against the root filesystem.
- Development happens on macOS without a VM: the shell libraries, components,
  patches, CI and docs are built here against fixture roots (bats). The VM
  harness is ported for a Linux host and CI; on-device verification happens
  on the owner's Steam Machine.

---

## 1. What is broken on stock SteamOS (as of 2026-11-12)

### 1.1 Native HDMI 2.1 FRL on the Steam Machine (fix `hdmi-frl`)

Kernel 7.2 has amdgpu HDMI 2.1 FRL (Fixed Rate Link), but Valve's
`linux-neptune-72` for SteamOS 3.9 stable (`7.2.7-valve2`) disables it
behind `amdgpu.dcfeaturemask` bit `0x400` (`DC_FRL_MASK`), per upstream
commit `c3778921bf0d` "drm/amd/display: Disable FRL and add module param to
enable it" (Fangzhi Zuo, AMD): FRL without VRR is a regression, so the
default stays TMDS (HDMI 2.0: 4K120 at 4:2:0 8 bpc on a 48 Gbit/s TV).
`amdgpu_dc_feature_mask` defaults to `2` in `7.2.7-valve2`
(`drivers/gpu/drm/amd/amdgpu/amdgpu_drv.c:221`).

Booting with `amdgpu.dcfeaturemask=0x402` enables FRL: 3840x2160 at 120 or
144 Hz, 10-bit 4:4:4, HDR, uncompressed. VRR is lost, because
`amdgpu_dm_update_freesync_caps()` in
`drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm.c` only handles
`sink->sink_signal == SIGNAL_TYPE_HDMI_TYPE_A`; an FRL-trained sink is
`SIGNAL_TYPE_HDMI_FRL` and skips the VRR range parsing. The fix is to test
`dc_is_hdmi_signal(sink->sink_signal)` instead.

Origin of the fix and credits: Tomasz Pakuła (GitHub Lawstorant), commit
`21d564d5a104` "Switch to signal type helper functions from DC — This fixes
HDMI VRR under FRL" on the `hdmi-7.2` branch of
[Lawstorant/linux](https://github.com/Lawstorant/linux); isolated to the
one-line freesync-caps hunk and verified on a Steam Machine by
[beaglemoo/steam-machine-hdmi21](https://github.com/beaglemoo/steam-machine-hdmi21)
(patch `0001`), reported in ValveSoftware/SteamOS issues
[#2809](https://github.com/ValveSoftware/SteamOS/issues/2809) and
[#2698](https://github.com/ValveSoftware/SteamOS/issues/2698). That
repository disables read-only mode and installs the rebuilt module under
`/lib/modules/<kver>/updates/`; **we explicitly do neither** (§4.4).

Valve has caught up in their next kernel: `7.2.10-valve1`
(`linux-neptune-72-7.2.10.valve1-3`, in `jupiter-main` as of 2026-11-12)
carries `152e053e341f` "[NOT-FOR-UPSTREAM] drm/amdgpu: Add full HDMI 2.1
support (SQUASHED SERIES)" (Pei-Hsin Yang, Valve), which enables
`DC_FRL_MASK` by default (`amdgpu_drv.c:222`), accepts
`SIGNAL_TYPE_HDMI_FRL` in `amdgpu_dm_update_freesync_caps()`, adds HF-VSDB
VRR parsing, ALLM, and the FRL hotplug fixes. Mainline Linux 7.4 enables
FRL by default with VRR/ALLM. **This fix is therefore expected to be
superseded by the next stable SteamOS kernel**; the design below retires it
cleanly (§5).

Motivation: a native HDMI 2.1 link instead of DP→HDMI dongles that drop
signal.

Not covered (documented limits, §6.3): DSC and QMS; ALLM is not set by
gamescope 3.16.x, so the TV's game mode must be selected by hand; FRL is
lost on the first hotplug after boot on `7.2.7` (beaglemoo patch `0002`,
mainline `c953b39f9487`; not shipped in v0.1, candidate for a later patch);
the unsigned module taints the kernel; kernel lockdown must be inactive;
an on-device rebuild needs network and a second reboot.

### 1.2 Kernels

| channel / repo | package | `uname -r` | FRL default | freesync FRL check |
|---|---|---|---|---|
| stable 3.9 (`jupiter-3.9`) | `linux-neptune-72-7.2.7.valve2-2` | `7.2.7-valve2-2-neptune-72-g31504582a073` | off | missing → **fix needed** |
| `jupiter-staging` | `linux-neptune-72-7.2.7.valve2-3` | `7.2.7-valve2-3-neptune-72-g31504582a073` | off | missing → fix needed |
| `jupiter-main` | `linux-neptune-72-7.2.10.valve1-3` | `7.2.10-valve1-3-neptune-72-g1b214a39f3cb` | **on** | present → superseded |
| `jupiter-main` | `linux-neptune-73-7.3.1.valve1-1` | `7.3.1-valve1-1-neptune-73-g205189b410aa` | off (not forward-ported) | file reorganised; not targeted yet |

The full `uname -r` (with the `-g<commit>` suffix, part of vermagic) is the
directory name inside the headers package; `build/kernels.txt` lists the
kernels CI builds, and `build/kernel-sources.md` the mirror layout.

---

## 2. Repository layout

```
steamos-fixes/
├── README.md, STEAMOS-FIXES-PLAN.md, LICENSE, LICENSE.md, VERSION, Makefile
├── steamos-fixes.sh                CLI dispatcher: cmd/<command>.sh -> cmd_<command>
├── lib/                            common, manifest, probes, component, slots, rauc,
│                                   modules, selfupdate, status, notify, retired, grub (new)
├── cmd/                            install apply status probe rebuild self-update uninstall
│                                   update-policy boot-entry audit boot notify rauc-handler
│                                   components version help, hdmi-frl (fix command)
├── components/                     framework components: modules.sh, update.sh
├── fixes/<name>/                   one directory per fix (§3): component.sh, README.md
│   └── hdmi-frl/
├── patches/kernel/                 NNNN-*.patch + modules-<fix>.list (read by lib/modules.sh
│                                   and build/build-modules.sh; one list per fix)
├── overlay/                        files installed on the device (manifest-tracked):
│                                   bin/load-or-fallback, systemd/*.service, rauc/*.hook
├── build/                          Containerfile, build-modules.sh, kernels.txt, kernel-sources.md
├── uninstall/                      standalone POSIX uninstaller + EFI clean-up
├── keys/, migrations/, scripts/    release signing keys, idempotent migrations, lint
├── tests/                          bats suites against fixture roots; policy tests
├── vm/                             QEMU/KVM harness (Linux host / CI only)
├── docs/                           architecture, kernel-modules, update-survival,
│                                   etc-survival (measured), fixes/hdmi-frl.md, ...
└── .github/workflows/              test.yml, build-modules.yml, vm-tests.yml
```

Renames from the X20 project, applied consistently: `ally-x20-steamos` →
`steamos-fixes`, `AX20_` → `SOF_`, `ax20_` → `sof_`, `.ax20-` → `.sof-`,
marker regex `ally-x20-steamos|x20` → `steamos-fixes`. Stripped: ACPI
override tooling, audio (UCM, firmware, TAS2783), InputPlumber, hid-asus-ally
and asus-armoury patches, power profiles shim, HDR (libdisplay-info,
gamescope), Xbox LED, the DMI board gate in `install`, device-specific docs
and VM guest scripts.

---

## 3. Fixes and the component contract

A **fix** is one self-contained change with a name `[a-z0-9-]+`, living in
`fixes/<name>/component.sh` (discovered next to the framework components in
`components/*.sh`; the component name is the directory name with `-` → `_`
for shell symbols). It defines:

| symbol | required | role |
|---|---|---|
| `COMPONENT_DESCRIPTION` | yes | one line |
| `<name>_files` | yes | `src<TAB>dest<TAB>mode[<TAB>slot]` lines; `src` relative to `overlay/` |
| `<name>_applies` | **new, required for fixes** | 0 = this hardware/software needs the fix, 1 = not applicable (no-op, status `n/a`), 2 = cannot tell. Reads sysfs/files under the fixture root only. Prints a one-line reason |
| `<name>_probe` | yes | 0 = stock SteamOS now provides it (superseded), 1 = still needed, 2 = unknown |
| `<name>_apply` | no | extra idempotent steps after the files are in place |
| `<name>_status` | no | override of the default status computation |
| `<name>_status_detail` | no | one line explaining the status (shown by `status`, written to `status.json`) |
| `<name>_remove` | no | extra cleanup before the manifest-driven removal |

Framework behaviour added for fixes (in `lib/component.sh`, `cmd/apply.sh`,
`lib/status.sh`):

- `apply` skips a fix whose `_applies` returns 1 (logged, status `n/a`)
  and never installs a fix whose probe says superseded (unless already
  installed, in which case the fix's own apply decides how to retire).
- Status vocabulary per fix: `active` (installed and effective),
  `degraded` (installed, but a part is not effective on the running kernel
  and the fix fell back to stock behaviour; `status_detail` says why and
  what will fix it), `superseded` (stock provides it), `stock` (not
  installed), `n/a` (hardware does not apply / cannot tell).
- `status --json` carries `status`, `detail` and `applies` per component.

The two framework components stay: `modules` (version-gated kernel modules
for every fix's `patches/kernel/modules-<fix>.list`) and `update` (RAUC
handlers, boot service, notifier, keep-list, boot-entry reconcile).

Per-fix structure (what a fix PR adds):

```
fixes/<name>/component.sh          contract above
fixes/<name>/README.md             short pointer; the user doc is docs/fixes/<name>.md
patches/kernel/NNNN-*.patch        git format-patch, original author kept, Derived-from section
patches/kernel/modules-<name>.list <patch>\t<M= dir>\t<ko>
overlay/...                        prefixed drop-ins
cmd/<name>.sh                      optional user command (e.g. hdmi-frl frl|tmds|status)
tests/components/<name>.bats       fixture roots: applies / not applies, stock lacks X / has X,
                                   apply/status/degrade/uninstall round-trip
docs/fixes/<name>.md               what it does, how to verify, known limits, how to turn it off
```

---

## 4. Mechanisms

### 4.1 Patched kernel modules (unchanged from X20, generalised)

Built out of tree against Valve's `linux-neptune-<series>-headers` package
from the SteamOS mirror, with the touched source directories from a blobless
sparse checkout of the exact Valve tag (`build/build-modules.sh`,
`build/kernel-sources.md`). Only the listed `.ko` targets are built. Output
per exact `uname -r`: `<kver>/{<module>.ko.zst,BUILD-INFO}`.

Staged under `/etc/steamos-fixes/modules/<kver>/` (a path that exists at
udev/modprobe time; `/var` → `/home` is not mounted yet) and loaded through
`/etc/modprobe.d/steamos-fixes-modules.conf` `install` hooks →
`/etc/steamos-fixes/load-or-fallback <module>`: vermagic-gated, any failure
falls back to `modprobe --ignore-install` (stock) and logs. Lockdown
(`integrity`/`confidentiality`) → stock, reported, no retry loop. No
`depmod`, nothing under `/usr`. An unknown kernel always boots with stock
behaviour.

**Change for `amdgpu`:** the M= directory is `drivers/gpu/drm/amd/amdgpu`
(where `amdgpu.ko` is built) while the patched file lives in
`drivers/gpu/drm/amd/display/amdgpu_dm/`, which that Makefile compiles via
`FULL_AMD_DISPLAY_PATH`. The X20 rule "every touched file is under the M=
dir" becomes "under the M= dir or under its parent directory
(`drivers/gpu/drm/amd`)"; the sparse checkout already fetches
`drivers/gpu`. The build is the whole amdgpu driver: tens of minutes in CI,
longer on the device; CI timeout raised accordingly.

**Modules loaded from the initramfs.** A module that is already loaded when
the root filesystem's modprobe.d is consulted never sees our hook
(`load-or-fallback` exits 0 when `/sys/module/<mod>` exists, on purpose).
SteamOS 3.9's initramfs is built with hooks `base udev plymouth holo
steam-deck modconf keyboard block filesystems resume`
(`steamos-customizations-jupiter`, `/etc/mkinitcpio.conf.d/20-steamdeck.conf`);
the `steam-deck` hook lists storage, USB, HID and Deck platform modules,
**not** `amdgpu`, and there is no `kms`/`autodetect` hook. The expectation
is therefore that `amdgpu` loads from the root filesystem and the modprobe
hook works. This **must be verified on the Steam Machine** before relying
on it (`lsinitcpio -l /boot/initramfs-linux-neptune.img | grep amdgpu`).
The framework detects it at apply time (`modules_in_initramfs <module>`,
reading the slot's initramfs with `lsinitcpio`, `bsdtar` or
`zstd|cpio`) and, when a listed module is in the initramfs, switches that
module to the **early-initrd override** path: the staged `.ko.zst` is
packed into an uncompressed newc cpio
(`/efi/EFI/steamos/steamos-fixes-modules.img`) at the same relative path
the initramfs uses (`usr/lib/modules/<kver>/kernel/...`), and the boot
entry lists it *after* the stock initramfs so the kernel's cpio extraction
overwrites the stock file. The override is only referenced when a build for
the slot's exact kernel is staged (kernel line checked), it is validated as
a cpio before the entry points at it, and it is removed from the entry when
no build matches. Status reports which path is in use
(`load path: modprobe hook | early initrd`). Documented finding and chosen
path: `docs/kernel-modules.md` and `docs/fixes/hdmi-frl.md`, filled in from
the device.

### 4.2 Kernel command line: `/etc/default/grub.d` drop-in

SteamOS's `update-grub` (`steamos-customizations-jupiter`) runs
`grub-mkconfig -o /efi/EFI/steamos/grub.cfg`; the stock cmdline comes from
`/etc/default/grub` + `/etc/default/grub-steamos`, and `/etc/default/grub.d/*.cfg`
drop-ins are honoured (beaglemoo relies on
`/etc/default/grub.d/hdmi-frl.cfg` on 3.9.5; confirmed on the device as
part of §7). The `hdmi-frl` fix writes
`/etc/default/grub.d/steamos-fixes-hdmi-frl.cfg` with
`GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} amdgpu.dcfeaturemask=0x402"`
(manifest-tracked) and runs `update-grub` on the booted slot. For a slot
that is not booted (RAUC post-install for the freshly written slot), the
drop-in is written into that slot's `/etc` through `apply --slot`, and its
`grub.cfg` is regenerated with the stock tool in the stock way:
`holo-chroot --partset <slot> -- update-grub` (the same mechanism Valve's
own post-install uses for `holo-finalize-install`), after our composite
mount of the slot is released. If that fails, the boot service repeats
`update-grub` on first boot of the new slot and the change applies one
boot later; the status says so.

`grub.cfg` is a stock-generated file; it is one of the two documented
exceptions (§4.4): the untouched `grub.cfg` of each slot is saved with its
sha256 before the first regeneration, and uninstall removes the drop-in,
regenerates with `update-grub`, and, when the saved copy still matches the
stock output modulo our argument (the common case), restores the saved
file byte-for-byte; otherwise the regenerated file stands and the
difference is logged. The X20 marker-based direct editing of `grub.cfg`
(`lib/slots.sh`) is kept for the early-initrd token only (§4.1), where
`update-grub` cannot help.

### 4.3 Surviving SteamOS A/B updates — **measured facts, not the X20 assumptions**

From `steamos-customizations-jupiter-3.9.20261021.1` (`/usr/lib/rauc/post-install.sh`,
`/usr/lib/holo/holo-sync-var`, `/usr/lib/rauc/atomic-update-keep.conf`):

1. RAUC writes the new rootfs to the other slot; the stock post-install
   handler reformats the other slot's `var` and runs `holo-sync-var all`,
   which rsyncs the booted `/var` into it **but prunes the `/etc` overlay
   upper directory to a keep list**: everything in `/etc` not matched by
   `/usr/lib/rauc/atomic-update-keep.conf` or a `/etc/atomic-update.conf.d/*.conf`
   drop-in is dropped (backed up to `/var/lib/steamos-atomupd/etc_backup`).
   The default keep list covers `/etc/systemd/system/*.service`,
   `*.wants/**`, `*.service.d/**`, `/etc/atomic-update.conf.d/*.conf`,
   users/groups, hostname, machine-id, NetworkManager, ssh keys… and **not**
   `/etc/modprobe.d/*`, `/etc/default/grub.d/*`, `/etc/<project>/**`,
   `/etc/systemd/user/*`, `/etc/rauc/*`.
2. It then runs `holo-chroot --partset <new> -- holo-finalize-install --no-kernel`,
   which regenerates the new slot's `grub.cfg` with `update-grub` **after**
   the sync, so a kept `grub.d` drop-in is honoured natively.
3. Only after that does our chained post-install handler run.

Consequences and design:

- The `update` component installs
  `/etc/atomic-update.conf.d/steamos-fixes.conf` listing every `/etc` path
  we own (`/etc/steamos-fixes/**`, `/etc/modprobe.d/steamos-fixes-*.conf`,
  `/etc/default/grub.d/steamos-fixes-*.cfg`,
  `/etc/systemd/user/steamos-fixes-*`, `/etc/systemd/user/*.wants/steamos-fixes-*`).
  Not `/etc/rauc/system.conf`: it must track Valve's version, so the RAUC
  block is re-added for the new slot by post-install (as in X20).
- The post-install handler still re-applies everything into the new slot
  (`apply --slot`), so the keep list is belt and the hook is braces; the
  boot service repairs anything that is still missing on first boot.
- `/var/lib/steamos-fixes` is a relative symlink to `/home/.steamos-fixes`
  (shared partition, large), so state, cache, checkout and backups are the
  same on both slots; the symlink itself is carried by the var rsync and
  re-created by `apply --slot`.
- `docs/etc-survival.md` records what the device actually does: the
  measurement is run on the Steam Machine across a real update
  (`vm/guest/measure-etc-survival.sh` ported as a plain guest script).

### 4.4 The two documented exceptions

1. **Boot entry** (`/efi/EFI/steamos/grub.cfg`, per slot): regenerated by
   `update-grub` from our `grub.d` drop-in (§4.2), and edited in place only
   for the early-initrd token (§4.1) with the X20 contract: original saved
   with sha256, deterministic marker edits, in-memory strip must reproduce
   the original byte-for-byte before writing, temp+rename, restore from the
   verified backup or by stripping.
2. **`/etc/rauc/system.conf`** handler registration: delimited block,
   single `[handlers]` section (steamos-atomupd's strict configparser),
   stock handlers chained, original saved and restored byte-for-byte.

### 4.5 Update policy: **degrade by default, never block** (differs from X20)

The X20 blocks updates by default because a missing module there means no
speakers and no controller. Here a missing module means "no VRR on FRL" at
worst, so a SteamOS update that brings a new kernel must always go through:

```
RAUC pre-install  (our handler, chained before the stock one)
  self-update (best effort) → incoming kernel known? → modules present? →
  try release asset, then on-device build → still none →
      policy degrade (default): exit 0, note state/pending-rebuild
      policy block   (opt-in):  exit 1, RAUC aborts, state/update-blocked
RAUC post-install (after the stock handler)
  mount the new slot, stage modules for its kernel if we have them,
  apply --slot (files, keep list, RAUC block, grub.d drop-in or its removal),
  release the mount, holo-chroot update-grub for that slot, pending-reboot-check
first boot of the new slot: steamos-fixes.service
  apply --missing-only; no modules for uname -r → detached rebuild
  (release asset for that kver first, container build from Valve headers
  second); probes; status.json; notification
```

Degraded state: the new kernel boots with stock modules. For `hdmi-frl`
that means **the FRL argument is not applied for that kernel** (the drop-in
is removed again in the slot that has no matching module, so the link runs
TMDS with VRR, which is stock behaviour) unless the user opted into
`hdmi-frl frl --without-vrr`. When a rebuild later succeeds, the boot
service re-applies the drop-in, runs `update-grub` and asks for one more
reboot. If no build is possible (headers not published, offline, new
kernel series), the fix stays `degraded` until a self-update of this
project ships support; `status` says exactly that. `update-policy block`
remains available as an opt-in, with `degrade --once` as its escape hatch.

### 4.6 Self-update, keys, migrations, notifications, uninstall

Unchanged from X20: signed-tag self-update with pinned keys
(`keys/`, `docs/self-update.md`), idempotent migrations, the user-session
notifier, the standalone POSIX uninstaller that removes exactly what the
manifest recorded (deny-list, hash-verified, works from the other slot or
recovery media) and restores the saved `grub.cfg`/`system.conf`.

---

## 5. Superseded detection and retiring a fix

Two independent signals per fix, both reported by `status --verbose`:

1. **Module patch already in Valve's tree.** `build/build-modules.sh`
   marks a patch `already-upstream` when it only reverse-applies, or when
   its description carries `Valve-Upstream: <tag>` and the target tag is
   that tag or newer (needed when Valve's version of the change differs
   textually, as `7.2.10-valve1` does for `hdmi-frl`). A module whose
   patches are all upstream is recorded `module.<name>=superseded` in
   `BUILD-INFO`, not built, and the stock module is used.
2. **Per-fix probe for the non-module parts.** `hdmi-frl` is superseded
   when the running stock kernel enables FRL by default. Detection, in
   order: (a) a version threshold table in the component
   (`7.2.10-valve1` for `neptune-72`, verified from Valve's
   `amdgpu_drv.c`; later series added as they are checked); (b) when the
   cmdline carries no `amdgpu.dcfeaturemask`, the live default read from
   `/sys/module/amdgpu/parameters/dcfeaturemask` having bit `0x400` set.
   `modinfo` does not expose parameter defaults and the stock `.ko`
   contains no usable string, so (a) is the authoritative signal while the
   drop-in is active; the table and the reasoning are documented in
   `docs/fixes/hdmi-frl.md`.

When a fix is superseded, `apply` (and the boot service) runs the fix's
retire step: `hdmi-frl` removes its `grub.d` drop-in, regenerates
`grub.cfg`, leaves the stock module in use, and `status` reports
`superseded` with the reason. The modprobe hook and staged modules of a
superseded module are inert (`BUILD-INFO` says superseded, nothing is
loaded) and go away with `uninstall --superseded`, which the user runs when
they want the project gone.

---

## 6. Fix #1: `hdmi-frl`

### 6.1 Deliverables

- `patches/kernel/0001-drm-amd-display-use-dc_is_hdmi_signal-in-freesync-caps.patch`
  (git format-patch; `From: Tomasz Pakuła <forest10pl@gmail.com>`; subject
  and body name the origin commit, the SteamOS issues and the beaglemoo
  isolation; `Valve-Upstream: 7.2.10-valve1`; `Derived from:` section).
  `patches/kernel/modules-hdmi-frl.list`:
  `0001-… <TAB> drivers/gpu/drm/amd/amdgpu <TAB> amdgpu.ko`.
- `build/kernels.txt`: the stable kernel `7.2.7-valve2-2-neptune-72-g31504582a073 jupiter-3.9`,
  plus staging `7.2.7-valve2-3-… jupiter-staging` and main
  `7.2.10-valve1-3-… jupiter-main` (the last one yields a `superseded`
  BUILD-INFO, so devices on that kernel stage a clean "nothing to load").
  CI builds and attaches `modules-<kver>.tar.zst` for every listed kernel.
  `build-modules.sh` learns the per-release repos (`jupiter-3.9`) and
  `lib/modules.sh` maps the device's branch + `VERSION_ID` to one.
- `fixes/hdmi-frl/component.sh`: applies when a native HDMI connector
  exists on an amdgpu device (`/sys/class/drm/card*-HDMI-A-*` whose
  `device/driver` is `amdgpu`); installs the `grub.d` drop-in and runs
  `update-grub`; status `active` only when the argument is on the running
  cmdline **and** the patched `amdgpu` is loaded (or `--without-vrr` was
  chosen); `degraded` with a reason otherwise; superseded per §5.
- `cmd/hdmi-frl.sh`: `steamos-fixes hdmi-frl frl [--without-vrr] | tmds | status`.
  `status` prints: mode configured vs running (`/proc/cmdline`), module
  (stock/patched, taint), `vrr_capable` (from
  `/sys/kernel/debug/dri/*/HDMI-A-*/vrr_range` when root, else
  `modetest -M amdgpu -c` when present), current mode and bpc
  (`/sys/class/drm/card*-HDMI-A-*/modes`, `/sys/kernel/debug/dri/*/crtc-*/amdgpu_current_bpc`),
  and a pointer to the gamescope log.
- `docs/fixes/hdmi-frl.md`: what it does, how to verify, known limits,
  the initramfs finding, how to go back to TMDS.
- `docs/etc-survival.md`: measured on the Steam Machine (template until then,
  every cell marked `TODO(hw)`).

### 6.2 Flows

```
install  → applies? no → "hdmi-frl: n/a (no native HDMI connector on an amdgpu device)"
         → yes → modules staged for uname -r (release asset / build) → drop-in + update-grub
         → reboot → cmdline has 0x402, patched amdgpu loaded → active; VRR 40-144 on an LG C4
SteamOS update, same kernel → keep list + post-install keep the drop-in; nothing to do
SteamOS update, new kernel, asset available → post-install stages it, drop-in kept → active after reboot
SteamOS update, new kernel, no asset → post-install removes the drop-in in the new slot (TMDS, stock)
         → first boot: detached rebuild → success → drop-in back, update-grub, "reboot to enable FRL"
         → failure → degraded: "no patched amdgpu for <kver>; waiting for a release that supports it"
Valve kernel enables FRL by default (7.2.10-valve1) → superseded: drop-in removed, stock module, VRR native
uninstall → drop-in removed, grub.cfg restored, hooks/modules removed, RAUC block restored
```

### 6.3 Known limits (documented, not fixed in v0.1)

No DSC/QMS. ALLM not set by gamescope (manual TV game mode). FRL lost on
the first hotplug after boot on `7.2.7` (candidate patch `0002`). Unsigned
module taints the kernel (`O`, `E`). Kernel lockdown must be inactive
(`modules_lockdown_active`). An on-device rebuild needs network, podman
and a second reboot, and the full amdgpu build is long. One boot in the
"wrong" mode is possible when post-install cannot regenerate the new
slot's `grub.cfg`.

---

## 7. Test plan

Unit (bats, fixture roots, macOS bash 3.2 and Linux bash 5; `make check`):

- policy: `steamos-readonly|holo-readonly (disable|enable)` string absent;
  no writes under `/usr`; no host `pacman`; SPDX headers; no tracked
  binaries; no bash-4-only constructs; every component/fix defines
  `_applies` and `_probe`; every patch is in a `modules-*.list`.
- lib: manifest, component (discovery in `components/` and `fixes/*/`),
  probes, slots (boot entry save/apply/strip/restore, initrd token),
  rauc (single `[handlers]`, chaining, byte-for-byte restore), modules
  (lists, BUILD-INFO matching, staging, superseded, `modules_in_initramfs`
  on a synthetic cpio, override-initrd rendering), grub (drop-in render,
  arg detection in a fixture `grub.cfg`, backup/restore decision),
  selfupdate, status (vocabulary incl. `degraded`, JSON shape).
- cmd: apply (`n/a` skip, superseded retire), status, probe,
  update-policy (default `degrade`, `block` opt-in, `--once`), rauc-handler
  pre/post-install with `SOF_INCOMING_KVER` and a fixture slot root
  (degrade path removes the drop-in when no module is staged; keeps it when
  staged), boot (detached rebuild kick, notify file), install, self-update,
  uninstall (standalone and via CLI; restores `grub.cfg` and `system.conf`
  byte-identically; refuses the deny-list).
- fix `hdmi-frl`: applies/not-applies fixtures (HDMI-A on amdgpu, DP only,
  HDMI on i915), probe thresholds (7.2.7 needed, 7.2.10 superseded, live
  dcfeaturemask default), apply writes the drop-in and records it, status
  matrix (active / degraded reasons / superseded / n/a / stock),
  `--without-vrr`, `tmds` removes it, `status` output parsing with fixture
  sysfs/debugfs files.
- patches: format-patch shape, author kept, `Valve-Upstream:` line,
  `Derived from:` section, no AI attribution, touched files under the M=
  dir or its parent, list consistency; `git apply --check` against the
  7.2.7-valve2 copy of the touched hunk's context (fixture file in
  `tests/patches/fixtures/`).
- build: `build-modules.sh` list parsing, M=-parent rule, `Valve-Upstream`
  handling (existing tests ported).

CI: `test.yml` (lint + bats on Ubuntu), `build-modules.yml` (every kernel in
`build/kernels.txt`, artifacts and release assets, 180 min timeout),
`vm-tests.yml` (skipped until a base image exists, as in X20).

On the Steam Machine (owner, not automatable here; recorded in docs):

1. `uname -r`, `cat /proc/cmdline`, `lsinitcpio -l /boot/initramfs-linux-neptune.img | grep -c amdgpu`,
   `grep -n grub.d /usr/bin/grub-mkconfig /etc/default/grub`, `ls /etc/default/grub.d`,
   `cat /sys/kernel/security/lockdown`, `ls /sys/class/drm/ | grep HDMI`,
   `cat /sys/module/amdgpu/parameters/dcfeaturemask`.
2. `install`, `status --verbose`, reboot, `hdmi-frl status`, `vrr_range`,
   `modetest -M amdgpu -c`, gamescope log mode/bpc.
3. `measure-etc-survival.sh before` → real SteamOS update (stable → stable,
   or beta opt-in) → `after` → fill `docs/etc-survival.md`; confirm the
   post-install log, `pending-reboot-check`, the new slot's `grub.cfg`,
   the degrade path with the network blocked.
4. `uninstall`: `grub.cfg` and `system.conf` byte-identical to the saved
   originals; `audit` clean.

---

## 8. Milestones

1. Plan (this file). Framework ported and renamed, X20 parts stripped,
   tests green on macOS. *(this PR)*
2. Framework changes: `fixes/` discovery and `_applies`, `degraded` status,
   degrade-by-default policy, keep-list, `holo-*` tool names,
   `modules_in_initramfs` + override initrd, `lib/grub.sh`, M=-parent rule.
   *(this PR)*
3. `hdmi-frl`: patch, list, kernels, component, command, docs, tests.
   *(this PR)*
4. First on-device run on the Steam Machine: §7 steps 1–2; fill in the
   initramfs finding and the `grub.d` confirmation; tag v0.1.0 with CI
   assets for the three kernels.
5. Real update survival measured (§7 step 3), `docs/etc-survival.md`
   completed; degrade path exercised.
6. Candidate second patch (FRL hotplug re-verify) and the next fix.

## References

- Valve/AMD: `c3778921bf0d` (FRL disabled by default, `DC_FRL_MASK`),
  `152e053e341f` in `7.2.10-valve1` (full HDMI 2.1: FRL default on, VRR,
  ALLM), mainline `c953b39f9487` (FRL re-verify on hotplug).
- Tomasz Pakuła, Lawstorant/linux `21d564d5a104` (the fix); beaglemoo/steam-machine-hdmi21
  (isolation, Steam Machine verification, `grub.d` drop-in, keep-list finding).
- ValveSoftware/SteamOS issues #2809, #2698.
- steamos-customizations-jupiter 3.9.20261021.1: `post-install.sh`,
  `holo-sync-var`, `atomic-update-keep.conf`, `update-grub`, `holo-chroot`,
  `holo-finalize-install`, `/etc/mkinitcpio.conf.d/20-steamdeck.conf`,
  `/usr/lib/initcpio/install/steam-deck`.
- ally-x20-steamos (framework origin), icedream/steamos-permanent-mods
  (RAUC hook pattern).
