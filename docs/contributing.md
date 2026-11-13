# Contributing

## Ground rules (from the plan; enforced by tests where possible)

1. Commits are authored by the repository owner only. No co-author or
   AI-attribution trailers.
2. GPL-2.0-only with an SPDX header on every source/script file
   (`scripts/check-spdx.sh`). Third-party files keep their license verbatim
   and are listed in `LICENSE.md` and `scripts/spdx-exceptions.txt`.
3. Never ship binaries: no `.ko`, firmware, or SOFA files in git.
4. Never edit a stock SteamOS file; only add prefixed drop-ins, recorded in
   the manifest. Nothing under `/usr`. Never toggle `steamos-readonly`.
5. Everything path-related goes through `sof_path` so it can run against a
   fixture root. New behaviour comes with bats (shell) or pytest (Python)
   tests that use fixture trees, not the host system.
6. Shell must work on bash 3.2 (macOS) and bash 5 (SteamOS). No associative
   arrays, `mapfile`, `${var,,}`, or `|&`.

## Workflow

- Work in a git worktree per task (`worktrees/<name>`, branch
  `<type>/<name>`), never on `main` directly.
- `make check` must pass before a PR: shellcheck, shfmt (`-i 4 -ci -bn`),
  SPDX check, bats, pytest. `make fmt` reformats.
- One PR per component or subsystem. Keep the PR description focused on what
  a reviewer must verify on hardware or in the VM, since CI cannot.
- Hardware-only facts (is amdgpu in the initramfs, free space on the efi
  partition, measured `/etc` survival) are marked `TODO(hw)` in the docs
  until collected on the device; never fill them in from assumptions.
- Every fix declares its hardware (`<name>_applies`) and is a no-op
  elsewhere; a fix that needs a kernel argument uses `lib/grub.sh`, one
  that needs a module adds `patches/kernel/modules-<fix>.list`.

## Dev host setup

macOS or Linux is fine for everything that does not need a VM or real
hardware: shell libraries, fixes, overlay files, CI, docs. Needed: `bash`,
`bats-core`, `shellcheck`, `shfmt`, `jq`, `zstd`, `cpio`. Container builds
and the optional VM need an x86 Linux host with podman and KVM
(`vm/setup-fedora-host.sh`); the fixes themselves are verified on the
owner's Steam Machine.

## Layout of a new fix

```
fixes/<name>/component.sh          contract: see components/README.md (incl. <name>_applies)
fixes/<name>/README.md             pointer to the pieces
patches/kernel/NNNN-*.patch        git format-patch, original author kept, "Derived from:" section
patches/kernel/modules-<name>.list <patch>\t<M= dir>\t<ko>
overlay/<...>                      files it installs (prefixed)
cmd/<name>.sh                      optional user command
tests/components/<name>.bats       fixture roots: applies / not, stock lacks X / has X, degrade, superseded, uninstall
docs/fixes/<name>.md               user-facing: what it does, how to verify, known limits, how to turn it off
```
Add the kernels it must be built for to `build/kernels.txt`.
