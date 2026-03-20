# Troubleshooting

## Bootstrap failed: 5

If `launchctl bootstrap` fails with an I/O error, the installer falls back to a manual daemon start for the current session.

## Hostname gets `-1` suffix

That usually means stale local state collided with an existing node record.
Delete the exisiting record node(s) from the web UI and run again.

## `tailscale ping` works, app lookup fails

That is usually resolver plumbing, not transport failure.

Run:

```bash
./fix-magicdns.sh
./verify.sh
```
