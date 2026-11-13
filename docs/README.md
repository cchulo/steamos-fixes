# Documentation index

User-facing:

| page | what it covers |
|---|---|
| [user-guide.md](user-guide.md) | **start here**: what it fixes, install, checks, updating, uninstall, troubleshooting, reporting a problem |
| [install.md](install.md) | prerequisites, Desktop Mode install steps, what gets written where |
| [fixes/hdmi-frl.md](fixes/hdmi-frl.md) | HDMI 2.1 FRL with VRR: what it does, commands, how to verify, superseded detection, known limits, what is still to measure |
| [kernel-modules.md](kernel-modules.md) | what is rebuilt, how it loads (modprobe hook or early initrd override), when it is fetched or built, lockdown |
| [update-survival.md](update-survival.md) | what a SteamOS update does to `/etc`, the keep list, the update flow, the degrade-by-default policy, the two exceptions |
| [self-update.md](self-update.md) | channels, signed tags, rollback, migrations |
| [uninstall.md](uninstall.md) | guarantees, deny-list, running from recovery media, audit |
| [notifications.md](notifications.md) | what the user notifier shows and the queue format |

Developer-facing:

| page | what it covers |
|---|---|
| [architecture.md](architecture.md) | CLI, fixture-root contract, the component and fix contract, manifest, state dir |
| [contributing.md](contributing.md) | rules, workflow, dev host setup, how to add a fix |
| [vm-testing.md](vm-testing.md) | what runs where (dev host, CI, the Steam Machine, an optional VM) |
| [etc-survival.md](etc-survival.md) | measurement template for `/etc` carry-over across slots (expectations from the SteamOS scripts, results from the device) |
| [../build/kernel-sources.md](../build/kernel-sources.md) | where kernel sources and headers come from, the mirror layout, running the build |
| [../patches/kernel/README.md](../patches/kernel/README.md) | the kernel patches |
| [../vm/README.md](../vm/README.md) | VM harness scripts and research notes |
| [../STEAMOS-FIXES-PLAN.md](../STEAMOS-FIXES-PLAN.md) | the design plan: mechanisms, degrade behaviour, per-fix structure, test plan |
