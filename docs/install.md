# Installing steamos-fixes

This guide covers installing on a machine running stock SteamOS (today the
Valve Steam Machine is the one with a fix that applies; elsewhere every fix
reports `n/a` and nothing is installed). If you are new to the project,
start with the [user guide](user-guide.md). What gets fixed and why is in
[`STEAMOS-FIXES-PLAN.md`](../STEAMOS-FIXES-PLAN.md). How to undo everything
is in [uninstall.md](uninstall.md).

## Prerequisites

- Stock SteamOS with read-only mode **on** (the default). The installer
  refuses to run if someone ran `steamos-readonly disable`, because stock
  files may then have been changed by other tools. It never turns read-only
  mode off itself. `--i-know` overrides the refusal; only use it if you know
  what changed.
- A password for the `deck` user, so `sudo` works. In Desktop Mode, open
  Konsole and run `passwd` once.
- Network access (to clone the repository and fetch the prebuilt module for
  your kernel; a local build downloads Valve's headers and sources).
- `git`, which ships with SteamOS.

## Steps (Desktop Mode)

1. Switch to Desktop Mode (Steam button → Power → Switch to Desktop) and
   open **Konsole**.
2. Clone and read what you are about to run as root (recommended):

   ```sh
   git clone https://github.com/cchulo/steamos-fixes.git
   cd steamos-fixes
   git checkout "$(git tag -l 'v*' --sort=-version:refname | head -n1)"   # newest release
   less cmd/install.sh                                                   # inspect
   sudo ./steamos-fixes.sh install
   ```

   The installer re-clones the same tag or branch from the same URL into
   `/var/lib/steamos-fixes/src` and runs everything from there. The
   clone in your home directory can be deleted afterwards.

3. Reboot when it says so (kernel module or boot entry changes take effect
   on the next boot), then return to Game Mode.

### One-liner (discouraged)

Piping a script from the internet into a root shell means running code you
have not read. Prefer step 2. If you accept the risk:

```sh
curl -fsSL https://raw.githubusercontent.com/cchulo/steamos-fixes/main/bootstrap.sh | sudo sh
```

`bootstrap.sh` checks for `git`, clones the newest `v*` release tag (or the
default branch while no release exists) into a temporary directory and
runs `install` from it. To fetch something else, pass `SOF_REF` or
`SOF_REPO_URL` through sudo, e.g. `... | sudo env SOF_REF=v0.2.0 sh`.
Arguments after `sh -s --` are passed on to `install`, e.g.
`... | sudo sh -s -- --no-apply`.

## Installer options

| option | effect |
|---|---|
| `--repo <url>` | clone from this URL (default: `origin` of the checkout you run it from) |
| `--ref <tag-or-branch>` | install this ref (default: the running checkout's exact tag, else its branch) |
| `--repin-keys` | replace the already pinned signing keys with the checkout's `keys/` |
| `--no-apply` | only clone, pin keys and record; do not apply anything |
| `--dry-run` (global) | print every action, write nothing |

## What `install` does

1. Checks it runs as root and that read-only mode is on. There is no
   hardware gate: each fix decides for itself whether it applies here.
2. Creates the state tree under `/var/lib/steamos-fixes/` (shared by both
   SteamOS slots, so it survives updates).
3. Clones the repository into `/var/lib/steamos-fixes/src`. If that
   checkout already exists it is fetched and moved to the requested ref
   (fast-forward only; local modifications make it stop). If you are
   already running from it, nothing is cloned.
4. Pins the release signing keys from `keys/` into
   `/var/lib/steamos-fixes/keys` (kept on re-install unless
   `--repin-keys`); `self-update` trusts only this pinned copy. See
   [self-update.md](self-update.md).
5. Records where it came from in `state/installed-from`.
6. Copies the standalone uninstaller to `/var/lib/steamos-fixes/uninstall.sh`
   (it keeps working even if the checkout is deleted).
7. Runs pending `migrations/`, then `apply` (every component, every file
   recorded in the manifest), then prints `status`.

Running `install` again is safe: every step is idempotent.

## What it writes

| path | content |
|---|---|
| `/var/lib/steamos-fixes/src/` | the git checkout everything runs from |
| `/var/lib/steamos-fixes/keys/` | pinned public keys for release signatures |
| `/var/lib/steamos-fixes/{modules,cache,backup,log,bin}/` | caches, saved originals (`backup/grub/<slot>`, `backup/rauc`, `backup/<slot>`), logs |
| `/var/lib/steamos-fixes/state/installed-from` | `url=`, `ref=`, `commit=`, `date=`, `keys_sha256=` lines |
| `/var/lib/steamos-fixes/state/status.json` | last `status` result |
| `/var/lib/steamos-fixes/uninstall.sh` | standalone uninstaller |
| `/var/lib/steamos-fixes/manifest` | every file `apply` placed outside the state dir |

Files outside `/var/lib/steamos-fixes` are only written by `apply`, as
prefixed drop-ins recorded in the manifest (`/etc/steamos-fixes/` for the
staged modules and loader, `/etc/modprobe.d`, `/etc/default/grub.d`,
`/etc/atomic-update.conf.d`, `/etc/systemd`). Nothing is ever written
under `/usr`. The slot's `grub.cfg` is regenerated by SteamOS's own
`update-grub` and the RAUC `system.conf` gets a delimited block; both
originals are saved first.

## Checking status

```sh
steamos-fixes.sh status            # human-readable table
steamos-fixes.sh status --verbose  # plus each component's probe details
steamos-fixes.sh status --json     # machine-readable; also in state/status.json
steamos-fixes.sh probe             # has stock SteamOS caught up? (superseded|needed|unknown)
```

The header shows the version and commit, the running kernel and whether
modules are staged for it, the update policy (`block` by default), whether
a post-update reboot check is pending, and the last self-update check. Each component is `active` (installed and
intact), `stock` (not installed or drifted; the boot service re-applies),
`superseded` (stock SteamOS now provides it; remove ours with
`uninstall --superseded`), `n/a` (cannot tell on this machine) or `error`.
