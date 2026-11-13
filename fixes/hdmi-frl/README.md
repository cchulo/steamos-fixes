# hdmi-frl

HDMI 2.1 FRL with VRR on the native HDMI port of an amdgpu device (the
Valve Steam Machine). Component `hdmi_frl`, command `steamos-fixes hdmi-frl`.

| file | role |
|---|---|
| `component.sh` | the component: hardware probe, superseded probe, apply/degrade logic, status |
| `../../cmd/hdmi-frl.sh` | `hdmi-frl frl [--without-vrr] \| tmds \| status` |
| `../../patches/kernel/0001-drm-amd-display-use-dc_is_hdmi_signal-in-freesync-caps.patch` | the amdgpu patch (Tomasz Pakuła) |
| `../../patches/kernel/modules-hdmi-frl.list` | builds `amdgpu.ko` from `drivers/gpu/drm/amd/amdgpu` |
| `../../tests/components/hdmi-frl.bats` | fixture-root tests |
| `../../docs/fixes/hdmi-frl.md` | user documentation, verification, limits |

Design: `STEAMOS-FIXES-PLAN.md` §1.1 and §6.
