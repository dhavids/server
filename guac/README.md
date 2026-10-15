# guac

Stands up Guacamole on the Pi (`guacd` + `guacamole` webapp + `postgres`,
via Docker) — the one Dockerized target left after the CGNAT pivot moved
derp/cloudflared to the VPS natively. Run after `vps/` is live.

## Why the Pi, and why Docker here but not on the VPS

The Pi has no public IP (CGNAT) so it can't run anything that needs one
directly — but it doesn't need to: it joins the same Tailscale network as
the VPS, purely outbound, and the VPS's `cloudflared` reaches Guacamole's
webapp over the tailnet instead of `localhost`. Docker is fine here since
nothing on the Pi needs host networking the way derper's STUN did on the
VPS.

## Scripts, run in order

**1. `setup-ssh.sh`** — run once, as `root` (however the Pi gave you
root):

```
sudo bash setup-ssh.sh -g <you> -i <chars> -e <you@example.com>
```

Thin wrapper around `utils/sh/setup-ssh.sh --user pi` — creates the `pi`
user (full sudo), authorizes your key, confirms it landed in
`authorized_keys`, then calls `utils/sh/harden.sh`. **After this finishes,
disconnect and reconnect as `pi`** — don't keep using the original root
session.

**2. `setup.sh`** — run as `pi` (now has full sudo), from a fresh SSH
session:

```
sudo bash setup.sh
```

Defaults to `--prepare`: installs Docker, joins the tailnet, generates
Guacamole's Postgres schema (`initdb/01-schema.sql`, from the
`guacamole/guacamole` image, once), writes `.env` (a generated
`POSTGRES_PASSWORD` plus the Pi's current `TAILSCALE_IP`), then
`docker compose up -d`. The webapp binds to the Pi's **Tailscale IP**
specifically, not `127.0.0.1` (the VPS's `cloudflared` needs to reach it
over the tailnet, from a different box) and not `0.0.0.0` (Docker's
published ports bypass `ufw`, so an unscoped bind would also be reachable
from the Pi's public interface).

`--activate` (wiring the VPS's `GatewayPorts`/per-host accounts and
writing Guacamole's RDP connection entries) **isn't built yet** — it needs
a host->forwarded-port registry decided first (each RDP host needs a
unique port on the VPS; nothing assigns/tracks those yet).

Both scripts refuse to run unless invoked via `sudo` specifically as `pi`,
and unless `utils/sh/harden.sh`'s `ssh-harden` step has actually completed
— see `utils/sh/guard.sh`.

## What's deliberately not here

`tunnel-sshd` / the RDP-forwarding path isn't a container here — it's the
**VPS's** native `sshd` (no Docker there at all), configured by this
script's future `--activate` phase over the `tunnel` user's SSH access
`vps/setup.sh` already established. Each RDP host runs its own small
`autossh`-reverse-tunnel script (forwarding its RDP port to a unique port
on the VPS) — that's a separate script for the hosts themselves, not part
of this directory.
