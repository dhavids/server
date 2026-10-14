#!/bin/bash
# Tears down the bare-metal derper validation setup from setup.sh, once
# server/derp/docker-compose.yml replaces it. Cert material and the Let's
# Encrypt account are deliberately left untouched — bind-mount them into
# the container instead of reissuing a fresh cert.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVER_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SERVER_ROOT/utils/sh/print.sh"

readonly ALL_STEPS="stop-service remove-binary remove-toolchain fix-renewal-hook"

ONLY=""
SKIP=""
START=""
ASSUME_YES="0"


# Usage

usage() {
    cat << 'USAGE'
Usage: sudo bash teardown.sh [options]

Optional:
  -y, --yes       Don't prompt before removing anything
  --only STEPS    Run only these comma-separated steps
  --skip STEPS    Run all steps except these comma-separated ones
  --start STEP    Resume from this step onward (skip everything before it)
  --list-steps    Print available steps and exit
  -h, --help      Show this help and exit
USAGE
}

list_steps() {
    cat << 'STEPS'
Steps (run in this order by default):
  stop-service       Disable + remove derper's systemd service
  remove-binary      Remove /usr/local/bin/derper
  remove-toolchain   Remove golang-go and its build cache (only needed to build derper)
  fix-renewal-hook   Point the cert renewal hook at the container instead of systemd

Cert material (/var/lib/derper/certs, /etc/letsencrypt) is never touched.
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

confirm() {
    local prompt="$1"
    [ "$ASSUME_YES" = "1" ] && return 0
    local reply
    read -rp "$prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}


# Steps

step_stop_service() {
    if ! systemctl list-unit-files 2>/dev/null | grep -q '^derper\.service'; then
        print_info "No derper.service found, nothing to do"
        return
    fi
    confirm "Stop and remove the derper systemd service?" || { print_warn "Skipped stop-service"; return; }
    systemctl disable --now derper || true
    rm -f /etc/systemd/system/derper.service
    systemctl daemon-reload
    print_info "Removed derper.service"
}

step_remove_binary() {
    if [ ! -f /usr/local/bin/derper ]; then
        print_info "/usr/local/bin/derper not present, nothing to do"
        return
    fi
    confirm "Remove /usr/local/bin/derper?" || { print_warn "Skipped remove-binary"; return; }
    rm -f /usr/local/bin/derper
    print_info "Removed /usr/local/bin/derper"
}

step_remove_toolchain() {
    confirm "Remove golang-go and its build cache (/root/go) — only needed to build derper, not run it?" \
        || { print_warn "Skipped remove-toolchain"; return; }
    apt-get remove -y golang-go || true
    rm -rf /root/go
    print_info "Removed Go toolchain and build cache"
}

step_fix_renewal_hook() {
    local hook="/etc/letsencrypt/renewal-hooks/deploy/derper-reload.sh"
    if [ ! -f "$hook" ]; then
        print_info "No renewal hook found, nothing to do"
        return
    fi
    sed -i "s|systemctl restart derper|docker compose -f $SERVER_ROOT/derp/docker-compose.yml restart derp|" "$hook"
    print_info "Updated $hook to restart the container instead of systemd"
}


# Flag parsing

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES="1"; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        --skip) SKIP="$2"; shift 2 ;;
        --start) START="$2"; shift 2 ;;
        --list-steps) list_steps; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) print_error "Unknown flag: $1"; usage; exit 1 ;;
    esac
done


# Run

should_run "stop-service"       && step_stop_service
should_run "remove-binary"      && step_remove_binary
should_run "remove-toolchain"   && step_remove_toolchain
should_run "fix-renewal-hook"   && step_fix_renewal_hook

print_info "Done — cert material under /var/lib/derper/certs and /etc/letsencrypt was left untouched, reuse it in the container"
