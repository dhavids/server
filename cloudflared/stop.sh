#!/bin/bash
# Stop the shared cloudflared tunnel. Does not touch the tunnel's identity
# (login/credentials) or the merged config — just stops the service.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_root || exit 1

print_info "Stopping cloudflared"
systemctl stop cloudflared
