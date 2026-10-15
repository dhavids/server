# vps

Bootstraps the cheap VPS that fronts this whole setup: derper (for a custom
Tailscale DERP relay) and the shared `cloudflared` tunnel both run here,
natively — no Docker, no containers. Run first, before `derp/` or
`cloudflared/`.

## Scripts, run in order

| # | Script | Runs on | Runs as |
|---|---|---|---|
| 1 | `setup-ssh.sh` | VPS | `root` |
| 2 | `setup.sh` | VPS | `tunnel` |
| 3 | `derp/setup.sh -a` | VPS | `tunnel` |
| 4 | `update.sh` | VPS | `tunnel`, invoked from the guac-host |
| 5 | `provision-host.sh` | VPS | `tunnel`, invoked from the guac-host |
| 6 | `deprovision-host.sh` | VPS | `tunnel`, invoked from the guac-host |

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

Creates the `tunnel` user (full sudo), authorizes your key (from
`-k`/`--pubkey`, or fetched from `github.com/<user>.keys` via
`-g`/`--github-user` + `-i`/`--key-id` or `-e`/`--email` to disambiguate if
you have more than one key there), confirms the key landed in
`authorized_keys`, then calls `utils/sh/harden.sh` — which disables
root/password SSH login. **After this finishes, disconnect and reconnect
as `tunnel`.**

### 2. `setup.sh` — as `tunnel`, fresh session

```
sudo bash setup.sh -d example.com -e you@example.com
```

Joins the tailnet (`tailscale up`, one-time browser approval), then calls
`derp/setup.sh --prepare` — builds derper, writes `cloudflared`'s ingress
fragment, and brings the shared tunnel up.

### 3. `derp/setup.sh -a` — as `tunnel`, once DNS is pointed at this VPS

```
sudo bash ../derp/setup.sh -a
```

Runs derp's `--activate` phase (DNS/port-80 checks + the actual cert) —
not called by `setup.sh` itself since it needs DNS pointed here first.

Scripts 1–3 all refuse to run unless invoked via `sudo` specifically as
`tunnel`, and unless `utils/sh/harden.sh`'s `ssh-harden` step has actually
completed (checked via `/etc/server-hardened`) — see `utils/sh/guard.sh`.

### 4. `update.sh` — as `tunnel`, invoked remotely from the guac-host

```
ssh tunnel@<vps-tailscale-ip> "sudo bash ~/server/vps/update.sh --guac-ip $(tailscale ip -4)"
```

Not typed in by hand — this is what `guac/setup.sh -a` runs over SSH.
Writes guac's `cloudflared` ingress fragment on the VPS (guac runs on a
different box, so it can't write this fragment itself the way `derp`
does), routes DNS for the subdomain, and reconfigures the shared tunnel.
No cert dance needed here — guac rides `cloudflared`'s own TLS
termination.

### 5. `provision-host.sh` — as `tunnel`, invoked remotely from the guac-host

Not typed in by hand either — this is what `guac/add-host.sh` runs over
SSH, once per client. Sets up the one-time `rdp-tunnel` sshd `Match`
block (`GatewayPorts clientspecified`, remote forwarding only) if it isn't
there yet, then creates that client's restricted `host-<name>` account,
scoped via `permitlisten` to just its own assigned port on this VPS's
Tailscale IP.

### 6. `deprovision-host.sh` — as `tunnel`, invoked remotely from the guac-host

Not typed in by hand either — this is what `guac/remove-host.sh` runs over
SSH. Removes one client's `host-<name>` account. The one-time `rdp-tunnel`
group/Match block is left in place — other clients still use it.

## What's deliberately not here

Clients' own tunnel scripts (`guac/client.sh`) — that's guac's concern,
since Guacamole on the guac-host is what actually reaches the ports this
VPS forwards. See `guac/README.md` and
`docs/research/projects/server/scratch.md` for the full architecture
history.
