# DNS / MagicDNS notes

If:

- `tailscale ping example-node` works
- `nslookup example-node.example-tailnet.ts.net 100.100.100.100` works
- but `ping example-node` or app lookups fail

then transport is healthy but macOS resolver plumbing is incomplete.

This project writes:

- `/etc/resolver/ts.net`
- `/etc/resolver/<tailnet>.ts.net`
- `/etc/resolver/search.tailscale`

It also removes stale `*.ts.net` resolver files that do not match the current configured tailnet domain.
