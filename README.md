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

## What this is

A headless Tailscale setup for macOS.

This project runs:

- `tailscaled` via Homebrew  
- supervised by a system LaunchDaemon  
- with explicit MagicDNS resolver wiring under `/etc/resolver`  

No GUI. No menu bar. No login session required.

> macOS runs as a Tailscale node — reachable before login, with reliable DNS.

---

## Features

- Headless `tailscaled`
- LaunchDaemon supervision at boot
- Explicit MagicDNS resolver wiring
- Automatic stale resolver cleanup
- zsh-safe scripting
- install / verify / repair / uninstall workflows
- hostname auto-detection (`TS_HOSTNAME`)
- warning on hostname mismatch
- fallback daemon start if LaunchDaemon bootstrap fails

---

## Architecture

```text
Homebrew
   ↓
tailscaled
   ↓
LaunchDaemon
   ↓
/etc/resolver/*
   ↓
macOS DNS stack
   ↓
MagicDNS resolution
```

---

## Required configuration

### `TAILNET_DOMAIN`

Your tailnet domain is required.

Example:

```text
example-tailnet.ts.net
```

Find it via:

```bash
tailscale dns status --all
```

or:

- Tailscale Admin Console → DNS

Do not guess this value.

---

## Hostname behaviour

`TS_HOSTNAME` controls:

```bash
tailscale up --hostname=...
```

If unset, it is auto-detected from macOS:

1. `LocalHostName`
2. `ComputerName`
3. `hostname -s`

If set but different, a warning is shown and the configured value is used.

Recommended:

- keep it aligned with the Mac hostname  
- override only intentionally  

---

## Requirements

- Tailscale account
- existing tailnet
- tailnet domain (MagicDNS suffix)
- MagicDNS enabled (recommended)

---

## Quick start

### 1. Clone

```bash
git clone https://github.com/MrCee/tailscale-headless-macos.git
cd tailscale-headless-macos
```

### 2. Create `.env`

```bash
cp .env.example .env
```

Edit `.env`:

```dotenv
TAILNET_DOMAIN=your-tailnet.ts.net
```

Optional:

```dotenv
TS_HOSTNAME=your-mac-name
```

- `TAILNET_DOMAIN` must match your real tailnet  
- If set, replace `TS_HOSTNAME` with your actual hostname  
- If unset, `TS_HOSTNAME` will be auto-detected  

### 3. Install

```bash
./install.sh
```

This will:

- install or relink Tailscale
- install LaunchDaemon
- start `tailscaled`
- configure `/etc/resolver`
- optionally run `tailscale up`

### 4. Verify

```bash
./verify.sh
```

### 5. Repair DNS (if needed)

```bash
./fix-magicdns.sh
```

### 6. Uninstall

```bash
./uninstall.sh
```

---

## Script overview

### `install.sh`

Main provisioning entrypoint:

- ensures sudo session
- installs or relinks Tailscale
- prepares state + logs
- installs LaunchDaemon
- starts daemon
- writes resolver files
- flushes DNS
- optionally runs `tailscale up`

Falls back to manual daemon start if required.

---

### `verify.sh`

Read-only diagnostics:

- binary presence
- daemon state
- LaunchDaemon status
- socket presence
- resolver files
- DNS resolution
- logs

Shows partial vs healthy states.

---

### `fix-magicdns.sh`

Repairs DNS only:

- ensures `/etc/resolver`
- removes stale `*.ts.net`
- rewrites managed resolvers
- flushes DNS cache

---

### `uninstall.sh`

Removes system state:

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

## MagicDNS model

Resolver files are explicitly managed:

```text
/etc/resolver/ts.net
/etc/resolver/<tailnet>.ts.net
/etc/resolver/search.tailscale
```

This avoids DNS issues commonly seen on headless macOS setups.

Stale resolvers are automatically cleaned:

```text
/etc/resolver/*.ts.net
```

---

## Known behaviour

### DNS convergence delay

Immediately after install or authentication:

```bash
tailscale status
```

may briefly show stale data.

Wait a few seconds and retry.

---

## Typical workflows

### Fresh install

```bash
cp .env.example .env
# edit .env and set TAILNET_DOMAIN
./install.sh
./verify.sh
```

### DNS repair

```bash
./fix-magicdns.sh
./verify.sh
```

### Full removal

```bash
./uninstall.sh
```

---

## Design principles

- explicit over implicit
- system-level over user session
- explicit DNS wiring
- fail-fast where appropriate
- clear separation: install, verify, repair, uninstall

---

## Tested target

- macOS Intel
- macOS Apple Silicon
- Homebrew-based installs

---

## Author

MrCee

---

## Summary

> macOS as a headless, always-on Tailscale node

No GUI. No guesswork. Always on.
