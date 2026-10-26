# Automatic updates and recovery

The installer includes a system job, `com.tailscale.headless-updater`, which checks stable Tailscale release metadata at boot and daily at 04:15 local time. Change `AUTO_UPDATE_HOUR` and `AUTO_UPDATE_MINUTE` in `.env`, then rerun `./install.sh`. Set `AUTO_UPDATE=false` to remove the schedule while leaving Tailscale running.

## Transaction

1. Acquire the shared lifecycle lock and validate the protected configuration and managed daemon.
2. Confirm that the existing daemon is online; record its version, executable and device ID.
3. Read the stable release version from `https://pkgs.tailscale.com/stable/?mode=json`. A current installation needs no build/restart. Automatic downgrades are refused.
4. Run the protected builder as the recorded non-root `BuildUser`, using that account's private Go/module/build cache. A suitable Go installation is reused; otherwise a SHA-256-verified Go archive for the Mac’s native Intel or Apple Silicon architecture is downloaded directly. Downloaded Tailscale source and dependencies are verified through Go's module checksum service.
5. Build both binaries from one pinned stable module with upstream `build_dist.sh`. Validate copied binaries before touching the service.
6. Save independent recovery binaries, original plist, updater config, version and device ID. Write `TRANSACTION_PENDING` before changing the selected release.
7. Atomically switch `current`, restart the daemon, then check its version, executable, online status and device identity. Clear the transaction marker only on success.

Download/build failures before switching leave the existing service alone. Failures after the transaction starts attempt recovery into the saved binary pair and create `RECOVERY_REQUIRED`, suspending updates. Tailscale's persistent state is not rolled back or rewritten by this updater. New releases can change state formats, so rollback remains a recovery attempt; arrange another access method for first-time testing.

The updater does not execute a writable checkout as root. Runtime scripts and configuration are copied into `/Library/PrivilegedHelperTools/com.tailscale.headless-updater`, owned by root. Builds execute as the installation user, with a clean environment, and require that account to remain available. Release and dependency downloads require working internet access, including `go.dev`, its download redirects, `proxy.golang.org`, `sum.golang.org`, and `pkgs.tailscale.com`.

## Inspect

```sh
sudo launchctl print system/com.tailscale.headless-updater
sudo tail -n 80 /var/log/tailscale-headless-update.log
sudo /Library/PrivilegedHelperTools/com.tailscale.headless-updater/update-tailscale.sh --check
```

The updater is normally idle between runs. Check mode reads local configuration/status only; it does not download, build, take a lock, or restart services. To request an update check:

```sh
sudo launchctl kickstart system/com.tailscale.headless-updater
```

Read the log afterward. A successful kickstart only means the job was requested.

## Recovery hold

Inspect the failure log and `recovery/` directory. A recovered daemon uses `recovery/tailscaled`, and `current` is repointed to the saved CLI/daemon pair. The original state, daemon arguments, socket and identity are preserved. Do not delete recovery files while a daemon depends on them.

Both `RECOVERY_REQUIRED` and an interrupted `TRANSACTION_PENDING` block ordinary updates. An interrupted transaction attempts recovery on the next unlocked run. The shared lock is `/var/run/com.tailscale.headless-updater.lock`; an unclean termination may leave it behind. Confirm its PID is no longer active before clearing a stale lock. Never remove a live lock.

Before clearing a recovery hold, an administrator must understand the failure, validate the saved pair, reconcile the daemon plist and `current` back to a healthy managed release, and test connectivity independently. Reinstalling while a hold exists is refused. The recovery files are not automatically purged by uninstall.

## Scope of verification

Local health checks do not prove every peer, DNS query, remote service or network route works. Reboots need the startup disk unlocked; this project does not bypass FileVault. Sleep, power, authentication expiry and network failures remain relevant. See the [README](../README.md#startup-and-reachability-limits).
