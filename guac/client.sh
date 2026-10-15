#!/bin/bash
# Run on a client (the machine whose screen you want to see), as a normal
# sudo user. Two phases:
#   1. --print-key [--protocol vnc|rdp]: decides the protocol (default
#      vnc), checks it's actually usable here, generates this client's
#      dedicated keypair, records the choice, and prints the pubkey to
#      hand to guac/add-host.sh --pubkey --protocol <same> (run on the
#      guac-host).
#   2. The default run: installs that protocol's server (x11vnc or xrdp)
#      if missing, and a systemd service that keeps a reverse tunnel
#      open, forwarding its port to the port guac/add-host.sh assigned on
#      the VPS. Needs --vps-ssh-host, --vps-bind-host, --vps-user, and
#      --port from that script's output. Reads the protocol phase 1
#      recorded — not asked again, so it can't drift from what was
#      actually checked/keyed.
#
# VNC vs RDP: Guacamole has no native X11-forwarding support, only VNC,
# RDP, SSH, Telnet, and Kubernetes. VNC (x11vnc) attaches to the client's
# own live X session (not a fresh one) — only works under a real Xorg
# session, not Wayland (checked at --print-key time, before anything else
# happens). RDP (xrdp) spins up its own session instead, works under
# either, at the cost of not being the desktop you're already looking at.
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
readonly KEY_PATH="$HOME/.ssh/vps_tunnel_ed25519"
readonly PROTOCOL_FILE="$HOME/.ssh/vps_tunnel_protocol"
readonly VNC_PASSWORD_FILE="$HOME/.ssh/vps_tunnel_vnc_password"
readonly VNC_AUTH_FILE="$HOME/.vnc/vps_tunnel_passwd"
source "$SERVER_ROOT/utils/sh/print.sh"

VPS_SSH_HOST=""
VPS_BIND_HOST=""
VPS_USER=""
VPS_SSH_PORT="22"
PORT=""
LOCAL_PORT=""
PROTOCOL="vnc"
PROTOCOL_GIVEN=""
PRINT_KEY=""


# Usage

usage() {
    cat << 'USAGE'
Usage: bash client.sh --print-key [--protocol vnc|rdp]
       bash client.sh --vps-ssh-host HOST --vps-bind-host HOST --vps-user USER --port PORT [options]

--print-key: checks --protocol is usable here, generates (if needed) this
client's keypair, records the protocol choice, and prints the public half
— paste it into guac/add-host.sh's --pubkey (and --protocol, to match) on
the guac-host, which assigns --port and --vps-user and prints the
--vps-ssh-host/--vps-bind-host to use here.

Once you have those, run again without --print-key to install that
protocol's server and the reverse tunnel. The protocol itself isn't
re-specified here — it's whatever --print-key already decided.

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
  --protocol vnc|rdp   Only meaningful with --print-key (default: vnc)
  --vps-ssh-port N     VPS's SSH port (default: 22)
  --local-port N       Local server port (default: 5900 for vnc, 3389 for rdp)
  -h, --help           Show this help and exit
USAGE
}


# Flag parsing

while [ $# -gt 0 ]; do
    case "$1" in
        --print-key) PRINT_KEY="1"; shift ;;
        --protocol) PROTOCOL="$2"; PROTOCOL_GIVEN="1"; shift 2 ;;
        --vps-ssh-host) VPS_SSH_HOST="$2"; shift 2 ;;
        --vps-bind-host) VPS_BIND_HOST="$2"; shift 2 ;;
        --vps-user) VPS_USER="$2"; shift 2 ;;
        --vps-ssh-port) VPS_SSH_PORT="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --local-port) LOCAL_PORT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) print_error "Unknown flag: $1"; usage; exit 1 ;;
    esac
done

if [ "$PROTOCOL" != "vnc" ] && [ "$PROTOCOL" != "rdp" ]; then
    print_error "--protocol must be vnc or rdp (got: $PROTOCOL)"
    exit 1
fi


# Run

command -v ssh-keygen &> /dev/null || { sudo apt-get update; sudo apt-get install -y openssh-client; }

if [ -n "$PRINT_KEY" ]; then
    # No --protocol given: reuse whatever was already decided, not the
    # vnc default — re-running --print-key should just reprint what's
    # saved, never silently redecide it.
    if [ -z "$PROTOCOL_GIVEN" ] && [ -f "$PROTOCOL_FILE" ]; then
        PROTOCOL="$(cat "$PROTOCOL_FILE")"
    fi

    if [ ! -f "$KEY_PATH" ]; then
        ssh-keygen -t ed25519 -N '' -f "$KEY_PATH" -C "$(hostname)->vps $PROTOCOL tunnel" &> /dev/null
        print_info "Generated a new SSH key at $KEY_PATH"
    fi
    echo "$PROTOCOL" > "$PROTOCOL_FILE"

    EXTRA_FLAGS=""
    if [ "$PROTOCOL" = "vnc" ]; then
        if [ ! -f "$VNC_PASSWORD_FILE" ]; then
            if [ "${XDG_SESSION_TYPE:-}" != "x11" ]; then
                print_error "--protocol vnc needs a real X11 session (x11vnc can't capture Wayland/XWayland)."
                print_error "Current session type: ${XDG_SESSION_TYPE:-unknown}."
                print_error "Either switch this session to Xorg (log out, pick 'Ubuntu on Xorg' at the"
                print_error "login screen, or set WaylandEnable=false in /etc/gdm3/custom.conf), or"
                print_error "re-run with --protocol rdp instead."
                exit 1
            fi
            openssl rand -hex 8 > "$VNC_PASSWORD_FILE"
            chmod 600 "$VNC_PASSWORD_FILE"
            print_info "Generated a VNC password at $VNC_PASSWORD_FILE"
        fi
        EXTRA_FLAGS=" --vnc-password $(cat "$VNC_PASSWORD_FILE")"
    fi

    cat << KEY
