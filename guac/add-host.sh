#!/bin/bash
# Run on the guac-host (as guac), once per client: allocates it a unique
# forwarded port, provisions a restricted account for it on the VPS (over
# ssh, via vps/provision-host.sh), and adds its connection to Guacamole
# (--protocol must match what client.sh --print-key decided). The client
# itself still needs client.sh run on it, with the port this prints.
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
PUBKEY=""
PROTOCOL="vnc"
VNC_PASSWORD=""
VPS_HOST=""
VPS_ID=""
VPS_PUBLIC_HOST=""
FORCE=""


# Usage

usage() {
    cat << 'USAGE'
Usage: sudo bash add-host.sh --name NAME --pubkey KEY [options]

Required:
  --name NAME       Host label (letters, digits, dashes/underscores only) —
                     shown as the Guacamole connection name
  --pubkey KEY      The host's SSH public key — a file path, or its literal
                     content (print it with client.sh's --print-key)

Optional:
  --protocol vnc|rdp    Must match what client.sh --print-key decided
                         (default: vnc)
  --vnc-password PASS   Sets/updates this VNC host's Guacamole password
                         param (client.sh --print-key prints one to use
                         here; vnc only)
  --vps-host HOST       VPS's Tailscale IP/hostname — reached from here,
                         and the bind address the host's forwarded port
                         gets restricted to (so only the Pi can reach it)
  -i, --vps-id ID       VPS's <hostname-prefix>-<ip-suffix>, resolved via
                         'tailscale status' — alternative to --vps-host. If
                         neither is given, auto-resolves to the one tailnet
                         peer whose hostname contains "vps".
  --vps-public-host IP  VPS's public IP/hostname, for the host to use (it
                         has no Tailscale, so --vps-host isn't reachable
                         from it). Auto-detected via the VPS's own
                         'curl ifconfig.me' if not given.
  -f, --force           Re-provision NAME even if already in the registry
                         (rotates its key/re-runs VPS provisioning; does not
                         duplicate its Guacamole connection)
  -h, --help            Show this help and exit
USAGE
}

# Prints phase c's exact command, copy-pasteable as-is.
print_finalize_cmd() {
    cat << CMD
On the client, run:

bash guac/client.sh --vps-ssh-host $VPS_PUBLIC_HOST --vps-bind-host $VPS_HOST --vps-user host-$NAME --port $PORT
CMD
}

# Sets/replaces NAME's Guacamole 'password' param. Assumes ENV_FILE is sourced.
update_vnc_password() {
    print_info "Updating $NAME's VNC password in Guacamole"
    PGPASSWORD="$POSTGRES_PASSWORD" docker compose -f "$SCRIPT_DIR/docker-compose.yml" --env-file "$ENV_FILE" \
        exec -T postgres psql -v ON_ERROR_STOP=1 -U guacamole_user -d guacamole_db \
        -v name="$NAME" -v vncpass="$VNC_PASSWORD" << 'SQL'
DELETE FROM guacamole_connection_parameter
WHERE parameter_name = 'password'
  AND connection_id = (SELECT connection_id FROM guacamole_connection WHERE connection_name = :'name');
INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT connection_id, 'password', :'vncpass'
FROM guacamole_connection WHERE connection_name = :'name';
SQL
}


# Flag parsing

while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME="$2"; shift 2 ;;
        --pubkey) PUBKEY="$2"; shift 2 ;;
        --protocol) PROTOCOL="$2"; shift 2 ;;
        --vnc-password) VNC_PASSWORD="$2"; shift 2 ;;
        --vps-host) VPS_HOST="$2"; shift 2 ;;
        -i|--vps-id) VPS_ID="$2"; shift 2 ;;
        --vps-public-host) VPS_PUBLIC_HOST="$2"; shift 2 ;;
        -f|--force) FORCE="1"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) print_error "Unknown flag: $1"; usage; exit 1 ;;
    esac
done

require_root || { usage; exit 1; }
require_user guac || exit 1
require_hardened || exit 1

if [ -z "$NAME" ] || [ -z "$PUBKEY" ]; then
    print_error "--name and --pubkey are required"
    usage
    exit 1
