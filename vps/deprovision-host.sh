#!/bin/bash
# Run on the VPS (as tunnel), invoked remotely by guac/remove-host.sh on
# the guac-host. Removes one client's restricted account. The one-time
# rdp-tunnel group/Match block is left in place — other clients still use
# it.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVER_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SERVER_ROOT/utils/sh/print.sh"
source "$SERVER_ROOT/utils/sh/guard.sh"

NAME=""


# Usage

usage() {
    cat << 'USAGE'
Usage: sudo bash deprovision-host.sh --name NAME

Required:
  --name NAME     Host label — the system account host-NAME is removed

Optional:
  -h, --help      Show this help and exit
USAGE
}


# Flag parsing

while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) print_error "Unknown flag: $1"; usage; exit 1 ;;
    esac
done

require_root || { usage; exit 1; }
require_user tunnel || exit 1
require_hardened || exit 1

if [ -z "$NAME" ]; then
    print_error "--name is required"
    usage
    exit 1
fi


# Run

readonly USER_NAME="host-$NAME"

if ! id "$USER_NAME" &> /dev/null; then
    print_info "User $USER_NAME doesn't exist, nothing to do"
    exit 0
fi

userdel -r "$USER_NAME" 2> /dev/null || userdel "$USER_NAME"
print_info "Removed $USER_NAME"
