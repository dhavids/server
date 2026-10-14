#!/bin/bash
# Shared functions for start.sh / stop.sh / reconfigure.sh. Not run directly.
# Runs cloudflared natively (systemd via its own 'cloudflared service
# install'), not in a container — this tunnel lives on the VPS, which has
# no Docker at all.

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVER_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SERVER_ROOT/utils/sh/print.sh"
source "$SERVER_ROOT/utils/sh/guard.sh"

readonly CONFIG_OUT="/etc/cloudflared/config.yml"
readonly TARGET_DIRS="derp guac webserver"
readonly FRAGMENT_NAME="cloudflared.ingress.yml"

# "derp" (the default subdomain) gets the bare prefix name; any other
# subdomain gets it as a suffix, so e.g. -s guac doesn't collide with derp's.
tunnel_name_for() {
    local prefix="$1" subdomain="$2"
    if [ "$subdomain" = "derp" ]; then
        echo "${prefix}-tunnel"
    else
        echo "${prefix}-tunnel-${subdomain}"
    fi
}

TUNNEL_PREFIX="${TUNNEL_PREFIX:-vps}"
SUBDOMAIN="${SUBDOMAIN:-derp}"
CF_TUNNEL_NAME="$(tunnel_name_for "$TUNNEL_PREFIX" "$SUBDOMAIN")"
[ -f "$SCRIPT_DIR/.env" ] && source "$SCRIPT_DIR/.env"


# Tunnel identity (one-time steps, skipped if already done)

ensure_cloudflared_cli() {
    bash "$SERVER_ROOT/utils/sh/install-req.sh" cloudflared
}

ensure_tunnel_login() {
    if [ -f "$HOME/.cloudflared/cert.pem" ]; then
        print_info "cloudflared already authorized (cert.pem present), skipping login"
        return
    fi
    print_info "Running 'cloudflared tunnel login' — this opens a URL to authorize in a browser"
    cloudflared tunnel login
}

ensure_tunnel_exists() {
    if cloudflared tunnel list 2>/dev/null | awk -v n="$CF_TUNNEL_NAME" '$2==n {found=1} END {exit !found}'; then
        print_info "Tunnel '$CF_TUNNEL_NAME' already exists, reusing it"
    else
        print_info "Creating tunnel '$CF_TUNNEL_NAME'"
        cloudflared tunnel create "$CF_TUNNEL_NAME"
    fi
}

get_tunnel_id() {
    cloudflared tunnel list | awk -v n="$CF_TUNNEL_NAME" '$2==n {print $1}'
}

get_credentials_file() {
    local tunnel_id="$1"
    local cred_file="$HOME/.cloudflared/${tunnel_id}.json"
    if [ ! -f "$cred_file" ]; then
        local alt
        alt="$(find / -maxdepth 4 -name "${tunnel_id}.json" 2>/dev/null | head -1)"
        if [ -n "$alt" ] && [ "$alt" != "$cred_file" ]; then
            mkdir -p "$HOME/.cloudflared"
            cp "$alt" "$cred_file"
            print_info "Copied tunnel credentials from $alt to $cred_file"
        fi
    fi
    echo "$cred_file"
}


# Config assembly

# Writes the merged config to $CONFIG_OUT.new; returns 0 if it differs from
# the config currently in place (or none exists yet), 1 if unchanged.
merge_config() {
    local tunnel_id="$1"
    local cred_file="$2"
    local found_any="0"
    local new_config="$CONFIG_OUT.new"

    mkdir -p /etc/cloudflared
    {
        cat << HEADER
tunnel: $tunnel_id
credentials-file: $cred_file

ingress:
HEADER
        for target in $TARGET_DIRS; do
            local fragment="$SERVER_ROOT/$target/$FRAGMENT_NAME"
            if [ -f "$fragment" ]; then
                print_hint "Including ingress fragment: $fragment"
                cat "$fragment"
                found_any="1"
            fi
        done
        printf '%s\n' "  - service: http_status:404"
    } > "$new_config"

    if [ "$found_any" = "0" ]; then
        print_warn "No target ingress fragments found under $SERVER_ROOT/*/$FRAGMENT_NAME"
    fi

    if [ -f "$CONFIG_OUT" ] && diff -q "$CONFIG_OUT" "$new_config" > /dev/null 2>&1; then
        rm -f "$new_config"
        return 1
    fi
    mv "$new_config" "$CONFIG_OUT"
    return 0
}


# Native systemd service

ensure_cloudflared_service() {
    # Checks the file on disk, not systemd's cache, which a prior
    # interrupted run can leave stale.
    if [ -f /etc/systemd/system/cloudflared.service ]; then
        systemctl daemon-reload
        return
    fi
    print_info "Installing cloudflared as a systemd service"
    cloudflared service install
    systemctl daemon-reload
}

cloudflared_is_active() {
    systemctl is-active --quiet cloudflared
}
