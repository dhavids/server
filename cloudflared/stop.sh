#!/bin/bash
# Stop the shared cloudflared tunnel. Does not touch the tunnel's identity
# (login/credentials) or the merged config — just stops the container.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

print_info "Stopping cloudflared"
docker compose -f "$SCRIPT_DIR/docker-compose.yml" stop cloudflared
