# Architecture

This project is built around a small deterministic stack:

- `tailscale` CLI from Homebrew
- `tailscaled` daemon
- `launchd` LaunchDaemon for pre-login startup
- explicit macOS resolver files for MagicDNS

Goals:

- pre-login availability
- no GUI dependency
- deterministic system paths
- explicit DNS repair and verification
