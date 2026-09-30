# Automatic updates

The existing Tailscale LaunchDaemon uses `RunAtLoad` and `KeepAlive`: it starts when macOS loads the service and launchd restarts it if it exits. Keeping the process running does not update the executable. Tailscale's [macOS variants documentation](https://tailscale.com/docs/concepts/macos-variants) lists the CLI-only `tailscaled` variant as supporting operation before login, without built-in automatic updates.

The normal `./install.sh` setup includes an updater LaunchDaemon. It checks for the stable Homebrew `tailscale` formula at boot and daily, upgrades when needed, and verifies the local daemon after a restart. It follows the release available through Homebrew; a new upstream Tailscale release may reach Homebrew later.

## Install on each Mac

From a reviewed checkout of [MrCee/tailscale-headless-macos](https://github.com/MrCee/tailscale-headless-macos), run as the user who owns Homebrew:

```bash
./install.sh
```

For a fresh machine, first copy `.env.example` to `.env` and configure your tailnet as described in the [quick start](../README.md#-quick-start). The installer sets up the daemon, authenticates it, and enables automatic updates as part of the same workflow.

On a Mac already running a compatible, authenticated Homebrew Tailscale LaunchDaemon, the same command adds or refreshes the updater while preserving the running daemon and its authentication. The default existing-daemon setup does not require `.env`. If a user-owned `.env` is present, the installer reads its settings, including the update schedule. Do not run competing Tailscale services against the same state.

To check the setup first without administrator authentication or changes to installed services:

```bash
./install.sh --check
```

For an existing daemon, this checks the updater's installation prerequisites. For a fresh setup, it validates configuration and reports the installation plan.

The installer requests administrator authentication to install root-owned runtime files and register the LaunchDaemon. Normal scheduled runs need no password entry, GUI app, or recurring approval dialog. Installing or changing the updater still requires administrator authority. macOS or device-management policy can impose its own controls; this installer does not disable them or weaken `sudoers`.

Defaults:

| Setting | Value |
| --- | --- |
| Updater service | `com.tailscale.headless-updater` |
| Tailscale service | `com.tailscale.tailscaled` |
| Tailscale socket | `/var/run/tailscaled.socket` |
| Schedule | At load/boot and daily at 04:15 local time |
| Installed runtime | `/Library/PrivilegedHelperTools/com.tailscale.headless-updater/update-tailscale.sh` |
| Log | `/var/log/tailscale-headless-update.log` |

To choose a different maintenance time, set these values in `.env` and run `./install.sh`:

```dotenv
AUTO_UPDATE=true
AUTO_UPDATE_HOUR=3
AUTO_UPDATE_MINUTE=30
```

The defaults are `AUTO_UPDATE=true`, `AUTO_UPDATE_HOUR=4`, and `AUTO_UPDATE_MINUTE=15`. These defaults also apply to older `.env` files that do not contain the update settings. To turn automatic updates off, set `AUTO_UPDATE=false` in `.env` and run `./install.sh`; this removes an existing updater schedule while preserving the daemon and recovery files.

For a non-default existing daemon, set the matching `BREW_BIN`, `LAUNCHD_LABEL`, `LAUNCHD_PLIST`, and `TAILSCALED_SOCKET` values in `.env`. The plist must be `/Library/LaunchDaemons/<label>.plist`, matching `LAUNCHD_LABEL`; update both values because `.env.example` contains the default plist path.

Intel Homebrew uses `/usr/local/bin/brew`; Apple silicon uses `/opt/homebrew/bin/brew`. The installer supports these two standard prefixes. Use the executable associated with the installed daemon. Review the installer output and updater log before considering a machine configured.

## What a scheduled run does

1. Validates the installed configuration and prevents overlapping updater runs.
2. Runs Homebrew as its owning user and refreshes package metadata.
3. Checks the stable `tailscale` formula. No restart is needed when the package is current and the daemon is already running that installed executable and version.
4. Makes root-owned backup copies of the existing CLI, daemon executable, original daemon plist, and updater configuration. The existing Tailscale state stays in place and is not rewritten by the updater.
5. Upgrades `tailscale` and any dependencies Homebrew requires, then restarts the configured daemon when needed. If another Homebrew upgrade already installed a newer package, it can restart into that package without another upgrade, provided matching recovery binaries for the running version are still available.
6. Checks that the daemon is running and online, with the expected executable/version and original device identity. If an upgrade attempt or subsequent health check fails, it attempts recovery using the backup and places automatic updates on hold with `RECOVERY_REQUIRED` for administrator review. A metadata or network failure before the upgrade transaction leaves the running daemon alone and does not create the recovery hold.

Homebrew commands run under the recorded owner's account and macOS user launch context. The updater's privileged portion manages the system daemon and protected backup/runtime files. It does not run a blanket `brew upgrade`, reset Tailscale settings, call `tailscale up`, or publish state or credentials. A restart briefly interrupts connections through that Mac; choose a suitable maintenance window.

The health checks concern the local daemon. A successful update does not prove that a remote peer is awake, Screen Sharing is enabled, or every network route works. Rollback is a recovery attempt, not a guarantee of uninterrupted access; arrange another way to reach a machine when testing updates for the first time.

## Inspect an installation

Check the updater and read its recent log:

```bash
sudo launchctl print system/com.tailscale.headless-updater
sudo tail -n 80 /var/log/tailscale-headless-update.log
```

The updater is a scheduled job, so it normally exits between checks. A loaded updater showing no running process is expected. The separate `tailscaled` service should remain running:

```bash
sudo launchctl print system/com.tailscale.tailscaled
```

Run the installed updater in check mode:

```bash
sudo /Library/PrivilegedHelperTools/com.tailscale.headless-updater/update-tailscale.sh --check
```

Check mode validates configuration and prints the installed version, running daemon version, backend state, and online status. It does not check for available package updates, refresh metadata, write log files, upgrade packages, or restart Tailscale. To run the normal update workflow now:

```bash
sudo launchctl kickstart system/com.tailscale.headless-updater
```

Read the log afterward; successfully starting the job is not evidence that an update completed.

The updater, installer, and removal script coordinate through `/var/run/com.tailscale.headless-updater.lock`. An unclean termination can leave a stale lock. If a run reports the lock is held, inspect the recorded PID and confirm that no update or installer is active before an administrator clears it. Do not remove a live lock to force an update.

## Recover an update on hold

If the log reports `RECOVERY_REQUIRED`, scheduled upgrades remain paused and reinstallation is blocked. Recovery changes the daemon plist's executable path to the protected backup `recovery/tailscaled` and restarts that executable against the existing state. It does not roll back Homebrew's installed package or symlinks. Inspect the logged failure and backup before changing anything, then confirm the daemon's loaded executable, socket, local status, and connectivity from another machine.

Do not delete the hold or reinstall blindly to retry a failed update. Keep the backup until the failure has been understood and the service is healthy. An administrator must reconcile the Homebrew package with the daemon configuration before clearing the hold. This is an administrative recovery step; automatic retry is deliberately blocked after a failed upgrade or health check.

The runtime also records `TRANSACTION_PENDING` before changing packages or restarting. A later run that finds an interrupted transaction attempts recovery and suspends further updates. If an unclean termination also left the scheduler lock behind, inspect that lock first as described above.

## Update the repository's scripts

The public GitHub repository distributes the installer and updater source. Installed machines run a root-owned copy made by the installer; they do not execute scripts from your writable checkout or automatically pull and execute new Git commits as root.

Tailscale package releases update on the schedule without changes to this repository. When this repository's updater itself changes, review the change, update the checkout, and rerun the installer on each Mac:

```bash
git fetch origin
git diff HEAD..origin/main
# After reviewing the changes and resolving any local work:
git pull --ff-only
./install.sh
```

Keep any custom schedule or daemon settings in your local `.env`. Rerunning `./install.sh` on a compatible existing daemon refreshes the updater without reinstalling or resetting the daemon. A recovery hold must still be resolved before reinstallation. Publishing to GitHub alone does not update an installed runtime.

Keep local `.env` files, Tailscale state, authentication keys, machine-specific logs, and backups out of commits. The public repository needs only generic scripts, templates, tests, and documentation.

## Maintainer checks

Run the isolated installation and transaction tests on macOS before publishing changes:

```bash
python3 tests/test-install.py
python3 tests/test-updater.py
```

The tests use temporary files and replacement adapters; they do not use sudo, restart the real daemon, or install packages. Installation tests cover the single-command setup paths and automatic-update configuration. Transaction tests exercise successful upgrades, Homebrew failure handling, recovery, interrupted transactions, and concurrent-operation protection. A real root installation and reboot still need separate verification on a test Mac.

An optional [GitHub Actions workflow template](examples/github-actions-checks.yml) runs syntax checks and these tests on a macOS runner. To enable it, copy it to `.github/workflows/checks.yml` and publish that file using a GitHub credential authorized to manage workflows. The template does not execute while stored under `docs/examples`.

## Startup and reachability limits

- **Fully unattended startup:** for recovery after a cold start or unexpected power loss using this setup alone, FileVault must be off, on both Intel and Apple silicon. With FileVault enabled, this daemon remains unavailable while the Mac waits for an unlock. Disabling FileVault reduces protection for stored data; the installer leaves that decision to you. See the [FileVault startup requirements](../README.md#filevault-and-unattended-restarts).
- **Planned authenticated restart:** on supported hardware, `fdesetup authrestart` can authorise the next boot without a FileVault unlock prompt, temporarily reducing FileVault protection. It does not cover unexpected power loss or later cold boots. Consult Apple's built-in `man fdesetup` documentation; this project does not perform authenticated restarts.
- **Remote FileVault unlock:** Apple supports [SSH unlock on Apple silicon with macOS 26 or later](https://support.apple.com/en-au/guide/security/sec8447f5049/web), with Remote Login enabled and suitable networking. It requires authentication and a route to the Mac independent of this Tailscale daemon, so it provides a separate unlock workflow rather than fully automatic recovery.
- **Sleep and power:** a sleeping or powered-off Mac cannot be made continuously reachable by `KeepAlive`. Review Apple's [wake for network access settings](https://support.apple.com/en-au/guide/mac-help/mh27905/mac). Whether a remote connection can wake a particular Mac depends on its network and power configuration. This project does not change sleep settings.
- **Network and authentication:** updates require access to Homebrew's services. Tailscale needs usable networking and valid authentication. A boot-time update check can fail while networking is starting; inspect the log and allow the next scheduled check.
- **Remote services:** Screen Sharing must be enabled and permitted on the destination Mac, and the connection must use its current hostname or Tailscale address. Updating the daemon does not enable Screen Sharing or repair an outdated saved hostname.

## Removal and recovery files

`./uninstall.sh` requires a local `.env` matching the actual installation, including the daemon label/plist, state paths, and tailnet domain. Configure this before removal even if the existing-daemon installation did not need `.env`.

Removal stops the updater service before removing Tailscale and deleting its local state. The updater's installed runtime, recovery files, and update log remain; a recovered daemon may depend on the backup executable. Resolve recovery before manually removing those files.

The lifecycle helpers under `scripts/` are internal parts of the installation and removal workflows. Normal setup and updates to these repository scripts use `./install.sh`.
