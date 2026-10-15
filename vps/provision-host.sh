#!/bin/bash
# Run on the VPS (as tunnel), invoked remotely by guac/add-host.sh on the
# Pi. Provisions one restricted account per RDP host: a forced reverse-only
# SSH account whose key is good for nothing but binding its own assigned
# port on this VPS's Tailscale interface. The one-time group/Match-block
# setup (GatewayPorts clientspecified, remote-forwarding only) runs every
# time too — idempotent, cheap to repeat.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVER_ROOT="$(dirname "$SCRIPT_DIR")"
readonly RDP_GROUP="rdp-tunnel"
readonly SSHD_DROPIN="/etc/ssh/sshd_config.d/10-rdp-tunnel.conf"
source "$SERVER_ROOT/utils/sh/print.sh"
source "$SERVER_ROOT/utils/sh/guard.sh"

NAME=""
PORT=""
PUBKEY=""


# Usage

usage() {
    cat << 'USAGE'
Usage: sudo bash provision-host.sh --name NAME --port PORT --pubkey KEY

Required:
  --name NAME     Host label (letters, digits, dashes/underscores only) —
                   the system account is host-NAME
  --port PORT     This host's unique forwarded port, from the Pi's registry
  --pubkey KEY    The host's SSH public key, raw content (one line)

Optional:
  -h, --help      Show this help and exit
USAGE
}


# Flag parsing

while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --pubkey) PUBKEY="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) print_error "Unknown flag: $1"; usage; exit 1 ;;
    esac
done

require_root || { usage; exit 1; }
require_user tunnel || exit 1
require_hardened || exit 1

if [ -z "$NAME" ] || [ -z "$PORT" ] || [ -z "$PUBKEY" ]; then
    print_error "--name, --port, and --pubkey are all required"
    usage
    exit 1
fi
if [[ ! "$NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
    print_error "--name must be letters, digits, dashes/underscores only (got: $NAME)"
    exit 1
fi
if ! tailscale ip -4 &> /dev/null; then
    print_error "No tailnet IP assigned on this VPS — tailscale-up must run first."
    exit 1
fi


# One-time group + Match block

if ! getent group "$RDP_GROUP" &> /dev/null; then
    groupadd "$RDP_GROUP"
    print_info "Created group $RDP_GROUP"
fi

cat > "$SSHD_DROPIN" << DROPIN
Match Group $RDP_GROUP
    GatewayPorts clientspecified
    AllowTcpForwarding remote
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
DROPIN
systemctl reload ssh
print_info "sshd Match block for $RDP_GROUP in place, reloaded"


# Per-host account

readonly USER_NAME="host-$NAME"
readonly VPS_TS_IP="$(tailscale ip -4)"
readonly SSH_DIR="/home/$USER_NAME/.ssh"

if id "$USER_NAME" &> /dev/null; then
    print_info "User $USER_NAME already exists — updating its key/port"
else
    # Not nologin: sshd runs authorized_keys' command= through the
    # account's shell, and nologin ignores -c instead of running it.
    useradd -m -s /bin/sh -G "$RDP_GROUP" "$USER_NAME"
    print_info "Created user $USER_NAME"
fi
usermod -aG "$RDP_GROUP" "$USER_NAME"
usermod -s /bin/sh "$USER_NAME"

mkdir -p "$SSH_DIR"
# command= forces any exec/shell request to a no-op (so a plain `ssh ...
# "echo ok"` connectivity check still succeeds) without affecting -N
# (autossh's actual usage never requests a shell/command at all).
echo "restrict,command=\"/bin/true\",permitlisten=\"$VPS_TS_IP:$PORT\" $PUBKEY" > "$SSH_DIR/authorized_keys"
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$USER_NAME:$USER_NAME" "$SSH_DIR"

print_info "Done. $USER_NAME can only bind $VPS_TS_IP:$PORT via -R, nothing else."
