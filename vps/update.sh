#!/bin/bash
# Run on the VPS (as tunnel), typically invoked remotely by the Pi over
# its plain SSH key — the Pi already knows its own Tailscale IP and guac's
# port, so it fills these flags itself rather than the VPS trying to
# resolve a peer by name:
#   ssh tunnel@<vps-tailscale-ip> \
#     "bash ~/server/vps/update.sh -s guac-test --guac-ip $(tailscale ip -4)"
#
# Writes guac's cloudflared ingress fragment on the VPS (guac runs on a
# different box, so it can't write this fragment itself the way derp
# does), routes DNS for the subdomain, then reconfigures the shared
# tunnel. No cert dance needed — unlike derp, guac rides cloudflared's own
# TLS termination, so the route can go straight to the tunnel.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVER_ROOT="$(dirname "$SCRIPT_DIR")"
readonly GUAC_DIR="$SERVER_ROOT/guac"
readonly CF_ENV_FILE="$SERVER_ROOT/cloudflared/.env"
source "$SERVER_ROOT/utils/sh/print.sh"
source "$SERVER_ROOT/utils/sh/guard.sh"

DOMAIN=""
SUBDOMAIN="guac-test"
GUAC_HOST=""
GUAC_IP=""
GUAC_PORT="8080"


# Usage

usage() {
    cat << 'USAGE'
Usage: sudo bash update.sh --guac-ip IP [options]

Required:
  --guac-ip IP            The guac-host's current Tailscale IP (tailscale ip -4)

Optional:
  -d, --domain DOMAIN     Base domain (derives SUBDOMAIN.DOMAIN). Defaults
                          to whatever derp/.env has cached, if not given.
  -s, --subdomain NAME    Subdomain prefix (default: guac-test, for testing
                          before the real guac subdomain is wired up)
  --guac-host HOST        Override the derived SUBDOMAIN.DOMAIN entirely
  --guac-port PORT        Port guac's webapp listens on (default: 8080)
  -h, --help              Show this help and exit
USAGE
}


# Flag parsing

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--domain) DOMAIN="$2"; shift 2 ;;
        -s|--subdomain) SUBDOMAIN="$2"; shift 2 ;;
        --guac-host) GUAC_HOST="$2"; shift 2 ;;
        --guac-ip) GUAC_IP="$2"; shift 2 ;;
        --guac-port) GUAC_PORT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) print_error "Unknown flag: $1"; usage; exit 1 ;;
    esac
done

require_root || { usage; exit 1; }
require_user tunnel || exit 1
require_hardened || exit 1

if [ -z "$GUAC_IP" ]; then
    print_error "--guac-ip is required"
    usage
    exit 1
fi

if [ -z "$DOMAIN" ] && [ -f "$SERVER_ROOT/derp/.env" ]; then
    DOMAIN="$(grep '^DOMAIN=' "$SERVER_ROOT/derp/.env" | cut -d= -f2- | tr -d '"')"
    [ -n "$DOMAIN" ] && print_info "Using cached DOMAIN=$DOMAIN from derp/.env"
fi

if [ -z "$GUAC_HOST" ]; then
    if [ -z "$DOMAIN" ]; then
        print_error "--domain (or --guac-host) is required (nothing cached at derp/.env)"
        exit 1
    fi
    GUAC_HOST="${SUBDOMAIN}.${DOMAIN}"
fi

if [ ! -f "$CF_ENV_FILE" ]; then
    print_error "No $CF_ENV_FILE yet — run derp/setup.sh --prepare first (brings up the shared tunnel)"
    exit 1
fi
CF_TUNNEL_NAME="$(grep '^CF_TUNNEL_NAME=' "$CF_ENV_FILE" | cut -d= -f2- | tr -d '"')"


# Run

mkdir -p "$GUAC_DIR"
# Named per subdomain, not a single fixed file — lets more than one guac-host
# (e.g. guac-test on one box, guac on another) be routed at the same time.
FRAGMENT_FILE="$GUAC_DIR/cloudflared.ingress.$SUBDOMAIN.yml"
cat > "$FRAGMENT_FILE" << FRAGMENT
  - hostname: $GUAC_HOST
    service: http://$GUAC_IP:$GUAC_PORT
FRAGMENT
print_info "Wrote $FRAGMENT_FILE ($GUAC_HOST -> $GUAC_IP:$GUAC_PORT)"

print_info "Routing DNS for $GUAC_HOST to tunnel '$CF_TUNNEL_NAME'"
cloudflared tunnel route dns --overwrite-dns "$CF_TUNNEL_NAME" "$GUAC_HOST"

bash "$SERVER_ROOT/cloudflared/reconfigure.sh"

print_info "Done. guac should be reachable at https://$GUAC_HOST once DNS propagates."
