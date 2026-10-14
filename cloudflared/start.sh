#!/bin/bash
# Bring the shared cloudflared tunnel up: authorize once, create the tunnel
# once, merge whatever target ingress fragments exist, then start the
# native systemd service (or restart it if the merged config changed).
#
# Safe to re-run — each step is skipped if already done. -s/-t only take
# effect on the first run; once named, the tunnel keeps that name (see .env).
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
    cat << 'USAGE'
Usage: sudo bash start.sh [options]

Optional:
  -s, --subdomain NAME      Subdomain this tunnel is for (default: derp)
  -t, --tunnel-prefix NAME  Tunnel name prefix (default: vps) — e.g.
                            -t my-vps becomes my-vps-tunnel
  -h, --help                Show this help and exit
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        -s|--subdomain) SUBDOMAIN="$2"; shift 2 ;;
        -t|--tunnel-prefix) TUNNEL_PREFIX="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) print_error "Unknown flag: $1"; usage; exit 1 ;;
    esac
done

require_root || exit 1

if [ ! -f "$SCRIPT_DIR/.env" ]; then
    CF_TUNNEL_NAME="$(tunnel_name_for "$TUNNEL_PREFIX" "$SUBDOMAIN")"
    echo "CF_TUNNEL_NAME=\"$CF_TUNNEL_NAME\"" > "$SCRIPT_DIR/.env"
    print_info "Tunnel name set to '$CF_TUNNEL_NAME' (persisted to $SCRIPT_DIR/.env)"
fi

ensure_cloudflared_cli
ensure_tunnel_login
ensure_tunnel_exists

tunnel_id="$(get_tunnel_id)"
if [ -z "$tunnel_id" ]; then
    print_error "Could not determine tunnel ID for '$CF_TUNNEL_NAME'"
    exit 1
fi
cred_file="$(get_credentials_file "$tunnel_id")"

changed="1"
merge_config "$tunnel_id" "$cred_file" && changed="0"

ensure_cloudflared_service

if cloudflared_is_active; then
    if [ "$changed" = "0" ]; then
        print_info "Config changed, restarting cloudflared"
        systemctl restart cloudflared
    else
        print_info "cloudflared already running, config unchanged — nothing to do"
    fi
else
    print_info "Starting cloudflared"
    systemctl enable --now cloudflared
fi
