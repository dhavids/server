#!/bin/bash
# Ensures each named requirement is installed, via server/utils/conf/<name>.conf.
# Each conf defines an ensure() function; this sources it in a subshell and
# calls it, so successive requirements' ensure() definitions never collide.
#
# Usage: sudo bash install-req.sh <name> [<name> ...]
#   e.g. sudo bash install-req.sh docker cloudflared
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVER_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
readonly CONF_DIR="$SERVER_ROOT/utils/conf"
source "$SCRIPT_DIR/print.sh"
source "$SCRIPT_DIR/guard.sh"


# Usage

usage() {
    cat << 'USAGE'
Usage: sudo bash install-req.sh <name> [<name> ...]

Each <name> must have server/utils/conf/<name>.conf defining an ensure()
function. Example: sudo bash install-req.sh docker cloudflared
USAGE
}


# Helpers

ensure_requirement() {
    local name="$1"
    local conf="$CONF_DIR/$name.conf"
    if [ ! -f "$conf" ]; then
        print_error "No $conf found"
        exit 1
    fi
    print_info "Checking requirement: $name"
    ( source "$conf"; ensure )
}


# Flag parsing

if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    exit 0
fi

require_root || { usage; exit 1; }


# Run

for name in "$@"; do
    ensure_requirement "$name"
done

print_info "Done — all requirements satisfied: $*"
