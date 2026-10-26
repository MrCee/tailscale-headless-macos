# tailscale-headless-macos

Run the open-source Tailscale CLI and daemon on **Intel and Apple Silicon macOS**, without a GUI or package manager. Installation and scheduled updates build both binaries from the same stable Tailscale release using Go.

## Requirements

- An Intel or Apple Silicon Mac running macOS 12 or newer, and an OS supported by the selected Tailscale release **and its Go toolchain**. Older systems may need an OS upgrade; this installer does not patch unsupported toolchains.
- A normal administrator account, internet access and an existing Tailscale tailnet.
- Architecture is detected automatically. A Rosetta terminal on Apple Silicon still selects native ARM64 tools and binaries.

You do not need to install Go first. A suitable native Go executable is reused when available. Otherwise, the builder downloads the current stable `darwin-amd64` (Intel) or `darwin-arm64` (Apple Silicon) Go archive from `go.dev`, verifies its SHA-256 against official release metadata, and extracts it into the build user's private cache. It does not replace a system Go installation or run a Go `.pkg` installer.

## Quick start

```sh
git clone https://github.com/MrCee/tailscale-headless-macos.git
cd tailscale-headless-macos
cp .env.example .env
```

Set `TAILNET_DOMAIN` in `.env` to your exact MagicDNS suffix from the Tailscale admin console, for example `your-actual-tailnet.ts.net`. `TS_HOSTNAME` is optional; when blank, the Mac's hostname is detected. Keep authentication keys and state out of Git.

Run as your normal user:

```sh
./install.sh --check
./install.sh
```

Check mode validates local configuration without downloading, building, requesting sudo or changing services. Installation builds the stable release, requests administrator authority, installs root-owned binaries and a system LaunchDaemon, configures MagicDNS and starts interactive enrollment. Initial compilation can take several minutes and requires disk space for Go, module downloads and build caches.

Automatic updates are included by default. With `RUN_TAILSCALE_UP=false`, authenticate the daemon manually before rerunning the installer to configure updates. A failed installation does not report completion; inspect the reported stage before retrying.

## Use the CLI

The managed executables are deliberately outside package-manager paths:

```sh
/Library/PrivilegedHelperTools/com.tailscale.headless/current/tailscale status
```

For convenient commands in your current shell:

```sh
export PATH="/Library/PrivilegedHelperTools/com.tailscale.headless/current:$PATH"
tailscale status
tailscale version
```

If you configured a non-default socket, pass `--socket=/your/socket` before the CLI subcommand. No existing `tailscale` executable in another directory is overwritten.

## How it works

```text
install.sh
  ├─ build-tailscale.sh → stable release metadata → verified Go → source builds
  ├─ system LaunchDaemon → current/tailscaled → persistent Tailscale state
  ├─ /etc/resolver → MagicDNS
  └─ updater LaunchDaemon → build, validate, switch release, health check
```

The source is downloaded as a pinned Go module through `proxy.golang.org`, verified using `sum.golang.org`, and built with upstream `build_dist.sh`. The release version and commit hash are embedded. Both binaries are checked for matching versions and the Mac’s native architecture before use. Builds target `darwin/amd64` with `GOAMD64=v1` on Intel, or `darwin/arm64` with `GOARM64=v8.0` on Apple Silicon, and do not require a C compiler.

| Purpose | Location |
| --- | --- |
| Installed releases | `/Library/PrivilegedHelperTools/com.tailscale.headless/releases/<version>` |
| Selected release | `/Library/PrivilegedHelperTools/com.tailscale.headless/current` |
| Daemon service | `com.tailscale.tailscaled` |
| Default state | `/var/lib/tailscale/tailscaled.state` |
| Default socket | `/var/run/tailscaled.socket` |
| Go/module/build cache | `~/Library/Caches/tailscale-headless` for the installation user |
| Updater runtime and recovery | `/Library/PrivilegedHelperTools/com.tailscale.headless-updater` |
| Update log | `/var/log/tailscale-headless-update.log` |

## Automatic updates

Checks run at boot and daily at **04:15 local time**. When already current, the updater does not compile or restart. A new stable release is built as the recorded non-root installation user; only installation and daemon management use root. No GUI login is required. That user account must remain available.

