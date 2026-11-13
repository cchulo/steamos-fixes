# hdmi-frl: HDMI 2.1 FRL with VRR on the native HDMI port

Component `hdmi_frl` (`fixes/hdmi-frl/`), command `steamos-fixes hdmi-frl`.
Plan: [`STEAMOS-FIXES-PLAN.md`](../../STEAMOS-FIXES-PLAN.md) §1.1, §6.

## The problem

SteamOS 3.9 stable ships `linux-neptune-72` (`7.2.7-valve2`). Kernel 7.2's
amdgpu can drive an HDMI 2.1 TV over FRL (Fixed Rate Link, 48 Gbit/s), but
Valve keeps FRL off behind `amdgpu.dcfeaturemask` bit `0x400`
(`DC_FRL_MASK`, upstream commit `c3778921bf0d`), because FRL without VRR
would be a regression. Stock, the native HDMI port runs TMDS: 4K120 at
4:2:0 8-bit at best, and HDR only in that mode.

With `amdgpu.dcfeaturemask=0x402` the link trains at FRL: 3840x2160 at 120 Hz
with up to 12-bit 4:4:4, or 144 Hz at 10-bit 4:4:4, uncompressed, HDR.
VRR disappears, because `amdgpu_dm_update_freesync_caps()` only parses the
HDMI VRR range for `SIGNAL_TYPE_HDMI_TYPE_A` and an FRL sink is
`SIGNAL_TYPE_HDMI_FRL`. Testing `dc_is_hdmi_signal()` instead brings VRR
back (40-144 Hz on an LG C4 as measured by beaglemoo).

## What the fix does

1. **Kernel module.** `patches/kernel/0001-drm-amd-display-use-dc_is_hdmi_signal-in-freesync-caps.patch`
   (author Tomasz Pakuła; see the patch for the derivation) is built into
   `amdgpu.ko` out of tree against Valve's headers for every kernel in
   `build/kernels.txt`. The `modules` component stages it under
   `/etc/steamos-fixes/modules/<uname -r>/` and loads it through the
   modprobe hook, or through the early initrd override if the initramfs
   loads amdgpu ([kernel-modules.md](../kernel-modules.md)).
2. **Kernel argument.** `/etc/default/grub.d/steamos-fixes-hdmi-frl.cfg`
   adds `amdgpu.dcfeaturemask=0x402`; `update-grub` regenerates the slot's
   `grub.cfg`. The stock `grub.cfg` is saved first
   (`/var/lib/steamos-fixes/backup/grub/<slot>/`). The drop-in is on the
   SteamOS keep list, so an update carries it to the new slot and Valve's
   own `holo-finalize-install` regenerates that slot's `grub.cfg` with it.

The argument is only set while a patched amdgpu for the kernel in question
is staged: FRL without the patched module is FRL without VRR, the exact
regression Valve avoided. Otherwise the drop-in is removed, the link runs
TMDS with VRR (stock behaviour), and `status` says `degraded` and why.
`hdmi-frl frl --without-vrr` overrides that if you prefer 4K144 without VRR.

## Applies to

