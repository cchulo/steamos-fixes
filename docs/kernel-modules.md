# Patched kernel modules

Component: `modules` (plan §4.1, §4.5). Each fix lists the modules it
needs in `patches/kernel/modules-<fix>.list`; the component builds, stages
and loads all of them.

## What gets rebuilt

| Module | Fix | Patch | Built with |
|---|---|---|---|
| `amdgpu` | `hdmi-frl` | `0001` VRR on an HDMI FRL link (`dc_is_hdmi_signal()` in `amdgpu_dm_update_freesync_caps()`) | `make M=drivers/gpu/drm/amd/amdgpu amdgpu.ko` |

Nothing else in the kernel is touched. The patched file lives under
`drivers/gpu/drm/amd/display/`, which the amdgpu Makefile compiles; the
build's scope rule allows a patch to touch the parent of its M= directory
for that reason (`build/kernel-sources.md`).

## Where it lives

| Path | What |
|---|---|
| `/etc/steamos-fixes/modules/<uname -r>/<module>.ko.zst` | patched modules for one kernel |
| `/etc/steamos-fixes/modules/<uname -r>/BUILD-INFO` | how they were built: kernel, vermagic, header source, source commit, patch hashes, `module.<name>=superseded` |
| `/etc/steamos-fixes/load-or-fallback` | the loader used by the modprobe hooks |
| `/etc/modprobe.d/steamos-fixes-modules.conf` | one `install <module> ... load-or-fallback <module>` line per module, generated from the lists |
| `/efi/EFI/steamos/steamos-fixes-modules.img` | the early initrd override, only for modules the initramfs loads (below) |
| `/var/lib/steamos-fixes/cache/` | downloaded release artifacts and build caches |

Nothing is written under `/usr`, and `depmod` is not run (it would write
under the read-only `/usr/lib/modules`). The hooks need neither. All of
these `/etc` paths are on the SteamOS keep list, so an update carries them
([update-survival.md](update-survival.md)).

## How loading works

When the kernel or udev asks for one of these modules, modprobe runs
`load-or-fallback <module>`. It loads the patched module only when
`/etc/steamos-fixes/modules/$(uname -r)/<module>.ko.zst` exists and its
vermagic matches the running kernel. In every other case (no build for
this kernel, mismatch, load failure) it loads Valve's module with
`modprobe --ignore-install`. An unknown kernel therefore always boots with
stock behaviour. Each decision is logged: `journalctl -t steamos-fixes`.

The patched modules are unsigned. SteamOS kernels have `CONFIG_MODULE_SIG`
on but not enforced, so they load and the kernel is marked tainted (`O`, `E`).

### Modules loaded from the initramfs

A module that is already loaded when the root filesystem's modprobe.d is
read never sees the hook (`load-or-fallback` exits 0 when
`/sys/module/<mod>` exists, on purpose: it must never unload anything).
SteamOS 3.9 builds its initramfs with the hooks `base udev plymouth holo
steam-deck modconf keyboard block filesystems resume`
(`/etc/mkinitcpio.conf.d/20-steamdeck.conf` in `steamos-customizations`);
the `steam-deck` hook lists storage, USB, HID and Deck platform modules,
**not amdgpu**, and there is no `kms` or `autodetect` hook. The expectation
is therefore that amdgpu loads from the root filesystem and the hook works.

**Measured on the Steam Machine:** `TODO(hw)` — run
`lsinitcpio -l /boot/initramfs-linux-neptune.img | grep -c amdgpu` and
record the answer here.

The component does not rely on the expectation. At apply time it lists the
slot's initramfs (`lsinitcpio`, else `bsdtar -tf`, else
decompress-and-`cpio -t`) and, for every listed module it finds there,
packs the staged `.ko.zst` into an uncompressed newc cpio at the
initramfs's own path (`usr/lib/modules/<kver>/kernel/...`, same
compression) and places it **after** the stock initramfs in the boot entry
(`lib/slots.sh`, `boot-entry set --initrd ... --last`). The kernel extracts
the archives in order, so our file replaces the stock one before udev
loads it. The override is only referenced while a staged build for the
slot's exact kernel exists, is validated as a cpio before the entry points
at it, and is dropped (image, manifest entry and boot-entry token) when no
build matches. `status --verbose` and `hdmi-frl status` say which path is
in use (`amdgpu: modprobe hook` or `early initrd`).

