# Architecture

- Pinned stable Tailscale Go module, verified through the Go checksum database.
- Direct verified Go bootstrap when no suitable native toolchain is available.
- Native Intel or Apple Silicon `tailscale` and `tailscaled` builds using upstream `build_dist.sh`.
- Root-owned versioned binaries with an atomic `current` selection.
- System launchd service for startup after the disk is unlocked.
- Explicit resolver files for MagicDNS.
- Non-root scheduled builds, followed by privileged installation, health checks and recovery holds.

State and authentication remain separate from replaceable executables. Intel and Apple Silicon macOS are supported; Rosetta shells select native ARM64 builds.
