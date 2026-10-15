# guac

Stands up Guacamole on the guac-host (`guacd` + `guacamole` webapp +
`postgres`, via Docker) and wires up clients behind it. Run after `vps/`
is live.

## Scripts, run in order

| # | Script | Runs on | Runs as |
|---|---|---|---|
| 1 | `setup-ssh.sh` | guac-host | `root` |
| 2 | `setup.sh` | guac-host | `guac` |
| 3 | `setup.sh -a` | guac-host | `guac` |

Steps 1–3 run once, for the guac-host itself. After that, adding a client
is a three-phase loop — get its key, provision it, finalize it — repeated
once per client:

| Phase | Script | Runs on | Runs as |
|---|---|---|---|
| a. Get the pubkey | `client.sh --print-key` | client | any sudo user |
| b. Provision | `add-host.sh` | guac-host | `guac` |
| c. Finalize | `client.sh --vps-ssh-host ...` | client | any sudo user |

Removing a client is one script, run on the guac-host:

```
sudo bash remove-host.sh --name win-desktop
```

### 1. `setup-ssh.sh` — once, as `root`

```
sudo bash setup-ssh.sh -g <you> -i <chars> -e <you@example.com>
```

Thin wrapper around `utils/sh/setup-ssh.sh --user guac` — creates the `guac`
user (full sudo), authorizes your key, confirms it landed in
`authorized_keys`, then calls `utils/sh/harden.sh`. **After this finishes,
disconnect and reconnect as `guac`.**

### 2. `setup.sh` — as `guac`, fresh session

```
sudo bash setup.sh
```

Defaults to `--prepare`: installs Docker, joins the tailnet, generates
Guacamole's Postgres schema (once), writes `.env` (`POSTGRES_PASSWORD` +
the guac-host's `TAILSCALE_IP`), then `docker compose up -d`. The webapp
binds to the guac-host's **Tailscale IP** specifically — not `127.0.0.1`
(the VPS's `cloudflared` reaches it over the tailnet, from a different
box) and not `0.0.0.0` (Docker's published ports bypass `ufw`).

### 3. `setup.sh -a` — as `guac`, once the VPS is reachable over the tailnet

```
sudo bash setup.sh -a
```

Runs `vps/update.sh` on the VPS over SSH: wires guac's hostname into the
shared `cloudflared` tunnel (ingress fragment, DNS route, reconfigure).
Auto-resolves `--vps-host` to the one tailnet peer matching "vps" (pass
`--vps-host`/`-i` if there's more than one).

Defaults to the test subdomain `guac-test` (`-s/--subdomain` to override).
Moving from the test subdomain to the real one is just re-running with it:

```
sudo bash setup.sh -a -s guac
```

You'll have to remove the test subdomain's CNAME yourself (Cloudflare
dashboard) — this is additive, it won't do that for you.

First run needs a one-time SSH key handshake: the guac-host generates its
own key (`/root/.ssh/vps_tunnel_ed25519`), and if the VPS doesn't
recognize it yet, prints the exact command to run **on the VPS, as
`tunnel`**:

```
echo "<pubkey>" >> ~/.ssh/authorized_keys
```

Re-run `setup.sh -a` once that's done.

### a. Get the pubkey — `client.sh --print-key`

**On the client**: not copied anywhere by `setup-ssh.sh` —
clone this repo onto it (or just copy this file plus `utils/sh/print.sh`)
and run it there directly:

```
bash client.sh --print-key
```

Generates the client's dedicated keypair and prints its public half —
hand that to phase b.

### b. Provision — `add-host.sh`

**On the guac-host, as `guac`**:

```
sudo bash add-host.sh --name win-desktop --pubkey "ssh-ed25519 AAAA..."
```

`--pubkey` is the key phase a printed. Assigns the client a unique
forwarded port (tracked in `hosts.registry`, starting at `20001`, not
committed to git), provisions a restricted account for it on the VPS over
SSH (`vps/provision-host.sh`), and adds its VNC connection straight into
Guacamole's Postgres DB. Prints back the exact `client.sh` command for
phase c (`--vps-ssh-host`, `--vps-bind-host`, `--vps-user`, `--port`).

Refuses to re-provision an existing `--name` unless you pass `-f`/`--force`
— that rotates the client's VPS key but never touches its existing
Guacamole connection.

### c. Finalize — `client.sh --vps-ssh-host ...`

**Back on the client**, with the command phase b printed:

```
bash client.sh --vps-ssh-host 203.0.113.10 --vps-bind-host 100.x.x.x --vps-user host-win-desktop --port 20001
```

Two different VPS addresses, both needed: `--vps-ssh-host` (the VPS's
**public** IP — the client has no Tailscale, so it's the only address it
can reach to make the SSH connection) and `--vps-bind-host` (the VPS's
**Tailscale** IP — the forwarded port's bind address, which `permitlisten`
restricts it to server-side, so only the guac-host can reach it over the
tailnet).

Installs `autossh` + `x11vnc` (serving the client's live X session, not a
fresh one — this is why VNC, not RDP) and two systemd services
(`x11vnc`, `vps-vnc-tunnel`) forwarding the client's local VNC port
(`5900` default, `--vnc-port` to override) to its assigned port on the
VPS. Safe to re-run.

### Removing a client — `remove-host.sh`

**On the guac-host, as `guac`**:

```
sudo bash remove-host.sh --name win-desktop
```

Undoes phases a–c's provisioning: removes `host-win-desktop` on the VPS
(over SSH, via `vps/deprovision-host.sh`), deletes the Guacamole
connection, and drops the entry from `hosts.registry`. Prompts for
confirmation unless `-y`/`--yes` is given.

Doesn't touch the client itself — its `vps-vnc-tunnel` systemd service
just starts failing to connect once the VPS account is gone. Disable it
there by hand: `sudo systemctl disable --now vps-vnc-tunnel x11vnc`.

## What restricts a client to just its own port

`provision-host.sh`'s one-time `Match Group rdp-tunnel` sshd block
(`GatewayPorts clientspecified`, `AllowTcpForwarding remote`) lets the
group's accounts request a non-loopback bind at all, but each account's
`authorized_keys` line also carries `permitlisten="<vps-ts-ip>:<port>"` —
the key is refused for any bind except that exact address:port.

## Guards

Scripts that run on the guac-host (`setup-ssh.sh`, `setup.sh`,
`add-host.sh`) refuse to run unless invoked via `sudo` specifically as
`guac`, and unless `utils/sh/harden.sh`'s `ssh-harden` step has completed —
see `utils/sh/guard.sh`. `client.sh` runs on a different box entirely, so
it has no such guard.