A native HDMI connector (`/sys/class/drm/card*-HDMI-A-*`) whose card is
driven by `amdgpu`. Anything else (DP-only cards, Intel/NVIDIA GPUs, a Steam
Deck's DP-over-USB-C) reports `n/a` and nothing is installed.

## Commands

```sh
sudo steamos-fixes.sh hdmi-frl status          # what is configured, what runs, VRR range, mode, bpc
sudo steamos-fixes.sh hdmi-frl frl             # want FRL (default once installed); reboot
sudo steamos-fixes.sh hdmi-frl frl --without-vrr   # FRL even when no patched amdgpu is available
sudo steamos-fixes.sh hdmi-frl tmds            # back to the stock link; reboot
sudo steamos-fixes.sh status --verbose         # all fixes, with the detail line
```

## Status and what it means

| status | meaning |
|---|---|
| `active` | the FRL argument is on the running command line and the patched amdgpu is loaded (or `--without-vrr`) |
| `degraded` | installed, but one of: no patched amdgpu for this kernel yet (TMDS with VRR until a build exists), argument set but not yet booted, FRL on but the stock module loaded (loader fallback: no VRR), kernel lockdown. The detail line says which |
| `stock` | not installed, or `tmds` chosen |
| `superseded` | the kernel enables FRL by default (see below); the drop-in has been removed |
| `n/a` | no native HDMI connector on an amdgpu device |

## Verifying on the machine

```sh
cat /proc/cmdline | tr ' ' '\n' | grep dcfeaturemask          # 0x402 when FRL is requested
sudo cat /sys/kernel/debug/dri/*/HDMI-A-1/vrr_range           # Min/Max; 0/0 means no VRR
modetest -M amdgpu -c | grep -A3 vrr_capable                  # without root
cat /sys/class/drm/card*-HDMI-A-*/modes | head -n1            # preferred mode
sudo cat /sys/kernel/debug/dri/*/crtc-*/amdgpu_current_bpc    # driven colour depth
sudo grep -A2 '^HPO:' /sys/kernel/debug/dri/*/amdgpu_dm_dtn_log   # FRL lanes/rate when linked at FRL
journalctl -b -t steamos-fixes                                # which amdgpu the loader picked
cat /sys/module/amdgpu/taint                                  # O E with the out-of-tree build
grep -E 'gamescope.*(mode|bpc|HDR)' ~/.steam/steam/logs/console-linux.txt | tail
```

`hdmi-frl status` prints the same facts in one place.

## Superseded detection

The fix retires itself when the running kernel enables FRL by default,
decided in this order:

1. **Version threshold** (authoritative while our argument is on the command
   line): Valve's `7.2.10-valve1` and any later `7.2.x-valveN` enable
   `DC_FRL_MASK` by default (`drivers/gpu/drm/amd/amdgpu/amdgpu_drv.c`,
   `amdgpu_dc_feature_mask = DC_MULTI_MON_PP_MCLK_SWITCH_MASK | DC_FRL_MASK`,
   from `152e053e341f` "[NOT-FOR-UPSTREAM] drm/amdgpu: Add full HDMI 2.1
   support (SQUASHED SERIES)"), and so does mainline from 7.4. Valve's
   `7.3.1-valve1` has it **off** again (the series was not forward-ported),
   so 7.3 is not in the table. The table lives in
   `fixes/hdmi-frl/component.sh` (`HDMI_FRL_DEFAULT_ON_TAGS`).
2. **Live default**: when the command line carries no `amdgpu.dcfeaturemask`
   and `/sys/module/amdgpu/parameters/dcfeaturemask` has bit `0x400` set.

`modinfo` does not expose parameter defaults and the stock `.ko` contains no
string that would reveal it, which is why the table exists. The module
patch has its own signal: the build marks it `already-upstream` on
`7.2.10-valve1` and later through the `Valve-Upstream:` line in the patch
(the text no longer reverse-applies there because Valve rewrote the
function).

When superseded, `apply` (and the boot service) removes the drop-in and
regenerates `grub.cfg`; the staged module directory stays inert until
`uninstall --superseded`.

## SteamOS updates

- Same kernel: the keep list carries the drop-in; nothing to do.
- New kernel with a release asset for it: the RAUC post-install handler
  stages it into the new slot and keeps the drop-in; `active` after the
  reboot.
- New kernel without an asset: the handler removes the drop-in in the new
  slot (TMDS with VRR, stock) and regenerates its `grub.cfg` with
  `holo-chroot --partset <slot> -- update-grub`. On the first boot the
  service starts a rebuild (release asset, then an on-device container
  build from Valve's headers); when it lands, the drop-in comes back and a
  notification asks for one more reboot. Until then: `degraded`.
- If the handler could not regenerate the new slot's `grub.cfg`, the boot
  service does it on that slot's first boot and the change applies one boot
  later; `status` says so.

Details: [update-survival.md](../update-survival.md).

## Known limits

- No DSC, no QMS: 4K144 is 10-bit at most; 4K120 reaches 12-bit.
- ALLM is not set by gamescope 3.16.x, so the TV's game mode has to be
  selected by hand (beaglemoo's optional patch `0003` adds a module
  parameter for it; not shipped here).
- On `7.2.7` the link falls back to TMDS on the first hotplug after boot
  (a TV re-handshake after wake, an input switch). Fix known
  (beaglemoo `0002`, mainline `c953b39f9487`); candidate for a later patch.
- The patched module is unsigned: the kernel is tainted (`O`, `E`).
- Kernel lockdown (`integrity`/`confidentiality`) must be inactive; Valve's
  kernels ship `LOCK_DOWN_KERNEL_FORCE_NONE`.
- An on-device rebuild needs network, podman and a second reboot, and the
  full amdgpu build takes a long time; prefer the release asset.
- What is actually driven (bpc, mode) is gamescope's choice through the
  connector's `max bpc`; the fix only makes the link capable of it.

## Still to measure on a Steam Machine

Written down here when done (nothing below is assumed in the code; the
component adapts to either answer where it can):

- `lsinitcpio -l /boot/initramfs-linux-neptune.img | grep amdgpu`: whether
  the initramfs loads amdgpu. The `steam-deck` initcpio hook of
  `steamos-customizations` 3.9 lists no amdgpu and there is no `kms` hook,
  so the expectation is "no" and the modprobe hook path is used; if "yes",
  `modules` switches to the early initrd override automatically and
  `status` reports `amdgpu: early initrd`.
- `grep -n grub.d /usr/bin/grub-mkconfig /etc/default/grub` and
  `ls /etc/default/grub.d`: that SteamOS's `update-grub` honours the
  drop-in directory (beaglemoo relies on it on 3.9.5).
- `cat /sys/kernel/security/lockdown`, `cat /sys/module/amdgpu/parameters/dcfeaturemask`
  on stock: expected `[none]` and `2`.
- The measured link after the fix: `vrr_range`, mode, bpc, `amdgpu taint`.
- [etc-survival.md](../etc-survival.md) across a real update.
