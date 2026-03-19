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

It’s designed for machines that you want online and reachable — without needing to log in or manage an app.

> Set it up once — the machine stays connected, even before login.

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
- Starts at boot via LaunchDaemon
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
- Fallback startup if LaunchDaemon fails

---

## 🧱 How it fits together

```text
Homebrew
   ↓
tailscaled
   ↓
LaunchDaemon
   ↓
/etc/resolver/*
   ↓
macOS DNS
   ↓
MagicDNS
```

---

## ⚙️ Required configuration

### `TAILNET_DOMAIN`

You **must** set your tailnet domain.

Example:

```text
example-tailnet.ts.net
```

Find it with:

```bash
tailscale dns status --all
```

or via:

- Tailscale Admin Console → DNS

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

**Best practice:**

- keep it aligned with your Mac name  
- only override when you actually mean to  

---

## 📋 Requirements

- Tailscale account  
- existing tailnet  
- tailnet domain  
- MagicDNS enabled (recommended)  

---

## 🚀 Quick start

### 1. Clone

```bash
git clone https://github.com/MrCee/tailscale-headless-macos.git
cd tailscale-headless-macos
```

### 2. Create `.env`

```bash
cp .env.example .env
```

Edit:

```dotenv
TAILNET_DOMAIN=your-tailnet.ts.net
```

Optional:

```dotenv
TS_HOSTNAME=your-mac-name
```

---

### 3. Install

```bash
./install.sh
```

This will:

- install or relink Tailscale  
- install LaunchDaemon  
- start `tailscaled`  
- configure DNS resolvers  
- optionally authenticate the node  

---

### 4. Verify

```bash
./verify.sh
```

---

### 5. Repair DNS (if needed)

```bash
./fix-magicdns.sh
```

---

### 6. Uninstall

```bash
./uninstall.sh
```

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

Includes fallback if LaunchDaemon bootstrap fails.

---

### `verify.sh`

Read-only diagnostics:

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

### DNS may take a moment

Right after install or login:

```bash
tailscale status
```

You may briefly see stale data — give it a few seconds.

---

## 🧪 Typical workflows

### Fresh setup

```bash
cp .env.example .env
# edit .env
./install.sh
./verify.sh
```

---

### Fix DNS issues

```bash
./fix-magicdns.sh
./verify.sh
```

---

### Remove everything

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

## 🖥️ Tested on

- macOS Intel  
- macOS Apple Silicon  
- Homebrew installs  

---

## 👤 Author

MrCee

---

## 💡 Summary

> Turn a Mac into a quiet, always-available Tailscale node.

No GUI. No surprises. Just works.
