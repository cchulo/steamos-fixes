# Migrations

A migration converts on-device state left by an older version into what
the current version expects (renamed state files, moved caches, a changed
manifest field). They run after `self-update` or `install` has checked out
a version, before `apply`, from the **new** checkout.

## Rules

- File name: `NNNN-short-name.sh` with a 4-digit, never reused number.
  They run in lexical order. Never rename or edit a migration once
  released; fix mistakes with a new one.
- Run with `bash`, with `SOF_SRC` (the checkout), `SOF_ROOT` (fixture or
  slot root, empty on a live system) and `SOF_DRY_RUN` exported. Source
  `"$SOF_SRC/lib/common.sh"` and build every path with `sof_path`.
- **Idempotent**: a migration may run against a device that never had the
  old state (fresh install) or where it already ran partially (crash). Test
  for the old state before changing anything.
- Exit non-zero to stop. The failed migration is not recorded and is retried
  by the next self-update; later migrations and `apply` do not run.
- Only touch steamos-fixes's own state (`/var/lib/steamos-fixes`,
  files listed in the manifest). Never stock SteamOS files, never `/usr`.
  Files outside the state dir must go through `manifest_install_file`.
- Must not need the network.
- Each migration comes with a bats test under `tests/migrations/` that sets
  up the old state in a fixture root.

Applied migrations are recorded per device in
`/var/lib/steamos-fixes/state/migrations.done` (`<name>\t<ts>\t<commit>`).
There are no migrations yet; the first one is `0001-<name>.sh`.
