# Kernel patches

Kernel patches carried by steamos-fixes. Each file is in `git format-patch`
format and applies with `git apply` or `patch -p1` from the top of a kernel
tree. They are derivative works of GPL-2.0 kernel code and are licensed
GPL-2.0-only (see `LICENSE.md`). Upstream authorship is kept.

One list per fix, `modules-<fix>.list`, names the patch, the `M=` directory
the module is built from and the `.ko`; `build/build-modules.sh` and
`lib/modules.sh` read every `modules*.list`. The static checks are in
`tests/patches/kernel-patches.bats`.

## Target kernels

| | |
|---|---|
| SteamOS 3.9 stable kernel | `7.2.7-valve2-2-neptune-72-g31504582a073` (`jupiter-3.9`) |
| Valve source tag | `7.2.7-valve2` (commit `31504582a073`, mirror [evlaV/linux-integration](https://github.com/evlaV/linux-integration)) |
| Superseded from | `7.2.10-valve1` (`152e053e341f`, full HDMI 2.1 support, FRL on by default) |

`build/kernels.txt` is the list CI builds.

## 0001: VRR on an HDMI FRL link (fix `hdmi-frl`)

`0001-drm-amd-display-use-dc_is_hdmi_signal-in-freesync-caps.patch`,
`modules-hdmi-frl.list` → `drivers/gpu/drm/amd/amdgpu` → `amdgpu.ko`.

**What it fixes:** `amdgpu_dm_update_freesync_caps()`
(`drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm.c`) only parses the HDMI
VRR range when `sink->sink_signal == SIGNAL_TYPE_HDMI_TYPE_A`. With FRL
enabled (`amdgpu.dcfeaturemask=0x402`) an HDMI 2.1 sink is
`SIGNAL_TYPE_HDMI_FRL`, falls through, and `vrr_capable` stays 0. The patch
tests `dc_is_hdmi_signal()` instead; one line.

**Origin:** Tomasz Pakuła, `21d564d5a104` "Switch to signal type helper
functions from DC — This fixes HDMI VRR under FRL" on the `hdmi-7.2` branch
of [Lawstorant/linux](https://github.com/Lawstorant/linux) (that commit
also switches the DP branch to `dc_is_dp_sst_signal()`, which is not
needed here). Reduced to the freesync-caps hunk, and verified on a Steam
Machine with an LG C4 (40-144 Hz VRR at 4K144 10-bit 4:4:4), by
[beaglemoo/steam-machine-hdmi21](https://github.com/beaglemoo/steam-machine-hdmi21)
(patch `0001`). Reported in ValveSoftware/SteamOS
[#2809](https://github.com/ValveSoftware/SteamOS/issues/2809) and
[#2698](https://github.com/ValveSoftware/SteamOS/issues/2698).

**Validation:** `git apply --check` passes against Valve's `7.2.7-valve2`
`amdgpu_dm.c` (the test suite applies it to a fixture copy of the function,
`tests/patches/fixtures/`). On `7.2.10-valve1` the function was rewritten
(it tests `SIGNAL_TYPE_HDMI_TYPE_A || SIGNAL_TYPE_HDMI_FRL`), so the patch
applies neither forward nor in reverse there; the `Valve-Upstream:
7.2.10-valve1` line in its description tells `build-modules.sh` to treat it
as already upstream on that tag and later, record `module.amdgpu=superseded`
and ship nothing (confirmed by CI on 2026-11-13: `7.2.10-valve1-3` →
`already-upstream`, `module.amdgpu=superseded`; `7.2.7-valve2-2` and `-3`
→ `applied`, vermagic matching). Not yet run on hardware (plan §7).

**Why the whole module:** `amdgpu.ko` is one module built from
`drivers/gpu/drm/amd/amdgpu`, whose Makefile also compiles the display code
under `drivers/gpu/drm/amd/display`. The build's scope rule allows a patch
to touch the parent of its `M=` directory for that reason. The build is the
complete driver: 8 minutes on a GitHub runner (measured), `amdgpu.ko.zst`
5.6 MB; the release asset is the normal path.

**Related, not shipped:** beaglemoo's `0002` (re-verify the FRL link on
every hotplug, mainline `c953b39f9487`; without it the link drops to TMDS
on the first hotplug after boot on 7.2.7) and `0003` (an ALLM module
parameter). Candidates for a later release.
