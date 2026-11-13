# vm/ — SteamOS under QEMU/KVM

A QEMU/KVM harness for stock SteamOS, inherited from ally-x20-steamos and
kept for update-survival and uninstall round-trips on a Linux host or in
CI. The fixes themselves need real hardware; see
[`docs/vm-testing.md`](../docs/vm-testing.md) for what runs where.

| file | runs on | what it does |
|---|---|---|
| `setup-fedora-host.sh` | Fedora host | idempotent dnf/groups/`/dev/kvm`/podman setup, `--download` fetches + verifies a recovery image |
| `run-steamos-vm.sh` | any host | QEMU launcher: `--install`, `--run`, `--snapshot`/`--restore`, optional SMBIOS strings, EDID, USB passthrough, `--offline`, accel auto-detection |
| `guest/measure-etc-survival.sh` | VM | which `/etc` paths survive an A/B update → `docs/etc-survival.md` |
| `guest/roundtrip-test.sh` | VM | install → status → uninstall must leave the system byte-identical |
| `ci/make-base-image.sh` | Fedora host | one-time, manual production of the CI base image |
| `ci/vm-ci.sh` | CI / host | the steps `.github/workflows/vm-tests.yml` runs |

## Quick start (Fedora box)

```sh
vm/setup-fedora-host.sh --download          # once; log out/in if it says so
vm/run-steamos-vm.sh --install              # wipe+install from the recovery desktop
vm/run-steamos-vm.sh --run                  # first boot: passwd; sudo systemctl enable --now sshd
vm/run-steamos-vm.sh --restore clean        # every test session starts from here
ssh -p 2222 deck@127.0.0.1
```

`--print-cmd` shows the exact QEMU command without running anything.

## Research notes (collected 2026-10-30)

### Recovery images

| image | URL | size | date | sha256 (computed by us) |
|---|---|---|---|---|
| `recovery-4` | <https://steamdeck-images.steamos.cloud/recovery/steamdeck-recovery-4.img.bz2> | 2 653 795 875 B | Last-Modified 2022-05-15 | `ac9c58fdd319d46120444875172eb56382098634f2075729f51426ba5cb788c6` |
| `latest` | <https://steamdeck-images.steamos.cloud/recovery/steamdeck-repair-latest.img.zip> → 302 to `steamdeck-oobe-repair-20260707.10-3.8.14.img.zip` | 3 363 609 740 B | Last-Modified 2026-07-07 (SteamOS 3.8.14) | `d54fbf0ad400d9c2a04501aaae68231e08ed5dadba8774348eca82c554eea494` |

