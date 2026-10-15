#!/bin/bash
# Run on the VPS (as tunnel), invoked remotely by guac/add-host.sh — from
# any guac-host. Prints every provisioned host's "NAME PORT", read straight
# off each host-NAME account's authorized_keys permitlisten. No separate
# registry file: this is the same state provision-host.sh already has to
# write for forwarding to work at all, so two guac-hosts always see the
# same picture, and there's nothing extra to keep in sync or back up.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVER_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SERVER_ROOT/utils/sh/print.sh"
source "$SERVER_ROOT/utils/sh/guard.sh"

require_root || { print_error "Use: sudo bash list-ports.sh"; exit 1; }
require_user tunnel || exit 1
require_hardened || exit 1

for keyfile in /home/host-*/.ssh/authorized_keys; do
    [ -f "$keyfile" ] || continue
    name="$(basename "$(dirname "$(dirname "$keyfile")")")"
    name="${name#host-}"
    port="$(grep -oP 'permitlisten="[^:]*:\K[0-9]+' "$keyfile" | head -1)"
    [ -n "$port" ] && echo "$name $port"
done
