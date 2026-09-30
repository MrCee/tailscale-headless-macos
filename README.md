# tailscale-headless-macos

<div align="left">

![Platform](https://img.shields.io/badge/platform-macOS-black)
![Arch](https://img.shields.io/badge/arch-Apple%20Silicon%20%2B%20Intel-blue)
![Runtime](https://img.shields.io/badge/runtime-tailscaled-1f6feb)
![Supervisor](https://img.shields.io/badge/supervisor-launchd-orange)
![Mode](https://img.shields.io/badge/mode-headless-critical)
![DNS](https://img.shields.io/badge/dns-MagicDNS%20explicit-success)
![Goal](https://img.shields.io/badge/goal-pre--login%20networking-success)
![License](https://img.shields.io/badge/license-MIT-success)

</div>

---

## 🧠 What this is

A simple, reliable way to set up Tailscale on macOS without needing the GUI app.

This project:

- installs and runs `tailscaled` via Homebrew  
- manages it with a system LaunchDaemon  
- configures MagicDNS explicitly  
- checks for stable Homebrew updates at boot and daily

It’s designed for machines that you want online and reachable — without needing to log in or manage an app.

> **One installation includes the daemon and automatic updates.** The daemon starts before user login once macOS has booted and the startup volume is unlocked.

> 🔐 **Unattended startup:** For fully automatic recovery after a cold start or unexpected power loss using this setup alone, **FileVault must be off**. This applies to Intel and Apple silicon. Read the [FileVault startup requirements](#filevault-and-unattended-restarts).

Once the disk is unlocked and macOS is running, FileVault does not prevent normal Tailscale connectivity. Reachability still depends on power, sleep, networking, and Tailscale authentication.

---

## 🎯 When this makes sense

This is **not** for everyone.

Use it if you want:

- a Mac that stays connected even when nobody is logged in  
- remote access to machines like iMacs, minis, or lab devices  
- predictable DNS behaviour (no mystery breakage)  
- to avoid the macOS Tailscale GUI entirely  

If you’re happy using the official app — you probably don’t need this.

---

## ✨ Features

- Fully headless `tailscaled`
- Starts at boot via LaunchDaemon, after any required [FileVault unlock](#filevault-and-unattended-restarts)
- Unattended updates at boot and daily, with health checks and rollback
- Explicit MagicDNS resolver setup
- Cleans up stale DNS configs automatically
- Safe for zsh environments
- Structured workflows:
  - install
  - verify
  - repair
  - uninstall
- Smart hostname detection
- Warning if hostname doesn’t match expectation

---

## 🧱 How it fits together

```text
./install.sh
   ├─ Tailscale LaunchDaemon → tailscaled → tailnet connection
   ├─ Update LaunchDaemon   → Homebrew   → stable package updates
   └─ /etc/resolver/*       → macOS DNS  → MagicDNS
```

---

## ⚙️ Required configuration

### `TAILNET_DOMAIN`

Set your tailnet domain in `.env` for initial setup.

Example:

```text
example-tailnet.ts.net
```

Find it in **Tailscale Admin Console → DNS**. If Tailscale is already connected, you can also use:

```bash
tailscale dns status --all
```

> Do not guess this — it must be exact.

---

## 🖥️ Hostname behaviour

Controls:

```bash
tailscale up --hostname=...
```

If not set, it’s auto-detected from:

1. `LocalHostName`
2. `ComputerName`
3. `hostname -s`

If you override it and it differs — you’ll get a warning.

To override the detected name, set this in `.env`:

```dotenv
TS_HOSTNAME=your-mac-name
```

**Best practice:**

- keep it aligned with your Mac name  
- only override when you actually mean to  

---

## 📋 Requirements

| Requirement | Details |
| --- | --- |
| macOS | An installed macOS version that can run Homebrew and the Tailscale package |
| Homebrew | Already installed at `/usr/local` on Intel or `/opt/homebrew` on Apple silicon |
| Administrator access | Run setup as the Homebrew-owning user; authenticate with `sudo` when prompted |
| Tailscale | An account and existing tailnet; fresh setup requires authentication and the tailnet domain |
| MagicDNS | Enabled in the tailnet, recommended for hostname access |
| Unattended startup | Review the [FileVault startup note](#filevault-and-unattended-restarts) and check access after a restart |

---

## 🚀 Quick start

Before relying on access after a restart, read the [FileVault startup note](#filevault-and-unattended-restarts).

### 1. Clone

```bash
git clone https://github.com/MrCee/tailscale-headless-macos.git
cd tailscale-headless-macos
```

### 2. Configure

Create the configuration file if it does not already exist:

```bash
test -f .env || cp .env.example .env
```

Set your actual tailnet domain in `.env`:

```dotenv
TAILNET_DOMAIN=your-tailnet.ts.net
```

---

### 3. Install

```bash
./install.sh
```

The installer automatically detects an existing compatible daemon. It installs or maintains the headless service and enables automatic updates, preserving an existing daemon's settings and authentication.

Run as the user who owns Homebrew. Initial setup requires administrator authentication and tailnet enrollment. After setup, launchd manages the daemon and scheduled checks as system services, without the Tailscale GUI.

To inspect the setup before installing, run `./install.sh --check`.

---

### 4. Verify

```bash
./install.sh --check
tailscale status
```

For detailed daemon and DNS diagnostics, use `./verify.sh` with a local `.env` containing the expected tailnet and hostname.

---

## 🔄 Automatic updates

Automatic updates are included in `./install.sh` and enabled by default.

| Setting | Default |
| --- | --- |
| When it checks | At boot and daily at **04:15 local time** |
| What it updates | The stable Homebrew `tailscale` formula and required dependencies |
| When it restarts | When needed to run the installed package |
| If an update fails | Attempts recovery using the saved daemon and pauses further updates for review |
| Activity log | `/var/log/tailscale-headless-update.log` |

To change the daily time, set these values in `.env` and rerun `./install.sh`:

```dotenv
AUTO_UPDATE=true
AUTO_UPDATE_HOUR=4
AUTO_UPDATE_MINUTE=15
```

For custom settings, diagnostics, and recovery, see [Automatic updates](docs/automatic-updates.md).

---

## 🔍 Script overview

### `install.sh`

Main setup flow:

- ensures sudo session  
- installs or relinks Tailscale  
- prepares state + logs  
- installs LaunchDaemon  
- starts daemon  
- writes resolver files  
- flushes DNS  
- optionally runs `tailscale up`  
- installs the included automatic updater

An existing compatible, authenticated daemon is preserved; rerunning `install.sh` configures the included updater without rebuilding the daemon setup. A fresh setup must have a healthy system LaunchDaemon before automatic updates can be enabled.

The updater service is `com.tailscale.headless-updater`. It runs Homebrew as its owning user, preserves Tailscale state, and records activity in `/var/log/tailscale-headless-update.log`. Its installation and removal helpers live under `scripts/` and are called by the main setup/removal flow.

---

### `verify.sh`

Detailed read-only diagnostics using the tailnet and expected hostname in `.env`:

- binary check  
- daemon state  
- LaunchDaemon status  
- socket presence  
- resolver files  
- DNS resolution  
- logs  

Helps identify partial vs healthy setups.

---

### `fix-magicdns.sh`

DNS repair only:

- ensures `/etc/resolver` exists  
- removes stale `*.ts.net` files  
- rewrites managed resolvers  
- flushes DNS  

---

### `uninstall.sh`

Clean removal:

- removes the automatic update service
- stops daemon  
- removes LaunchDaemon  
- clears state + logs  
- removes resolver files  
- flushes DNS  

Optional:

```dotenv
REMOVE_BREW_PACKAGE=true
```

---

## 🌐 MagicDNS model

Resolvers are explicitly managed:

```text
/etc/resolver/ts.net
/etc/resolver/<tailnet>.ts.net
/etc/resolver/search.tailscale
```

This avoids common macOS DNS edge cases in headless setups.

Old resolver files are automatically cleaned:

```text
/etc/resolver/*.ts.net
```

---

## ⚠️ Known behaviour

### FileVault and unattended restarts

**For fully unattended recovery after a cold start or unexpected power loss using this setup alone, FileVault must be off.** This applies to Intel and Apple silicon, including macOS 15 Sequoia and macOS 26 Tahoe. With FileVault enabled, the Mac can wait for an unlock while this Tailscale daemon is unavailable. See [Apple's FileVault guidance](https://support.apple.com/en-au/guide/deployment/dep82064ec40/web).

FileVault can remain enabled if you have a separate unlock workflow. Tailscale works normally once the disk is unlocked.

Disabling FileVault reduces protection for stored data. The installer leaves this setting unchanged.

For planned restarts, Tahoe's remote-unlock option, and other connection requirements, see [startup and reachability limits](docs/automatic-updates.md#startup-and-reachability-limits).

---

### DNS may take a moment

Right after install or login:

```bash
tailscale status
```

You may briefly see stale data — give it a few seconds.

---

## 🧰 Maintenance

### Fix DNS issues

```bash
./fix-magicdns.sh
./verify.sh
```

---

### Update the project's scripts

```bash
git pull --ff-only
./install.sh
```

Review repository changes before installing them. The installer keeps a compatible running daemon and its authentication in place.

---

### Remove everything

Ensure `.env` matches the installation before removing its daemon and state.

```bash
./uninstall.sh
```

---

## 🧩 Design approach

- keep everything explicit  
- run at system level, not user level  
- avoid hidden macOS behaviour  
- separate install / verify / repair clearly  
- make failures visible and fixable  

---

## 🖥️ Platforms and verification

The scripts use the standard Intel and Apple silicon Homebrew paths.

Installer and updater tests use isolated simulations. Installation and startup after a reboot need verification on each Mac; see [maintainer checks](docs/automatic-updates.md#maintainer-checks).

---

## 👤 Author

MrCee

---

## 💡 Summary

Run a Mac as a headless Tailscale node, with system startup and unattended package updates included in the installation.

Each Mac needs its own installation. Publishing a change to GitHub does not deploy it to your machines.
