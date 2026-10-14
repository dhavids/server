#!/bin/bash
# Bring the shared cloudflared tunnel up: authorize once, create the tunnel
# once, merge whatever target ingress fragments exist, then start the
# container (or restart it if the merged config changed since last time).
#
# Safe to re-run — each step is skipped if already done.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_root || exit 1

ensure_cloudflared_cli
ensure_tunnel_login
ensure_tunnel_exists

tunnel_id="$(get_tunnel_id)"
if [ -z "$tunnel_id" ]; then
    print_error "Could not determine tunnel ID for '$CF_TUNNEL_NAME'"
    exit 1
fi
get_credentials_file "$tunnel_id" > /dev/null

changed="1"
merge_config "$tunnel_id" && changed="0"

if docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps --status running 2>/dev/null | grep -q cloudflared; then
    if [ "$changed" = "0" ]; then
        print_info "Config changed, restarting cloudflared"
        docker compose -f "$SCRIPT_DIR/docker-compose.yml" restart cloudflared
    else
        print_info "cloudflared already running, config unchanged — nothing to do"
    fi
else
    print_info "Starting cloudflared"
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d cloudflared
fi
