#!/bin/bash
# Run after setup-ssh.sh, as the tunnel user it created (full sudo): joins
# the tailnet, then hands off to derp/setup.sh (already portable — nothing
# in it is VPS-specific). No Docker is installed or needed on this box.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVER_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SERVER_ROOT/utils/sh/print.sh"
source "$SERVER_ROOT/utils/sh/guard.sh"

readonly ALL_STEPS="tailscale-up derp-setup"

DOMAIN=""
EMAIL=""
SUBDOMAIN=""
TUNNEL_PREFIX=""
ONLY=""
SKIP=""
START=""


# Usage

usage() {
    cat << 'USAGE'
Usage: sudo bash setup.sh [options]

Run setup-ssh.sh first, as root, then SSH in as the tunnel user it created
and run this.

Optional:
  -d, --domain DOMAIN   Passed through to derp/setup.sh --prepare
  -e, --email EMAIL     Passed through to derp/setup.sh --prepare
  -s, --subdomain NAME  Passed through to derp/setup.sh --prepare
  -t, --tunnel-prefix NAME  Passed through to derp/setup.sh --prepare
  --only STEPS          Run only these comma-separated steps
  --skip STEPS          Run all steps except these comma-separated ones
  --start STEP          Resume from this step onward (skip everything before it)
  --list-steps          Print available steps and exit
  -h, --help            Show this help and exit
USAGE
}

list_steps() {
    cat << 'STEPS'
Steps (run in this order by default):
  tailscale-up  Install Tailscale, join the tailnet (tailscale up)
  derp-setup    Call derp/setup.sh --prepare with --domain/--email/--subdomain

derp/setup.sh's own --activate phase is NOT run here — it needs DNS/port-80
actually working, run it separately once those are confirmed in place.
STEPS
}


# Step dispatch

should_run() {
    local step="$1"
    if [ -n "$ONLY" ]; then
        case ",$ONLY," in *",$step,"*) return 0 ;; *) return 1 ;; esac
    fi
    if [ -n "$START" ]; then
        if [ "$step" = "$START" ]; then STARTED="1"; fi
        [ "${STARTED:-}" = "1" ] && return 0 || return 1
    fi
    if [ -n "$SKIP" ]; then
        case ",$SKIP," in *",$step,"*) return 1 ;; *) return 0 ;; esac
    fi
    return 0
}


# Steps

step_tailscale_up() {
    bash "$SERVER_ROOT/utils/sh/install-req.sh" tailscale
    if tailscale ip -4 &> /dev/null; then
        print_info "Already joined a tailnet ($(tailscale ip -4))"
        return
    fi
    print_info "Running 'tailscale up' — this opens a URL to authorize in a browser"
    tailscale up
}

step_derp_setup() {
    local args=(--prepare)
    [ -n "$DOMAIN" ] && args+=(--domain "$DOMAIN")
    [ -n "$EMAIL" ] && args+=(--email "$EMAIL")
    [ -n "$SUBDOMAIN" ] && args+=(--subdomain "$SUBDOMAIN")
    [ -n "$TUNNEL_PREFIX" ] && args+=(--tunnel-prefix "$TUNNEL_PREFIX")
    bash "$SERVER_ROOT/derp/setup.sh" "${args[@]}"
}


# Flag parsing

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--domain) DOMAIN="$2"; shift 2 ;;
        -e|--email) EMAIL="$2"; shift 2 ;;
        -s|--subdomain) SUBDOMAIN="$2"; shift 2 ;;
        -t|--tunnel-prefix) TUNNEL_PREFIX="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --skip) SKIP="$2"; shift 2 ;;
        --start) START="$2"; shift 2 ;;
        --list-steps) list_steps; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) print_error "Unknown flag: $1"; usage; exit 1 ;;
    esac
done

require_root || { usage; exit 1; }
require_user tunnel || exit 1
require_hardened || exit 1


# Run

should_run "tailscale-up"   && step_tailscale_up
should_run "derp-setup"     && step_derp_setup

print_info "Done"
