# User guide: steamos-fixes

This page is for people who run **stock SteamOS** on a machine that needs
one of the fixes here (today: the **Valve Steam Machine** and its HDMI 2.1
port) and want it without replacing SteamOS. You will type a few commands
in a terminal. Developer documentation starts at the [README](../README.md).

## What this is

steamos-fixes is a set of scripts that adds small fixes next to SteamOS
instead of replacing it, keeps them working across SteamOS updates, and can
remove everything again. It is not a custom SteamOS image and not a Decky
plugin. A fix checks which hardware it is for; on anything else it does
nothing and reports `n/a`.

**Honest status:** pre-release. The first fix has not run on a Steam
Machine yet; the owner will test it on their own. It ships a patched kernel
driver and a boot setting, so read what you run and use it at your own risk.

## What it fixes

| On stock SteamOS | With steamos-fixes |
|---|---|
| The Steam Machine's HDMI port runs HDMI 2.0 (TMDS): 4K at 120 Hz only at 4:2:0 8-bit, 144 Hz not offered, no 4:4:4 at 4K120. Many people use a DisplayPort→HDMI dongle that drops the signal. | **HDMI 2.1 (FRL)**: 4K120 at up to 12-bit or 4K144 at 10-bit, full 4:4:4, HDR, and **VRR still works** (fix `hdmi-frl`). |

Valve's next kernel already does this on its own; when your SteamOS gets
it, the fix reports `superseded` and steps aside by itself.

## What it changes on your system

- **Nothing under `/usr`.** That is SteamOS's read-only system image. The
  project never turns read-only mode off, never runs `depmod` or
  `mkinitcpio`.
- Its own files go to `/var/lib/steamos-fixes` (the downloaded copy of this
  project, built drivers, logs and saved originals) and
  `/etc/steamos-fixes` (the patched driver for the running kernel).
- Small configuration files with `steamos-fixes` in their name:
  `/etc/modprobe.d/steamos-fixes-modules.conf`,
  `/etc/default/grub.d/steamos-fixes-hdmi-frl.cfg`,
  `/etc/atomic-update.conf.d/steamos-fixes.conf` (tells SteamOS to keep
  the others across updates), systemd units in `/etc/systemd`.
- A **patched `amdgpu` driver**, loaded only when it was built for exactly
  the kernel you are running; otherwise SteamOS's own driver loads, so a
  new kernel never fails to boot because of this project.
- One **kernel argument** (`amdgpu.dcfeaturemask=0x402`) through a GRUB
  drop-in. SteamOS's own `update-grub` writes the boot entry; the original
  is saved first.
- A hook in SteamOS's updater (RAUC) so the fixes are carried over to the
  new system after an update. The original updater configuration is saved
  first.

