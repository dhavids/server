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

On a fresh box, update and reboot first:

```
sudo apt update && sudo apt upgrade -y && sudo reboot
```

Skipping this can make `openssh-server` fail its postinstall restart
(`systemd`/kernel upgrading in the same transaction — a known Debian/Ubuntu
race). If it happens and `sudo systemctl daemon-reload && sudo dpkg
--configure -a` doesn't fix it, retry from the box's keyboard/monitor, not
SSH — the old sshd can be left holding port 22.

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

Log in at `guacadmin`/`guacadmin` and change it immediately — `guacadmin`
can't change its own password, only another admin's, so create a second
admin user first and do it from there.

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

Decides the protocol here (`--protocol vnc|rdp`, default `vnc`) — not
re-specified later, so phase c can't drift from what was actually
checked. Safe to re-run any time, e.g. to reprint the same flags for
registering this client on a second guac-host — it reuses the saved
key/password/protocol instead of redoing anything, only touching them if
`--protocol` picks something not yet recorded. `vnc` needs a real X11
session (checked only the first time, before generating its password)
since `x11vnc` attaches to the client's own live desktop, not a fresh one
like `rdp` (`xrdp`) does — if this client is
on Wayland (Ubuntu's GNOME default), either switch the session to Xorg
first or re-run with `--protocol rdp`. Generates the client's dedicated
keypair, records the protocol choice, and — for `vnc` — a password too
(`x11vnc` otherwise runs with no auth at all). Prints one paste-ready
flags fragment (`--pubkey ... --protocol ... --vnc-password ...`) to
append onto phase b's `add-host.sh --name ... --vps-host ...`.

### b. Provision — `add-host.sh`

**On the guac-host, as `guac`**:

```
sudo bash add-host.sh --name win-desktop --pubkey "ssh-ed25519 AAAA..." --protocol vnc --vnc-password "..."
```

`--pubkey` and `--vnc-password` (vnc only) are what phase a printed;
`--protocol` must match what it decided. Assigns the client a unique
forwarded port, provisions a restricted account for it on the VPS over
SSH (`vps/provision-host.sh`), and adds its connection straight into
Guacamole's Postgres DB. Prints back the exact `client.sh` command for
phase c (`--vps-ssh-host`, `--vps-bind-host`, `--vps-user`, `--port`).

Port assignment and "is `--name` already provisioned" both check the VPS
directly (`vps/list-ports.sh`, reading each `host-NAME` account's own
`authorized_keys` — not a separate file to keep in sync), not just this
guac-host's local `hosts.registry` cache. That's what lets a second,
independent guac-host (e.g. a Pi alongside a test VM) register the same
`--name` without colliding on a port the first one already has — `--port`
can still pin one explicitly if needed, but shouldn't normally be.

Whether `--name` already has a Guacamole connection is checked **here**,
not on the VPS — that's the other half of multi-guac-host support: a
second guac-host sharing an already-provisioned VPS account still needs
its own connection row, created the first time it runs `add-host.sh` for
that `--name`, no `--force` required. If it's already here, re-running
just updates the password (if `--vnc-password` is given) and stops;
`-f`/`--force` additionally rotates the client's VPS key, but still never
duplicates the connection.

### c. Finalize — `client.sh --vps-ssh-host ...`

**Back on the client**, with the command phase b printed:

```
bash client.sh --vps-ssh-host 203.0.113.10 --vps-bind-host 100.x.x.x --vps-user host-win-desktop --port 20001
```

No `--protocol` here — it's read back from what phase a recorded. Two
different VPS addresses, both needed: `--vps-ssh-host` (the VPS's
**public** IP — the client has no Tailscale, so it's the only address it
can reach to make the SSH connection) and `--vps-bind-host` (the VPS's
**Tailscale** IP — the forwarded port's bind address, which `permitlisten`
restricts it to server-side, so only the guac-host can reach it over the
tailnet).

Installs that protocol's server if missing (`x11vnc` or `xrdp`) and two
systemd services — the server itself (`x11vnc` only; `xrdp` manages its
own) and `vps-<protocol>-tunnel`, forwarding the client's local server
port (`5900` for vnc / `3389` for rdp by default, `--local-port` to
override) to its assigned port on the VPS. Safe to re-run.

### Removing a client — `remove-host.sh`

**On the guac-host, as `guac`**:

```
sudo bash remove-host.sh --name win-desktop
```

Undoes phases a–c's provisioning: removes `host-win-desktop` on the VPS
(over SSH, via `vps/deprovision-host.sh`), deletes the Guacamole
connection, and drops the entry from `hosts.registry`. Prompts for
confirmation unless `-y`/`--yes` is given.

Doesn't touch the client itself — its `vps-<protocol>-tunnel` systemd
service just starts failing to connect once the VPS account is gone.
Disable it there by hand: `sudo systemctl disable --now vps-vnc-tunnel
x11vnc` (swap in `vps-rdp-tunnel`/`xrdp` if the client used RDP).

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
