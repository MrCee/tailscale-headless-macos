# Troubleshooting

## Build or Go bootstrap failed

Check network access, disk space, the release's minimum macOS/Go requirements and the reported checksum/version error. A checksum mismatch must be investigated; do not bypass it. Build cache: `~/Library/Caches/tailscale-headless` for the installation user.

A build lock is left after an unclean termination. Confirm no builder is running before removing `build.lock` from that cache. A scheduled build runs as the account recorded in the installed updater config; that account must still exist.

## Bootstrap failed

Inspect the daemon plist with `plutil -lint`, inspect the daemon logs and read `launchctl print system/com.tailscale.tailscaled`. A bootstrap failure is reported as incomplete setup; there is no temporary manual-daemon fallback. Resolve the partial service before rerunning installation.

## Existing service uses an older binary path

This installer maintains only its own Go-built binaries. Preserve the old service's plist, state, socket and authentication and plan an explicit migration. Do not start a second daemon or delete state to force setup.

## Hostname receives a suffix

Inspect the local and admin-console device records before changing anything. Do not delete state or device records solely to remove a suffix; verify which identity is active first.

## Tailscale transport works but app lookups fail

Inspect `.env`, then run `./verify.sh`. If the resolver configuration is incorrect, use `./fix-magicdns.sh`. See [DNS notes](dns-magicdns-notes.md).

## Update on hold

Read the update log and [recovery guidance](automatic-updates.md#recovery-hold). Do not clear a hold or delete recovery binaries blindly.
