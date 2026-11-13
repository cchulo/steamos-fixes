# VM testing

The QEMU/KVM harness under [`vm/`](../vm/README.md) is inherited from the
sibling project and kept for update-survival and uninstall-from-broken-state
runs on a Linux host and in CI. For this project the primary test bed is the
owner's Steam Machine: the first fix needs real amdgpu hardware with a
native HDMI port, which a VM cannot provide, and macOS development hosts
run no VM at all (plan: "Development happens on macOS without a VM").

## What runs where

| where | what |
|---|---|
| any dev host (macOS, Linux) | `make check`: shellcheck, shfmt, SPDX, every bats suite against fixture roots. This is the bulk of the test plan (plan §7) |
| GitHub Actions `ubuntu-latest` | `test.yml` (the same), `build-modules.yml` (container builds for every kernel in `build/kernels.txt`, release assets), `vm-tests.yml` (skipped, not red, until a base image exists) |
| the Steam Machine | plan §7 steps 1–4: the initramfs check, `grub.d` confirmation, install/status/`hdmi-frl status`, a real update with `measure-etc-survival.sh`, the degrade path offline, uninstall byte-identity |
| a Linux box with KVM (optional) | `vm/run-steamos-vm.sh`: stock SteamOS under QEMU for install → update → uninstall round-trips without touching the device. Fixes report `n/a` there (no amdgpu HDMI), which is itself a check |

## Where the VM runs

SteamOS is x86-64 only and boots through UEFI with its own A/B layout, so it
needs a real x86 VM with OVMF. `vm/run-steamos-vm.sh` picks the accelerator
automatically (`kvm` → `hvf` → `tcg`) and prints which one it got.
`--smbios` injects DMI strings (`Valve`/`Steam Machine`/`Fremont` by default,
overridable) for fixes that probe DMI; `--edid <blob>` sets the virtual
GPU's preferred mode; `--offline` blocks the network for the degrade path.

```sh
vm/setup-fedora-host.sh --download          # once; log out/in if it says so
vm/run-steamos-vm.sh --install              # wipe+install from the recovery desktop
vm/run-steamos-vm.sh --run                  # first boot: passwd; sudo systemctl enable --now sshd
vm/run-steamos-vm.sh --restore clean        # every test session starts from here
ssh -p 2222 deck@127.0.0.1
```

## What each check proves

| # | check | how |
|---|---|---|
| 1 | install/status/uninstall round-trip leaves the system byte-identical | `vm/guest/roundtrip-test.sh` (snapshots `/etc`, `/var/lib/steamos-fixes`, ESP entries; all manifest paths gone); CI job `roundtrip` |
| 2 | module build produces `.ko` with matching vermagic; version-gated substitution | `build-modules.yml` artifacts + `modinfo`; `journalctl -t steamos-fixes` on the device |
| 3 | A/B update survival, `/etc` keep list, offline degrade, self-update/rollback | `vm/guest/measure-etc-survival.sh before/after` around `steamos-update` → [`etc-survival.md`](etc-survival.md); on the device for the real answer |
| 4 | fixes are no-ops on other hardware | `status` in the VM shows `hdmi_frl n/a` |
| 5 | probes on "stock lacks X" / "stock has X", degrade and superseded transitions | bats with fixture roots (`tests/components/hdmi-frl.bats`), no VM needed |

## Slow tests

`run-steamos-vm.sh` exports `SOF_VM_ACCEL` and `SOF_VM_SLOW` and writes
them to `<vm-dir>/accel.env`. Suites that boot, update or rebuild should
`skip` when `SOF_VM_SLOW=1`; CI always runs on KVM.

## Producing the CI base image (once, by hand)

The recovery installer is a click-through desktop flow, so the base image is
made manually on a Linux box and uploaded as a release:

```sh
vm/setup-fedora-host.sh --download
vm/ci/make-base-image.sh keygen       # CI ssh key; then: gh secret set SOF_VM_SSH_KEY < .../ci_ed25519
vm/ci/make-base-image.sh install      # wipe+install, first boot, passwd, enable sshd (prompts explain)
vm/run-steamos-vm.sh --run --disk ~/vms/steamos-fixes/disks/steamos-base.qcow2
vm/ci/make-base-image.sh prepare      # authorise key, CI sudoers drop-in, steamos-update
vm/ci/make-base-image.sh package      # compact, zstd, split < 2 GiB, SHA256SUMS, prints gh release create
```

Then set `SOF_VM_BASE_TAG` in `vm/ci/base-image.conf`. The image contains
`/etc/sudoers.d/zz-steamos-fixes-ci` (passwordless sudo for `deck`) and the
CI public key; it is a test fixture, never a device image.