On the guac-host, run add-host.sh with --name and --vps-host filled in, plus these flags:

--pubkey "$(cat "$KEY_PATH.pub")" --protocol $PROTOCOL$EXTRA_FLAGS
KEY
    exit 0
fi

if [ ! -f "$PROTOCOL_FILE" ]; then
    print_error "No recorded protocol — run --print-key first."
    exit 1
fi
PROTOCOL="$(cat "$PROTOCOL_FILE")"

if [ -z "$LOCAL_PORT" ]; then
    [ "$PROTOCOL" = "vnc" ] && LOCAL_PORT="5900" || LOCAL_PORT="3389"
fi

if [ -z "$VPS_SSH_HOST" ] || [ -z "$VPS_BIND_HOST" ] || [ -z "$VPS_USER" ] || [ -z "$PORT" ]; then
    print_error "--vps-ssh-host, --vps-bind-host, --vps-user, and --port are all required (run --print-key first if you haven't)"
    usage
    exit 1
fi

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -p "$VPS_SSH_PORT" -i "$KEY_PATH" \
    "$VPS_USER@$VPS_SSH_HOST" "echo ok" &> /dev/null; then
    print_error "$VPS_USER@$VPS_SSH_HOST doesn't accept this key yet. Run --print-key and give it to guac/add-host.sh first."
    exit 1
fi
print_info "SSH to $VPS_USER@$VPS_SSH_HOST confirmed"

readonly CURRENT_USER="$(whoami)"
readonly TUNNEL_UNIT="vps-$PROTOCOL-tunnel"

command -v autossh &> /dev/null || { sudo apt-get update; sudo apt-get install -y autossh; }

# Already something on the target local port: reuse it, don't touch any
# existing server/service — could be another tool's x11vnc/xrdp already
# serving this same desktop, and overwriting its unit could restart it.
if ss -tln 2> /dev/null | grep -q ":$LOCAL_PORT "; then
    print_info "Something's already listening on 127.0.0.1:$LOCAL_PORT — reusing it, not installing/starting $PROTOCOL's server"
elif [ "$PROTOCOL" = "vnc" ]; then
    command -v x11vnc &> /dev/null || { sudo apt-get update; sudo apt-get install -y x11vnc; }
    if [ ! -f "$VNC_PASSWORD_FILE" ]; then
        openssl rand -hex 8 > "$VNC_PASSWORD_FILE"
        chmod 600 "$VNC_PASSWORD_FILE"
        print_info "No VNC password on record — generated one, but it won't match what Guacamole has unless you also re-run add-host.sh --vnc-password $(cat "$VNC_PASSWORD_FILE")"
    fi
    mkdir -p "$(dirname "$VNC_AUTH_FILE")"
    x11vnc -storepasswd "$(cat "$VNC_PASSWORD_FILE")" "$VNC_AUTH_FILE" &> /dev/null
    # -noxdamage: XDAMAGE-based screen grabs crash (BadMatch) under some
    # compositing window managers; x11vnc falls back to plain polling without it.
    sudo tee /etc/systemd/system/x11vnc.service > /dev/null << SERVICE
[Unit]
Description=x11vnc, serving this user's live X session
After=graphical.target

[Service]
Environment=DISPLAY=:0
Environment=XAUTHORITY=$HOME/.Xauthority
ExecStart=/usr/bin/x11vnc -display :0 -auth $HOME/.Xauthority -rfbport $LOCAL_PORT -forever -shared -noxdamage -rfbauth $VNC_AUTH_FILE
Restart=always
RestartSec=5
User=$CURRENT_USER

[Install]
WantedBy=multi-user.target
SERVICE
    sudo systemctl daemon-reload
    sudo systemctl enable x11vnc
    sudo systemctl restart x11vnc
else
    command -v xrdp &> /dev/null || { sudo apt-get update; sudo apt-get install -y xrdp; }
    sudo systemctl enable --now xrdp
fi

# No Requires= on the server unit: caused a systemd ordering cycle, and isn't needed.
sudo tee "/etc/systemd/system/$TUNNEL_UNIT.service" > /dev/null << SERVICE
[Unit]
Description=Reverse $PROTOCOL tunnel to the VPS
After=network-online.target

[Service]
ExecStart=/usr/bin/autossh -M 0 -N \
  -R $VPS_BIND_HOST:$PORT:127.0.0.1:$LOCAL_PORT \
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
sudo systemctl enable --now "$TUNNEL_UNIT"
print_info "Done. Check with: sudo systemctl status $TUNNEL_UNIT"
print_info "From the VPS: ss -tlnp | grep $PORT (should be bound to $VPS_BIND_HOST)"
