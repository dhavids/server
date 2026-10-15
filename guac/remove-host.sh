#!/bin/bash
# Run on the guac-host (as guac), to fully remove a client: deletes its
# VPS account (over ssh, via vps/deprovision-host.sh), its Guacamole
# connection, and its hosts.registry entry. Doesn't touch the client
# itself — stop/disable its vps-rdp-tunnel systemd service there by hand.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVER_ROOT="$(dirname "$SCRIPT_DIR")"
readonly ENV_FILE="$SCRIPT_DIR/.env"
readonly REGISTRY_FILE="$SCRIPT_DIR/hosts.registry"
readonly BASE_PORT="20001"
source "$SERVER_ROOT/utils/sh/print.sh"
source "$SERVER_ROOT/utils/sh/guard.sh"
source "$SERVER_ROOT/utils/sh/tailscale.sh"
source "$SERVER_ROOT/utils/sh/vps_ssh.sh"
source "$SCRIPT_DIR/lib.sh"

NAME=""
VPS_HOST=""
VPS_ID=""
ASSUME_YES="0"


# Usage

usage() {
    cat << 'USAGE'
Usage: sudo bash remove-host.sh --name NAME [options]

Required:
  --name NAME       Host label, as given to add-host.sh

Optional:
  --vps-host HOST   VPS's Tailscale IP/hostname
  -i, --vps-id ID   VPS's <hostname-prefix>-<ip-suffix>, resolved via
                     'tailscale status' — alternative to --vps-host. If
                     neither is given, auto-resolves to the one tailnet
                     peer whose hostname contains "vps".
  -y, --yes         Don't prompt before removing anything
  -h, --help        Show this help and exit
USAGE
}

confirm() {
    local prompt="$1"
    [ "$ASSUME_YES" = "1" ] && return 0
    local reply
    read -rp "$prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}


# Flag parsing

while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME="$2"; shift 2 ;;
        --vps-host) VPS_HOST="$2"; shift 2 ;;
        -i|--vps-id) VPS_ID="$2"; shift 2 ;;
        -y|--yes) ASSUME_YES="1"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) print_error "Unknown flag: $1"; usage; exit 1 ;;
    esac
done

require_root || { usage; exit 1; }
require_user guac || exit 1
require_hardened || exit 1

if [ -z "$NAME" ]; then
    print_error "--name is required"
    usage
    exit 1
fi

PORT="$(registry_port_for "$NAME" || true)"
if [ -z "$PORT" ]; then
    print_error "'$NAME' isn't in $REGISTRY_FILE — nothing to remove"
    exit 1
fi

if [ -z "$VPS_HOST" ] && [ -n "$VPS_ID" ]; then
    VPS_HOST="$(resolve_tailscale_peer "$VPS_ID")" || exit 1
    print_info "Resolved --vps-id '$VPS_ID' to $VPS_HOST"
fi
if [ -z "$VPS_HOST" ]; then
    VPS_HOST="$(resolve_tailscale_peer vps)" || exit 1
    print_info "No --vps-host/--vps-id given — auto-resolved to the one tailnet peer matching 'vps': $VPS_HOST"
fi

confirm "Remove '$NAME' (port $PORT, VPS account host-$NAME, and its Guacamole connection)?" \
    || { print_warn "Aborted"; exit 1; }


# Run

ensure_vps_ssh_access "$VPS_HOST" || exit 1

print_info "Removing host-$NAME on $VPS_HOST via ssh"
ssh -i "$VPS_SSH_KEY" "tunnel@$VPS_HOST" \
    "sudo bash ~/server/vps/deprovision-host.sh --name '$NAME'"

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    print_info "Removing $NAME's Guacamole connection"
    # guacamole_connection_parameter/_permission both FK connection_id
    # ON DELETE CASCADE in Guacamole's own schema — one DELETE is enough.
    PGPASSWORD="$POSTGRES_PASSWORD" docker compose -f "$SCRIPT_DIR/docker-compose.yml" --env-file "$ENV_FILE" \
        exec -T postgres psql -v ON_ERROR_STOP=1 -U guacamole_user -d guacamole_db \
        -v name="$NAME" << 'SQL'
DELETE FROM guacamole_connection WHERE connection_name = :'name';
SQL
else
    print_warn "$ENV_FILE not found — skipping the Guacamole connection, VPS account already removed"
fi

registry_remove "$NAME"
print_info "Done. '$NAME' removed. Disable its tunnel on the client: sudo systemctl disable --now vps-rdp-tunnel"
