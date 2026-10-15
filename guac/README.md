# guac

Stands up Guacamole on the Pi (`guacd` + `guacamole` webapp + `postgres`,
via Docker) and wires up RDP hosts behind it. Run after `vps/` is live.

## Why the Pi, and why Docker here but not on the VPS

The Pi has no public IP (CGNAT) so it can't run anything that needs one
directly — but it doesn't need to: it joins the same Tailscale network as
the VPS, purely outbound, and the VPS's `cloudflared` reaches Guacamole's
webapp over the tailnet instead of `localhost`. Docker is fine here since
nothing on the Pi needs host networking the way derper's STUN did on the
VPS.

## Scripts, run in order

| # | Script | Runs on | Runs as |
|---|---|---|---|
| 1 | `setup-ssh.sh` | Pi | `root` |
| 2 | `setup.sh` | Pi | `pi` |
| 3 | `setup.sh -a` | Pi | `pi` |
| 4 | `add-host.sh` | Pi | `pi` |
| 5 | `client.sh` | the RDP host | any sudo user |

### 1. `setup-ssh.sh` — once, as `root`

```
sudo bash setup-ssh.sh -g <you> -i <chars> -e <you@example.com>
```

Thin wrapper around `utils/sh/setup-ssh.sh --user pi` — creates the `pi`
user (full sudo), authorizes your key, confirms it landed in
`authorized_keys`, then calls `utils/sh/harden.sh`. **After this finishes,
disconnect and reconnect as `pi`.**

### 2. `setup.sh` — as `pi`, fresh session

```
sudo bash setup.sh
```

Defaults to `--prepare`: installs Docker, joins the tailnet, generates
Guacamole's Postgres schema (once), writes `.env` (`POSTGRES_PASSWORD` +
the Pi's `TAILSCALE_IP`), then `docker compose up -d`. The webapp binds to
the Pi's **Tailscale IP** specifically — not `127.0.0.1` (the VPS's
`cloudflared` reaches it over the tailnet, from a different box) and not
`0.0.0.0` (Docker's published ports bypass `ufw`).

### 3. `setup.sh -a` — as `pi`, once the VPS is reachable over the tailnet

```
sudo bash setup.sh -a
```

Runs `vps/update.sh` on the VPS over SSH: wires guac's hostname into the
shared `cloudflared` tunnel (ingress fragment, DNS route, reconfigure).
Auto-resolves `--vps-host` to the one tailnet peer matching "vps" (pass
`--vps-host`/`-i` if there's more than one).

Defaults to the test subdomain `guac-pi` (`-s/--subdomain` to override).
Switch to the real subdomain later by just re-running:

```
sudo bash setup.sh -a -s guac
```

This is additive — it won't remove the old `guac-pi` CNAME. Delete that
from the Cloudflare dashboard yourself if you want it gone.

First run needs a one-time SSH key handshake: this box generates its own
key (`/root/.ssh/vps_tunnel_ed25519`), and if the VPS doesn't recognize it
yet, prints the exact command to run **on the VPS, as `tunnel`**:

```
echo "<pubkey>" >> ~/.ssh/authorized_keys
```

Re-run `setup.sh -a` once that's done.

### 4. `add-host.sh` — as `pi`, once per RDP host

```
sudo bash add-host.sh --name win-desktop --pubkey "ssh-ed25519 AAAA..."
```

`--pubkey` is the host's own key — get it by running `client.sh
--print-key` on the host first (step 5). Assigns the host a unique
forwarded port (tracked in `hosts.registry`, starting at `20001`, not
committed to git), provisions a restricted account for it on the VPS over
SSH (`vps/provision-host.sh`), and adds its RDP connection straight into
Guacamole's Postgres DB. Prints back `--vps-host`, `--vps-user`, and
`--port` for step 5.

Refuses to re-provision an existing `--name` unless you pass `-f`/`--force`
— that rotates the host's VPS key but never touches its existing Guacamole
connection.

### 5. `client.sh` — on the RDP host itself

Not copied anywhere by `setup-ssh.sh` — clone this repo onto the host (or
just copy this file plus `utils/sh/print.sh`) and run it there directly.

```
bash client.sh --print-key
```

Generates the host's dedicated keypair, prints its public half for step 4.

```
bash client.sh --vps-host 100.x.x.x --vps-user host-win-desktop --port 20001
```

With the values step 4 printed back: installs `autossh` and a systemd
service (`vps-rdp-tunnel`) forwarding the host's local RDP port (`3389`
default, `--rdp-port` to override) to its assigned port on the VPS. Safe
to re-run.

## What restricts a host to just its own port

`provision-host.sh`'s one-time `Match Group rdp-tunnel` sshd block
(`GatewayPorts clientspecified`, `AllowTcpForwarding remote`) lets the
group's accounts request a non-loopback bind at all, but each account's
`authorized_keys` line also carries `permitlisten="<vps-ts-ip>:<port>"` —
the key is refused for any bind except that exact address:port.

## Guards

Scripts that run on the Pi (`setup-ssh.sh`, `setup.sh`, `add-host.sh`)
refuse to run unless invoked via `sudo` specifically as `pi`, and unless
`utils/sh/harden.sh`'s `ssh-harden` step has completed — see
`utils/sh/guard.sh`. `client.sh` runs on a different box entirely, so it
has no such guard.

## What's deliberately not here

`tunnel-sshd` / the RDP-forwarding path isn't a container here — it's the
**VPS's** native `sshd`, configured by `add-host.sh` over the `tunnel`
user's SSH access `vps/setup.sh` already established.
