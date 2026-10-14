# server

Scripts for the VPS side of this setup: a custom Tailscale DERP relay
(`derp/`) and the shared Cloudflare Tunnel (`cloudflared/`) that fronts it,
both running natively on a cheap VPS — no Docker, no containers. The Pi/guac
side isn't built yet; this covers only what exists today.

## Why a VPS

The Pi's home ISP uses CGNAT by default, so no router port-forward can ever
make it reachable from the internet. The VPS is the one box with a real
public IP; everything that needs inbound reachability lives here.

## End-to-end setup, in order

**1. `vps/setup-ssh.sh`** — once, as `root` on a fresh VPS:

```
sudo bash vps/setup-ssh.sh -g <your-github-user> -i <chars> -e <you@example.com>
```

Creates a `tunnel` user with full sudo, authorizes your key, and hardens
SSH (disables root/password login). **Disconnect and reconnect as `tunnel`
after this** — don't keep using the root session.

**2. `vps/setup.sh`** — as `tunnel`, from the new session:

```
sudo bash vps/setup.sh -d example.com -e you@example.com
```

Joins Tailscale, then runs `derp/setup.sh`'s `-p`/`--prepare` phase
(installs derper, brings the shared `cloudflared` tunnel up).

**3. `derp/setup.sh -a`** — once DNS is pointed at the VPS and the router's
UDP 3478 is forwarded:

```
sudo bash derp/setup.sh -a
```

Gets the real cert, restarts derper, verifies it's live.

Every script above refuses to run unless invoked via `sudo` specifically as
`tunnel`, and unless hardening has actually completed — see
`utils/sh/guard.sh`.

## Layout

- **`vps/`** — box bootstrap: user creation, hardening, joining Tailscale.
- **`derp/`** — the DERP relay itself.
- **`cloudflared/`** — the one shared tunnel fronting derp (and, later,
  guac/the webserver).
- **`utils/`** — shared helpers (`sh/`) and requirement definitions
  (`conf/`) every script above sources or calls instead of duplicating.

Each has its own README with the details. For the full architecture
history, open decisions, and what's not built yet (guac, the per-host
RDP-forwarding path, backups), see
`docs/research/projects/server/scratch.md`.