Before switching releases, the updater saves independent copies of the original binaries and plist. It preserves Tailscale state, verifies the running version, executable, online status and device identity, and attempts rollback if the switch fails. Rollback suspends updates for administrator review. It cannot guarantee uninterrupted remote access.

Change the schedule in `.env`, then rerun `./install.sh`:

```dotenv
AUTO_UPDATE=true
AUTO_UPDATE_HOUR=4
AUTO_UPDATE_MINUTE=15
```

Set `AUTO_UPDATE=false` to remove the schedule while keeping the daemon. See [update and recovery details](docs/automatic-updates.md).

An existing installation made by this Go-based installer can be maintained without resetting authentication. Older or externally managed daemon paths are refused: preserve their state and plan migration separately. Do not run two Tailscale daemons against one state file.

## Verify, repair, remove

```sh
./install.sh --check
./verify.sh
./fix-magicdns.sh
```

Detailed DNS diagnostics use your `.env`. Resolver handling is described in [DNS notes](docs/dns-magicdns-notes.md). The installer supplies an explicit socket to launchd and CLI commands.

To remove this installation, with `.env` matching its actual paths:

```sh
./uninstall.sh
```

Uninstall stops the updater and selected daemon and removes managed binaries, configured state, logs and resolvers. Authentication is lost when state is deleted. Other Tailscale app installations and Go installations are left alone. The build user's private cache and updater recovery/log files are retained for inspection.

## Startup and reachability limits

Both Intel and Apple Silicon installations use a root-owned **system LaunchDaemon**, never a per-user LaunchAgent. The daemon starts before login **after macOS starts and the startup disk is unlocked**. Logging out does not stop it. The updater is also a system LaunchDaemon; changing Tailscale versions does not change this service model.

FileVault can hold startup at disk unlock. On **Apple Silicon with macOS Tahoe 26 or later**, Apple supports [unlocking FileVault over SSH after a restart](https://support.apple.com/en-au/guide/security/sec8447f5049/web), with Remote Login enabled beforehand and a working preboot network. Apple documents previously joined open or WPA2-Personal Wi-Fi, or unauthenticated Ethernet, in its [network requirements](https://support.apple.com/en-au/guide/deployment/dep82064ec40/web). This requires an authorised account password; ordinary SSH-key authentication and a shell are not available during that unlock stage. SSH disconnects after unlocking while macOS starts its remaining services; reconnect afterwards.

This Mac's Tailscale daemon cannot provide the connection used to unlock its own disk. To reach the preboot SSH service remotely, provide a separate route to its LAN, such as an always-on Tailscale subnet router on another device. Test this route and unlock procedure on the actual Mac before relying on it. Apple's documented Tahoe feature is for Apple Silicon; this project does not promise the same capability on Intel Macs.

The installer does not enable Remote Login, store unlock passwords, unlock FileVault or change encryption settings. An unattended power-loss recovery plan still needs an independently verified unlock workflow. Turning FileVault off removes that password gate but reduces protection for stored data.

A sleeping or powered-off Mac, unavailable network, expired authentication or disabled remote service can still prevent access. Test reboot and remote access separately before relying on an unattended machine. Installation does not change sleep, Screen Sharing or Remote Login settings.

## Maintainer checks

```sh
python3 tests/test-install.py
python3 tests/test-updater.py
python3 tests/test-build.py
```

These tests use temporary directories and OS/network adapters. They do not install a service or require sudo. A real source build can be checked without installation:

```sh
./scripts/build-tailscale.sh --output "$PWD/test-build"
./test-build/tailscale version
```

The output directory must not already exist. `--version X.Y.Z` builds a specific stable release. Build output, caches and credentials must not be committed. Full root installation, boot and real network recovery still require verification on a test Mac. A [workflow template](docs/examples/github-actions-checks.yml) is provided for maintainers.

To update this repository's scripts, review changes, pull them, and rerun `./install.sh` on each machine. Publishing GitHub changes does not deploy to installed Macs.

## References

- [Tailscale source and build instructions](https://github.com/tailscale/tailscale#building)
- [Tailscale macOS variants](https://tailscale.com/docs/concepts/macos-variants)
- [Official Go downloads](https://go.dev/dl/)

Original project: MrCee. Licensed under MIT; see [LICENSE](LICENSE).