- Valve publishes **no checksum file** next to the images (`.sha256`,
  `.sha256sum`, `SHA256SUMS` all 404 on 2026-10-30) and the help page
  (<https://help.steampowered.com/en/faqs/view/1B71-EDF2-EB6D-2BB3>) lists
  none. The values above come from one full download each on 2026-10-30;
  `setup-fedora-host.sh` checks them, and anything else is
  trust-on-first-use (digest recorded next to the file, checked on reruns).
  TODO(vm): confirm both digests from a second download on the Fedora box.
- `latest` is a moving redirect. When Valve moves it, the new file name has
  no known digest and falls back to TOFU; add the new value to
  `setup_known_sha256`.
- Prefer `latest`: it installs 3.8.x directly, so getting to the 3.9 beta
  takes one update instead of several from the 2022 image.

### Installing in QEMU

Sources: Alberto Garcia (Igalia), "Running SteamOS 3 in a virtual machine
using QEMU", <https://blogs.igalia.com/berto/?p=783> (2022-07-05, updated
2024-04-04 and 2025-07-28); DeterminateSystems/nix-installer PR #34
(<https://github.com/DeterminateSystems/nix-installer/pull/34>, uses the
same recipe in CI); GamingOnLinux forum thread 5200
(<https://www.gamingonlinux.com/forum/topic/5200/>).

- UEFI only: OVMF (`edk2-ovmf` on Fedora, `ovmf` on Ubuntu), `-machine q35`.
  The non-secure-boot `OVMF_CODE` build is used; SteamOS does not need
  Secure Boot. The vars file is copied per disk because SteamOS writes its
  boot entries into NVRAM; a snapshot gets its own copy.
- The installer (`~/tools/repair_device.sh`, run by the "Re-image" desktop
  icon, which calls `steamos-install`-style partitioning) hard-codes the
  Deck's `nvme0n1`. Attaching the target as `-device nvme` avoids editing
  `DISK`/`DISK_SUFFIX` in that script. We keep NVMe after the install too
  (`--disk-bus virtio` exists if needed).
- Target disk: 64 GiB qcow2 (the A/B layout needs two ~5 GiB root slots plus
  `/var`, `/home`, ESP; 64 GiB is the commonly used size). Sparse, so real
  usage is ~15 GiB after an update.
- Recovery image attached as virtio with `snapshot=on` so the downloaded
  file is never modified (the GamingOnLinux thread reports it breaks easily
  when written to).
- RAM: 8 GiB. Updates are reported to fail with less.
- Since 3.7 the image boots straight into Desktop Mode after the install,
  so the old `steamos-chroot --no-overlay` autologin trick is not needed.
  TODO(vm): confirm with the 3.8.14 image that Game Mode starts at all on
  virtio-gpu; if gamescope fails, the session falls back to Desktop Mode,
  which is enough for everything except the HDR/gamescope checks.
- "Dock/GPU check" workarounds: none needed for the install on current
  images in the sources above. Game Mode under virtio-gpu needs GL
  (`virtio-vga-gl` + `-display gtk,gl=on`); headless CI uses plain
  `virtio-vga` and only Desktop/ssh.
- swtpm: optional (`--tpm`); SteamOS does not require a TPM.
- ssh: `-netdev user,hostfwd=tcp:127.0.0.1:2222-:22`; in the guest set a
  password (`passwd`) and `sudo systemctl enable --now sshd`.

### Updating inside the VM (plan §6 check 4)

From the Igalia post: `steamos-select-branch beta` (or `main`), check
`BUILD_ID` in `/etc/os-release`, `steamos-update check`, `steamos-update`,
reboot. Known pitfall: an update that fails at 100 % with a post-install
handler error was fixed by renaming "Wired connection 1" in network
settings and rerunning. `/etc` carry-over across slots is governed by
SteamOS's atomic-update keep lists (`/usr/lib/rauc/atomic-update-keep.conf`
plus `/etc/atomic-update.conf.d/*.conf`, applied by `holo-sync-var`; see
docs/update-survival.md); `guest/measure-etc-survival.sh` plants a marker
in `/etc/atomic-update.conf.d` so the effect is measured, not assumed.

### DMI / SMBIOS

A fix that probes DMI (`/sys/class/dmi/id/*`) can be exercised with
`--smbios` (off by default), which injects
`-smbios type=1,manufacturer=Valve,product=Steam Machine,version=1.0` and
`-smbios type=2,manufacturer=Valve,product=Fremont`; every string can be
overridden (`--smbios-vendor`, `--smbios-product`, `--smbios-board-vendor`,
`--smbios-board`). Kernel mapping: `sys_vendor`/`product_name`/
`product_version` = SMBIOS **type 1** manufacturer/product/version;
`board_vendor`/`board_name` = **type 2** manufacturer/product. TODO(hw):
the real Steam Machine strings. The `hdmi-frl` fix does not use DMI: it
looks for a native HDMI connector on an amdgpu card, which the VM lacks,
so it reports `n/a` there.

### ACPI tables and EDID

`-acpitable file=X` appends a table to QEMU's own set (only when asked for).
`--edid <blob>` parses the preferred mode from the blob's first detailed
timing descriptor, sets `edid=on,xres=..,yres=..` on the virtio GPU, and
exposes the raw blob to the guest via
`-fw_cfg name=opt/steamos-fixes/edid,file=...`
(`/sys/firmware/qemu_fw_cfg/by_name/opt/steamos-fixes/edid/raw`, module
`qemu_fw_cfg`); `--edid-mode WxH` when the blob has no detailed timing.
Loading the blob as the connector's EDID would need
`drm.edid_firmware=Virtual-1:edid/<file>` on the guest command line.

### Accelerators

- KVM: Linux x86-64 with read/write `/dev/kvm` (group `kvm`). GitHub-hosted
  `ubuntu-latest` x86-64 runners expose `/dev/kvm`; the udev rule in
  `vm-tests.yml` (`KERNEL=="kvm", GROUP="kvm", MODE="0666"`) is the snippet
  from GitHub's changelog of 2024-04-02
  (<https://github.blog/changelog/2024-04-02-github-actions-hardware-accelerated-android-virtualization-now-available/>).
- HVF: Intel Macs only, detected by `sysctl -n kern.hv_support` = 1. HVF on
  Apple Silicon cannot run x86-64 guests.
- TCG: everything else (Apple Silicon). Expect 10-20x slower; the script
  sets `SOF_VM_SLOW=1` and writes it to `<vm-dir>/accel.env` so slow
  suites can skip.
