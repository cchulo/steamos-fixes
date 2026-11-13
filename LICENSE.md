# Licensing

`steamos-fixes` is licensed under **GPL-2.0-only** (see [`LICENSE`](LICENSE)).
The kernel patches under `patches/kernel/` are derivative works of GPL-2.0
code, so the repository as a whole uses the same license as the Linux kernel.
Every source and script file carries an SPDX header:

```
# SPDX-License-Identifier: GPL-2.0-only
```

## Per-file exceptions

Files kept verbatim under their original license are listed in
[`scripts/spdx-exceptions.txt`](scripts/spdx-exceptions.txt) so the SPDX
header check skips them. Today those are only key material:
`keys/release-signing.asc` (the owner's release signing key) and
`build/keys/steamos-package-signing.asc` (Valve's package signing key, used
to verify downloaded headers packages).

## Patches taken from upstream

Kernel patches taken from other trees keep their original `From:` author,
date and description, with a `Derived from:` section naming the source
commit and anything that was changed:

| patch | author | origin |
|---|---|---|
| `patches/kernel/0001-drm-amd-display-use-dc_is_hdmi_signal-in-freesync-caps.patch` | Tomasz Pakuła | `21d564d5a104` on the `hdmi-7.2` branch of [Lawstorant/linux](https://github.com/Lawstorant/linux), reduced to the freesync-caps hunk as isolated by [beaglemoo/steam-machine-hdmi21](https://github.com/beaglemoo/steam-machine-hdmi21) |

`tests/patches/fixtures/amdgpu_dm-7.2.7-valve2-freesync-caps.c` is a copy
of one function of Valve's `linux-integration` tree (GPL-2.0), used only to
check that the patch applies.

## Things we deliberately do not commit

- **Prebuilt kernel modules** (`*.ko`): never in git. CI attaches prebuilt
  artifacts to releases together with SHA-256 sums and the exact source
  commit (`BUILD-INFO`).
- **Kernel sources or headers**: downloaded at build time from Valve's
  package mirror and git mirror (`build/kernel-sources.md`).
