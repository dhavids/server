#!/bin/bash
# Bring the shared cloudflared tunnel up: authorize once, create the tunnel
# once, merge whatever target ingress fragments exist, then start the
# native systemd service (or restart it if the merged config changed).
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
