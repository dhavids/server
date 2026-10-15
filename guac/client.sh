#!/bin/bash
# Run on an RDP host (the machine being remoted into), as a normal sudo
# user. Two phases:
#   1. --print-key: generate this host's dedicated keypair and print its
#      public half, to hand to guac/add-host.sh (run on the Pi).
#   2. The default run: install autossh and a systemd service that keeps a
#      reverse tunnel open, forwarding this host's RDP port to the port
#      guac/add-host.sh assigned it on the VPS. Needs --vps-host,
#      --vps-user, and --port from that script's output.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVER_ROOT="$(dirname "$SCRIPT_DIR")"
readonly KEY_PATH="$HOME/.ssh/vps_rdp_tunnel_ed25519"
source "$SERVER_ROOT/utils/sh/print.sh"

VPS_HOST=""
VPS_USER=""
VPS_SSH_PORT="22"
PORT=""
RDP_PORT="3389"
PRINT_KEY=""


# Usage

usage() {
    cat << 'USAGE'
Usage: bash client.sh --print-key
       bash client.sh --vps-host HOST --vps-user USER --port PORT [options]

--print-key: generate (if needed) this host's keypair and print its public
half — paste it into guac/add-host.sh's --pubkey on the Pi, which assigns
--port and --vps-user and tells you the --vps-host to use here.

Once you have those three, run again without --print-key to install the
reverse tunnel:

Required:
  --vps-host HOST    VPS's Tailscale IP (from add-host.sh's output)
  --vps-user USER    This host's VPS account, host-NAME (from add-host.sh)
  --port PORT        This host's assigned forwarded port (from add-host.sh)

Optional:
  --vps-ssh-port N   VPS's SSH port (default: 22)
  --rdp-port N       This host's local RDP port (default: 3389)
  -h, --help         Show this help and exit
USAGE
}


# Flag parsing

while [ $# -gt 0 ]; do
    case "$1" in
        --print-key) PRINT_KEY="1"; shift ;;
        --vps-host) VPS_HOST="$2"; shift 2 ;;
        --vps-user) VPS_USER="$2"; shift 2 ;;
        --vps-ssh-port) VPS_SSH_PORT="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --rdp-port) RDP_PORT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) print_error "Unknown flag: $1"; usage; exit 1 ;;
    esac
done

if [ ! -f "$KEY_PATH" ]; then
    ssh-keygen -t ed25519 -N '' -f "$KEY_PATH" -C "$(hostname)->vps rdp tunnel" &> /dev/null
    print_info "Generated a new SSH key at $KEY_PATH"
fi

if [ -n "$PRINT_KEY" ]; then
    cat << KEY
Give this to guac/add-host.sh --pubkey on the Pi:

$(cat "$KEY_PATH.pub")
KEY
    exit 0
fi

if [ -z "$VPS_HOST" ] || [ -z "$VPS_USER" ] || [ -z "$PORT" ]; then
    print_error "--vps-host, --vps-user, and --port are all required (run --print-key first if you haven't)"
    usage
    exit 1
fi

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$VPS_SSH_PORT" -i "$KEY_PATH" \
    "$VPS_USER@$VPS_HOST" "echo ok" &> /dev/null; then
    print_error "$VPS_USER@$VPS_HOST doesn't accept this key yet. Run --print-key and give it to guac/add-host.sh first."
    exit 1
fi
print_info "SSH to $VPS_USER@$VPS_HOST confirmed"

command -v autossh &> /dev/null || { sudo apt-get update; sudo apt-get install -y autossh; }

readonly CURRENT_USER="$(whoami)"
sudo tee /etc/systemd/system/vps-rdp-tunnel.service > /dev/null << SERVICE
[Unit]
Description=Reverse RDP tunnel to the VPS
After=network-online.target

[Service]
ExecStart=/usr/bin/autossh -M 0 -N \
  -R $VPS_HOST:$PORT:127.0.0.1:$RDP_PORT \
  -p $VPS_SSH_PORT -i $KEY_PATH $VPS_USER@$VPS_HOST \
  -o "ExitOnForwardFailure=yes" -o "ServerAliveInterval=30" -o "ServerAliveCountMax=3" \
  -o "StrictHostKeyChecking=accept-new"
Restart=always
RestartSec=5
User=$CURRENT_USER

[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable --now vps-rdp-tunnel
print_info "Done. Check it with: sudo systemctl status vps-rdp-tunnel"
print_info "From the VPS: ss -tlnp | grep $PORT (should be bound to $VPS_HOST)"
