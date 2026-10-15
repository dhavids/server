# vps

Bootstraps the cheap VPS that fronts this whole setup: derper (for a custom
Tailscale DERP relay) and the shared `cloudflared` tunnel both run here,
natively — no Docker, no containers. Run first, before `derp/` or
`cloudflared/`.

## Why a VPS at all

The Pi's home ISP uses CGNAT by default, so no router port-forward can ever
make it reachable from the internet — that's a hard network constraint, not
a config problem. The VPS is the one box that actually has a real public
IP. The Pi joins the same Tailscale network as the VPS and only ever makes
outbound connections, so CGNAT never matters to it.

## Scripts, run in order

**1. `setup-ssh.sh`** — run once, as `root` (however the VPS gave you
root — password, provider console, whatever):

```
sudo bash setup-ssh.sh -g <you> -i <chars> -e <you@example.com>
```

Creates the `tunnel` user (full sudo), authorizes your key (from
`-k`/`--pubkey`, or fetched from `github.com/<user>.keys` via
`-g`/`--github-user` + `-i`/`--key-id` or `-e`/`--email` to disambiguate if
you have more than one key there), confirms the key landed in
`authorized_keys`, then calls `utils/sh/harden.sh` — which disables
root/password SSH login.
**After this finishes, disconnect and reconnect as `tunnel`** — don't keep
using the original root session.

**2. `setup.sh`** — run as `tunnel` (now has full sudo), from a fresh SSH
session:

```
sudo bash setup.sh -d example.com -e you@example.com
```

Joins the tailnet (`tailscale up`, one-time browser approval), then calls
`derp/setup.sh --prepare` — builds derper, writes `cloudflared`'s ingress
fragment, and brings the shared tunnel up. Does **not** run derp's
`--activate` phase (DNS/port-80 checks + the actual cert) — that needs DNS
pointed at this VPS first, run it separately:

```
sudo bash ../derp/setup.sh -a
```

Both scripts refuse to run unless invoked via `sudo` specifically as
`tunnel`, and unless `utils/sh/harden.sh`'s `ssh-harden` step has actually
completed (checked via `/etc/server-hardened`) — see `utils/sh/guard.sh`.

**3. `update.sh`** — run on the VPS (as `tunnel`), typically invoked
remotely by the Pi over its own SSH key rather than typed in by hand, since
the Pi already knows its own Tailscale IP:

```
ssh tunnel@<vps-tailscale-ip> "bash ~/server/vps/update.sh --pi-ip $(tailscale ip -4)"
```

Writes guac's `cloudflared` ingress fragment on the VPS (guac runs on a
different box, so it can't write this fragment itself the way `derp`
does), routes DNS for the subdomain (default `guac-pi`, for testing before
the real `guac` subdomain is wired up), and reconfigures the shared
tunnel. No cert dance needed here — guac rides `cloudflared`'s own TLS
termination.

## What's deliberately not here

Hosts' RDP-forwarding tunnels landing on this VPS, and the `GatewayPorts`
config that lets guac (on the Pi) reach them — that's scoped to guac's own
setup (not yet built), not this one. See
`docs/research/projects/server/scratch.md` for the full architecture
history and open items.