Every file is recorded in a list (the manifest), and **everything can be
removed** again ([Uninstall](#uninstall)).

## Before you start

- SteamOS's **read-only mode stays on** (the default). Do not run
  `steamos-readonly disable`; the installer refuses to run if you did.
- Set a password for the `deck` user so `sudo` works: in Desktop Mode, open
  Konsole and run `passwd` once. Never share this password with anyone.
- Switch to **Desktop Mode** and open **Konsole**.
- Connect to the internet. The installer downloads this project and the
  prebuilt driver for your kernel (or the sources to build it).
- Secure Boot / kernel lockdown must be off (they are on a stock Steam
  Machine); the patched driver is unsigned.

## Install

```sh
git clone https://github.com/cchulo/steamos-fixes.git
cd steamos-fixes
git checkout "$(git tag -l 'v*' --sort=-version:refname | head -n1)"   # newest release
sudo ./steamos-fixes.sh install
```

The installer copies the project to `/var/lib/steamos-fixes/src` and runs
everything from there; you can delete the clone afterwards.

How long it takes: **a few minutes** when a prebuilt driver exists for your
kernel (each release carries one for the kernels it supports); **a long
time** (the whole amdgpu driver is compiled in a container) when there is
none, for example right after a SteamOS update with a brand-new kernel. In
that case the fix stays `degraded` (your HDMI link runs as before) until the
build finishes and you reboot once more.

When it finishes it prints a status table. **Reboot** when it tells you to,
then go back to Game Mode.

More detail, installer options and a one-line install (not recommended):
[install.md](install.md).

## After install: what to check

```sh
cd /var/lib/steamos-fixes/src
./steamos-fixes.sh status
sudo ./steamos-fixes.sh hdmi-frl status
```

| Status | Meaning |
|---|---|
| `active` | installed and effective right now |
| `degraded` | installed, but not effective on this kernel (for example no patched driver yet); the second line says why and what will fix it |
| `stock` | not installed, or switched off by you |
| `superseded` | SteamOS now has its own fix; you can remove ours (see [Updating](#updating)) |
| `n/a` | this fix is not for this machine |
| `error` | something went wrong; see [Troubleshooting](#troubleshooting) |

On the TV: Settings → Display in Game Mode should now offer 144 Hz (if the
TV does), 4K120 looks like 4:4:4 (text edges are clean), HDR is available,
and VRR stays on. `hdmi-frl status` shows the VRR range the kernel reports,
the current mode and colour depth. Set your TV's **game mode by hand**:
SteamOS does not switch it on for you (ALLM is not sent).

## Updating

**SteamOS updates.** Install them as usual; they are never held back by
this project. After the reboot you get one notification. If the update
brought a new kernel, the HDMI link runs stock (HDMI 2.0, VRR on) until a
patched driver for that kernel is downloaded or built in the background; a
notification then asks for one more reboot. If no driver can be built yet
(brand-new kernel, no network), the fix stays `degraded` until a newer
steamos-fixes release supports that kernel. Details:
[update-survival.md](update-survival.md).

**When SteamOS catches up.** If a SteamOS update ships Valve's own HDMI 2.1
support, the status shows `superseded` and you get a notification; the
kernel argument is removed by itself. To remove the rest:

```sh
cd /var/lib/steamos-fixes/src
sudo ./steamos-fixes.sh uninstall --superseded
```

**Updating steamos-fixes itself.**

```sh
cd /var/lib/steamos-fixes/src
sudo ./steamos-fixes.sh self-update --check   # is there a new release?
sudo ./steamos-fixes.sh self-update           # install it
sudo ./steamos-fixes.sh self-update --rollback   # go back if the new one misbehaves
```

`self-update` only installs releases signed with the project's key, and it
refuses to run if you changed files in the installed copy. Details:
[self-update.md](self-update.md).

## Switching the HDMI link mode

```sh
sudo ./steamos-fixes.sh hdmi-frl tmds               # back to HDMI 2.0 (stock), reboot
sudo ./steamos-fixes.sh hdmi-frl frl                # HDMI 2.1 again, reboot
sudo ./steamos-fixes.sh hdmi-frl frl --without-vrr  # HDMI 2.1 even when no patched driver exists (no VRR then)
```

## Uninstall

```sh
cd /var/lib/steamos-fixes/src
sudo ./steamos-fixes.sh uninstall --dry-run   # show what would happen, change nothing
sudo ./steamos-fixes.sh uninstall --reboot    # remove everything, then reboot
```

If the installed copy is broken or deleted, the standalone uninstaller
still works:

```sh
sudo sh /var/lib/steamos-fixes/uninstall.sh --yes
```

This removes every file the project added, regenerates the boot entry
without our argument (and tells you whether it is byte-identical to the
copy saved at install), restores the updater configuration byte for byte,
and deletes `/var/lib/steamos-fixes`. A file you edited yourself is left in
place and reported. Details: [uninstall.md](uninstall.md).

**If you factory-reset without uninstalling.** A reset wipes the project's
files but not the boot partitions. The kernel argument lives in a file the
reset also wipes, so it is gone; only the early initrd override (used when
the initramfs loads amdgpu) could stay behind, and the shutdown hook
restores both slots before the reset. If anything is left afterwards:

```sh
sudo sh /efi/EFI/steamos/steamos-fixes-cleanup.sh --all-slots
```

## Troubleshooting

Start every time with:

```sh
cd /var/lib/steamos-fixes/src
./steamos-fixes.sh status --verbose
sudo ./steamos-fixes.sh hdmi-frl status
```

**No 144 Hz / no 4:4:4 after a SteamOS update.** The new kernel has no
patched driver yet, so the fix withheld the FRL argument. Fetch or build
the driver and reboot:

```sh
sudo ./steamos-fixes.sh rebuild
sudo reboot
```

**HDMI 2.1 modes are there but VRR is gone.** The FRL argument is active
but the stock `amdgpu` loaded (the loader fell back). Check why:

```sh
journalctl -b -t steamos-fixes      # "loaded patched amdgpu" or the reason for the fallback
cat /sys/kernel/security/lockdown    # must say [none]
sudo ./steamos-fixes.sh rebuild --force && sudo reboot
```

**The picture drops to HDMI 2.0 after the TV was switched off and on.** A
known limit of the 7.2 kernel (the link is not re-trained at FRL on
hotplug); reboot, or wait for the follow-up patch.
[docs/fixes/hdmi-frl.md](fixes/hdmi-frl.md) lists the limits.

**Collecting information for a bug report.**

```sh
./steamos-fixes.sh status --verbose > ~/sof-status.txt
sudo ./steamos-fixes.sh hdmi-frl status > ~/sof-hdmi.txt
journalctl -b -t steamos-fixes > ~/sof-journal.txt
journalctl -b -u steamos-fixes > ~/sof-boot-service.txt
journalctl -k -b | grep -iE 'amdgpu|drm' > ~/sof-kernel.txt
```

All of these only read; nothing is changed. Look through the files before
you post them.

### Reporting a problem

Open an issue at <https://github.com/cchulo/steamos-fixes/issues> and
include what you did, what you expected and what happened; your SteamOS
version (Settings → System), `uname -r`, the TV model; and the files above.
**Never post your sudo password.**

## Credits

The HDMI 2.1 VRR fix is Tomasz Pakuła's, isolated and verified on a Steam
Machine by the steam-machine-hdmi21 project; the full list is in the
[README's Credits section](../README.md#credits).