## When modules are fetched or built

For a kernel version, the sources are tried in this order:

1. **cache**: a build already staged, or a downloaded release artifact;
2. **release**: `modules-<uname -r>.tar.zst` from the project's GitHub
   release (the release matching the checkout's `VERSION` first, then
   `latest`), checked against its `.sha256`;
3. **container**: a local build in the Arch container with podman (needs a
   network connection; the whole amdgpu driver takes a long time).

This runs from `install`, from the RAUC post-install hook for the new
slot's kernel, and from the boot service when the running kernel has no
build. Failures are logged and never block an update or a boot.

A staged or cached build is used only if its BUILD-INFO lists exactly the
patches the installed checkout ships, with matching hashes; otherwise it is
refused and the next source is tried.

## What happens on a new SteamOS kernel

After an update that changes the kernel, every fix that needs a patched
module runs on stock behaviour until a build for the new kernel exists and
the machine has rebooted once more. If the device is online, the build is
fetched or made in the background and a notification asks for the reboot.
Offline, it waits for a connection or a manual `rebuild`. Meanwhile
`status` shows the fix as `degraded` with the reason. A SteamOS update is
never blocked for this unless `update-policy block` was chosen.

If Valve's new kernel already contains a patch, the build detects it (it
only reverse-applies, or the patch carries a `Valve-Upstream:` tag not
newer than the kernel's), skips it, and marks the module `superseded` in
`BUILD-INFO`: nothing is shipped for it and the stock module is used.

## Forcing a rebuild

```sh
sudo steamos-fixes.sh rebuild                          # running kernel
sudo steamos-fixes.sh rebuild --kver <uname -r>        # another kernel, e.g. the other slot
sudo steamos-fixes.sh rebuild --source container       # skip cache and release
sudo steamos-fixes.sh rebuild --channel jupiter-3.9
```

`rebuild` runs `self-update` first when available and online, so a fix for
a new kernel published in this repository is picked up. It prints
`BUILD-INFO` on success and keeps the early initrd override in step. Reboot
to use the new modules. Build details:
[`build/kernel-sources.md`](../build/kernel-sources.md).

## Kernel lockdown

If kernel lockdown is in `integrity` or `confidentiality` mode
(`/sys/kernel/security/lockdown`), for example with Secure Boot enforcing,
unsigned modules cannot load. The status then reports the fix as degraded
with a lockdown explanation and the stock modules stay in use; there is no
retry loop. Valve's kernels are built with `LOCK_DOWN_KERNEL_FORCE_NONE`.

## Known limitations

- Dependencies of a patched module are loaded through modprobe first, so
  they get the same treatment (their own hooks, or stock).
- The modules must be built for the exact `uname -r`, including Valve's
  `-g<commit>` suffix.
- The early initrd override lives on the slot's `efi` partition
  (`/efi/EFI/steamos`, vfat): a large module such as amdgpu takes tens of
  megabytes there. `TODO(hw)`: free space on the Steam Machine's efi
  partitions.

## Why the boot-time files live under `/etc/steamos-fixes`

udev loads modules before `/var` and `/home` are mounted. The state
directory (`/var/lib/steamos-fixes`, a symlink into `/home`) does not
exist yet at that point (measured on an Ally X20 with the sibling project:
a helper there failed with exit 127 and no driver loaded at all). The
modprobe helper and the staged `<kver>/*.ko.zst` are therefore installed
under `/etc/steamos-fixes/`, which the initramfs sets up before systemd
starts. In addition, every generated `install` line falls back to
`modprobe --ignore-install` on its own if the helper is missing or fails.
