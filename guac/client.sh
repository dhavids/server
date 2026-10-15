#!/bin/bash
# Run on a client (the machine whose screen you want to see), as a normal
# sudo user. Two phases:
#   1. --print-key: generate this host's dedicated keypair and print its
#      public half, to hand to guac/add-host.sh (run on the guac-host).
#   2. The default run: install autossh + x11vnc (if missing), start
#      x11vnc against the current X display, and a systemd service that
#      keeps a reverse tunnel open, forwarding the VNC port to the port
#      guac/add-host.sh assigned it on the VPS. Needs --vps-ssh-host,
#      --vps-bind-host, --vps-user, and --port from that script's output.
#
# VNC, not RDP: Guacamole has no native X11-forwarding support, only VNC,
# RDP, SSH, Telnet, and Kubernetes. x11vnc attaches to the client's own
# live X session (not a fresh one, unlike xrdp), so you see the real
# desktop as it already is.
#
# Two different VPS addresses are needed, not one — this client has no
# Tailscale, so it can only reach the VPS's public IP for the SSH
# connection itself (--vps-ssh-host). But the forwarded port's bind
# address is restricted server-side (provision-host.sh's `permitlisten`)
# to the VPS's Tailscale IP (--vps-bind-host) — that's what lets
# Guacamole, on the guac-host, reach it over the tailnet, and what the -R
# argument must request to be accepted at all.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVER_ROOT="$(dirname "$SCRIPT_DIR")"
readonly KEY_PATH="$HOME/.ssh/vps_vnc_tunnel_ed25519"
source "$SERVER_ROOT/utils/sh/print.sh"

VPS_SSH_HOST=""
VPS_BIND_HOST=""
VPS_USER=""
VPS_SSH_PORT="22"
PORT=""
VNC_PORT="5900"
PRINT_KEY=""


# Usage

usage() {
    cat << 'USAGE'
Usage: bash client.sh --print-key
       bash client.sh --vps-ssh-host HOST --vps-bind-host HOST --vps-user USER --port PORT [options]

--print-key: generate (if needed) this client's keypair and print its
public half — paste it into guac/add-host.sh's --pubkey on the guac-host,
which assigns --port and --vps-user and prints the
--vps-ssh-host/--vps-bind-host to use here.

Once you have those, run again without --print-key to install the
reverse tunnel:

Required:
  --vps-ssh-host HOST   VPS's public IP/hostname — this client has no
                        Tailscale, so this is the only address it can
                        reach to make the SSH connection itself
  --vps-bind-host HOST  VPS's Tailscale IP — the forwarded port's bind
                        address, restricted server-side to this exact
                        address (so only the guac-host, over the tailnet,
                        can reach it)
  --vps-user USER       This client's VPS account, host-NAME (from add-host.sh)
  --port PORT           This client's assigned forwarded port (from add-host.sh)

Optional:
  --vps-ssh-port N   VPS's SSH port (default: 22)
  --vnc-port N       This client's local x11vnc port (default: 5900)
  -h, --help         Show this help and exit
USAGE
}


# Flag parsing

while [ $# -gt 0 ]; do
    case "$1" in
        --print-key) PRINT_KEY="1"; shift ;;
        --vps-ssh-host) VPS_SSH_HOST="$2"; shift 2 ;;
        --vps-bind-host) VPS_BIND_HOST="$2"; shift 2 ;;
        --vps-user) VPS_USER="$2"; shift 2 ;;
        --vps-ssh-port) VPS_SSH_PORT="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --vnc-port) VNC_PORT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) print_error "Unknown flag: $1"; usage; exit 1 ;;
    esac
done


# Run

command -v ssh-keygen &> /dev/null || { sudo apt-get update; sudo apt-get install -y openssh-client; }

if [ ! -f "$KEY_PATH" ]; then
    ssh-keygen -t ed25519 -N '' -f "$KEY_PATH" -C "$(hostname)->vps vnc tunnel" &> /dev/null
    print_info "Generated a new SSH key at $KEY_PATH"
fi

if [ -n "$PRINT_KEY" ]; then
    cat << KEY
Give this to guac/add-host.sh --pubkey on the guac-host:

$(cat "$KEY_PATH.pub")
KEY
    exit 0
fi

if [ -z "$VPS_SSH_HOST" ] || [ -z "$VPS_BIND_HOST" ] || [ -z "$VPS_USER" ] || [ -z "$PORT" ]; then
    print_error "--vps-ssh-host, --vps-bind-host, --vps-user, and --port are all required (run --print-key first if you haven't)"
    usage
    exit 1
fi

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$VPS_SSH_PORT" -i "$KEY_PATH" \
    "$VPS_USER@$VPS_SSH_HOST" "echo ok" &> /dev/null; then
    print_error "$VPS_USER@$VPS_SSH_HOST doesn't accept this key yet. Run --print-key and give it to guac/add-host.sh first."
    exit 1
fi
print_info "SSH to $VPS_USER@$VPS_SSH_HOST confirmed"

MISSING=""
command -v autossh &> /dev/null || MISSING="$MISSING autossh"
command -v x11vnc &> /dev/null || MISSING="$MISSING x11vnc"
if [ -n "$MISSING" ]; then
    sudo apt-get update
    sudo apt-get install -y $MISSING
fi

readonly CURRENT_USER="$(whoami)"

sudo tee /etc/systemd/system/x11vnc.service > /dev/null << SERVICE
[Unit]
Description=x11vnc, serving this user's live X session
After=graphical.target

[Service]
Environment=DISPLAY=:0
Environment=XAUTHORITY=$HOME/.Xauthority
ExecStart=/usr/bin/x11vnc -display :0 -auth $HOME/.Xauthority -rfbport $VNC_PORT -forever -shared
Restart=always
RestartSec=5
User=$CURRENT_USER

[Install]
WantedBy=multi-user.target
SERVICE

sudo tee /etc/systemd/system/vps-vnc-tunnel.service > /dev/null << SERVICE
[Unit]
Description=Reverse VNC tunnel to the VPS
After=network-online.target x11vnc.service
Requires=x11vnc.service

[Service]
ExecStart=/usr/bin/autossh -M 0 -N \
  -R $VPS_BIND_HOST:$PORT:127.0.0.1:$VNC_PORT \
  -p $VPS_SSH_PORT -i $KEY_PATH $VPS_USER@$VPS_SSH_HOST \
  -o "ExitOnForwardFailure=yes" -o "ServerAliveInterval=30" -o "ServerAliveCountMax=3" \
  -o "StrictHostKeyChecking=accept-new"
Restart=always
RestartSec=5
User=$CURRENT_USER

[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable --now x11vnc vps-vnc-tunnel
print_info "Done. Check with: sudo systemctl status x11vnc vps-vnc-tunnel"
print_info "From the VPS: ss -tlnp | grep $PORT (should be bound to $VPS_BIND_HOST)"
