#!/bin/bash
# Re-merge target ingress fragments and restart cloudflared if the result
# changed. Unlike start.sh, never touches login/tunnel-create — use this
# after adding or changing a target's ingress fragment, not for first setup.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

tunnel_id="$(get_tunnel_id)"
if [ -z "$tunnel_id" ]; then
    print_error "Tunnel '$CF_TUNNEL_NAME' does not exist yet — run start.sh first"
    exit 1
fi
get_credentials_file "$tunnel_id" > /dev/null

if merge_config "$tunnel_id"; then
    print_info "Config changed, restarting cloudflared"
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" restart cloudflared
else
    print_info "Config unchanged — nothing to do"
fi