fi
if [[ ! "$NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
    print_error "--name must be letters, digits, dashes/underscores only (got: $NAME)"
    exit 1
fi
if [ "$PROTOCOL" != "vnc" ] && [ "$PROTOCOL" != "rdp" ]; then
    print_error "--protocol must be vnc or rdp (got: $PROTOCOL)"
    exit 1
fi
if [ -n "$VNC_PASSWORD" ] && [ "$PROTOCOL" != "vnc" ]; then
    print_error "--vnc-password only applies to --protocol vnc"
    exit 1
fi
if [ -f "$PUBKEY" ]; then
    PUBKEY="$(cat "$PUBKEY")"
fi

# Password-only update on an already-registered host: no need for --force,
# and no need to touch the VPS at all.
if [ -n "$VNC_PASSWORD" ] && [ -z "$FORCE" ] && registry_port_for "$NAME" &> /dev/null; then
    if [ ! -f "$ENV_FILE" ]; then
        print_error "$ENV_FILE not found — run setup.sh --prepare first"
        exit 1
    fi
    source "$ENV_FILE"
    update_vnc_password
    print_info "Done. $NAME's password updated, nothing else touched."
    exit 0
fi

if [ -z "$VPS_HOST" ] && [ -n "$VPS_ID" ]; then
    VPS_HOST="$(resolve_tailscale_peer "$VPS_ID")" || exit 1
    print_info "Resolved --vps-id '$VPS_ID' to $VPS_HOST"
fi
if [ -z "$VPS_HOST" ]; then
    VPS_HOST="$(resolve_tailscale_peer vps)" || exit 1
    print_info "No --vps-host/--vps-id given — auto-resolved to the one tailnet peer matching 'vps': $VPS_HOST"
fi

EXISTING_PORT=""
EXISTING_PORT="$(registry_port_for "$NAME" || true)"
if [ -n "$EXISTING_PORT" ] && [ -z "$FORCE" ]; then
    print_error "'$NAME' is already in $REGISTRY_FILE on port $EXISTING_PORT. Pass --force to re-provision it."
    exit 1
fi

PORT="$EXISTING_PORT"
if [ -z "$PORT" ]; then
    PORT="$(next_free_port)"
    mkdir -p "$SCRIPT_DIR"
    echo "$NAME $PORT" >> "$REGISTRY_FILE"
    print_info "Assigned $NAME port $PORT (recorded in $REGISTRY_FILE)"
else
    print_info "Re-using $NAME's existing port $PORT"
fi


# Run

ensure_vps_ssh_access "$VPS_HOST" || exit 1

if [ -z "$VPS_PUBLIC_HOST" ]; then
    VPS_PUBLIC_HOST="$(ssh -i "$VPS_SSH_KEY" "tunnel@$VPS_HOST" "curl -4 -s ifconfig.me")"
    if [ -z "$VPS_PUBLIC_HOST" ]; then
        print_error "Couldn't detect the VPS's public IP — pass --vps-public-host"
        exit 1
    fi
fi

print_info "Provisioning $NAME on $VPS_HOST via ssh"
ssh -i "$VPS_SSH_KEY" "tunnel@$VPS_HOST" \
    "sudo bash ~/server/vps/provision-host.sh --name '$NAME' --port '$PORT' --pubkey '$PUBKEY'"

if [ ! -f "$ENV_FILE" ]; then
    print_error "$ENV_FILE not found — run setup.sh --prepare first"
    exit 1
fi
source "$ENV_FILE"

if [ -n "$EXISTING_PORT" ]; then
    [ -n "$VNC_PASSWORD" ] && update_vnc_password
    print_info "Done. $NAME's Guacamole connection already exists, not touching it."
    print_finalize_cmd
    exit 0
fi

print_info "Adding $NAME's $PROTOCOL connection to Guacamole"
if [ "$PROTOCOL" = "rdp" ]; then
    EXTRA_PARAMS="('security', 'any'), ('ignore-cert', 'true')"
elif [ -n "$VNC_PASSWORD" ]; then
    EXTRA_PARAMS="('password', :'vncpass')"
else
    EXTRA_PARAMS=""
fi
PGPASSWORD="$POSTGRES_PASSWORD" docker compose -f "$SCRIPT_DIR/docker-compose.yml" --env-file "$ENV_FILE" \
    exec -T postgres psql -v ON_ERROR_STOP=1 -U guacamole_user -d guacamole_db \
    -v name="$NAME" -v host="$VPS_HOST" -v port="$PORT" -v protocol="$PROTOCOL" -v vncpass="$VNC_PASSWORD" << SQL
WITH new_conn AS (
    INSERT INTO guacamole_connection (connection_name, protocol)
    VALUES (:'name', :'protocol')
    RETURNING connection_id
), params AS (
    INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
    SELECT connection_id, p.name, p.value
    FROM new_conn, (VALUES
        ('hostname', :'host'),
        ('port', :'port')$([ -n "$EXTRA_PARAMS" ] && echo ", $EXTRA_PARAMS")
    ) AS p(name, value)
)
INSERT INTO guacamole_connection_permission (entity_id, connection_id, permission)
SELECT e.entity_id, nc.connection_id, 'READ'
FROM new_conn nc, guacamole_entity e
WHERE e.name = 'guacadmin' AND e.type = 'USER';
SQL

print_info "Done. Guacamole connection '$NAME' -> $VPS_HOST:$PORT created."
print_finalize_cmd
