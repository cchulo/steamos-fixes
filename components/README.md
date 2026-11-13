# Components and fixes

`components/` holds the two framework components, `modules` (patched
kernel modules of every fix) and `update` (RAUC handlers, boot service,
keep list, notifier, boot entry). A **fix** lives in
`fixes/<name>/component.sh` and is discovered next to them; its component
name is the directory name with `-` replaced by `_`. The contract is
documented in [`lib/component.sh`](../lib/component.sh) and
[`docs/architecture.md`](../docs/architecture.md). Summary:

| symbol | required | purpose |
|---|---|---|
| `COMPONENT_DESCRIPTION` | yes | one line |
| `<name>_files` | yes | tab-separated `src dest mode [slot]` lines; `src` relative to `overlay/`; may print nothing |
| `<name>_applies` | fixes: yes | 0 this hardware needs the fix, 1 not applicable (no-op, `n/a`), 2 cannot tell; prints a one-line reason |
| `<name>_probe` | yes | 0 superseded by stock SteamOS, 1 still needed, 2 unknown |
| `<name>_apply` | no | extra idempotent steps after files are installed (generated files, `grub.d` drop-ins, …) |
| `<name>_status` | no | override `active|degraded|stock|superseded|n/a` computation |
| `<name>_status_detail` | no | one line explaining the status (shown by `status`, in `status.json`) |
| `<name>_remove` | no | extra cleanup before manifest-driven removal |

Rules: never write outside `manifest_install_file` /
`manifest_install_symlink` (or the `lib/grub.sh` helpers, which use them);
build every path with `sof_path`; name every file with the `steamos-fixes`
marker; stay bash-3.2 compatible; add a bats file under
`tests/components/<name>.bats` with fixture roots for "applies / does not
apply" and "stock lacks X / has X", and a user page under
`docs/fixes/<name>.md`. Kernel modules go in
`patches/kernel/modules-<name>.list`.
