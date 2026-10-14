#!/bin/bash
# Orchestrates what's specific to the VPS box: create the tunnel user,
# harden the box, join the tailnet, then hand off to derp/setup.sh (already
# portable — nothing in it is VPS-specific). See --list-steps for the exact
# breakdown. No Docker is installed or needed on this box.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVER_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SERVER_ROOT/utils/sh/print.sh"
source "$SERVER_ROOT/utils/sh/guard.sh"

readonly ALL_STEPS="create-user harden tailscale-up derp-setup"

TUNNEL_USER="tunnel"
PUBKEY=""
GITHUB_USER=""
KEY_ID=""
DOMAIN=""
EMAIL=""
SUBDOMAIN=""
ONLY=""
SKIP=""
START=""


# Usage

usage() {
    cat << 'USAGE'
Usage: sudo bash setup.sh [options]

Optional:
  -u, --tunnel-user NAME  Account to create with full sudo (default: tunnel)
  -k, --pubkey VALUE      A public key's file path, or its literal content,
                          to authorize for -u. Without this, add a key to
                          its authorized_keys manually before continuing —
                          harden.sh's ssh-harden step disables password login.
  -g, --github-user NAME  Fetch candidate keys from github.com/NAME.keys
                          instead of -k. GitHub strips comments from this
                          endpoint, so if NAME has more than one key, -i
                          (or -e as a fallback) must match the END of exactly
                          one key's raw data to pick it — ambiguous or no
                          matches refuse rather than guess.
  -i, --key-id ID         At least 3 characters, matched against the
                          trailing characters of each -g key. Falls back
                          to -e if not given.
  -d, --domain DOMAIN     Passed through to derp/setup.sh --prepare
  -e, --email EMAIL       Passed through to derp/setup.sh --prepare
  -s, --subdomain NAME    Passed through to derp/setup.sh --prepare
  --only STEPS            Run only these comma-separated steps
  --skip STEPS            Run all steps except these comma-separated ones
  --start STEP            Resume from this step onward (skip everything before it)
  --list-steps            Print available steps and exit
  -h, --help              Show this help and exit
USAGE
}

list_steps() {
    cat << 'STEPS'
Steps (run in this order by default):
  create-user   Create --tunnel-user, full sudo, authorize --pubkey if given
  harden        Call harden.sh --user <tunnel-user>
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


# Pubkey resolution

# Fetches github.com/$GITHUB_USER.keys and sets PUBKEY to the one entry
# whose raw key data ends with the chosen id (--key-id, else --email) —
# refuses rather than guess if zero or more than one key matches.
resolve_github_pubkey() {
    local id="$KEY_ID"
    [ -z "$id" ] && id="$EMAIL"
    if [ -z "$id" ]; then
        print_error "--github-user needs --key-id (or --email) to pick among its keys"
        exit 1
    fi
    if [ "${#id}" -lt 3 ]; then
        print_error "--key-id (or --email) must be at least 3 characters"
        exit 1
    fi

    local keys
    keys="$(curl -fsSL "https://github.com/${GITHUB_USER}.keys")"
    if [ -z "$keys" ]; then
        print_error "No keys found at github.com/${GITHUB_USER}.keys"
        exit 1
    fi

    local line key_data matches=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        key_data="$(awk '{print $2}' <<< "$line")"
        if [[ "$key_data" == *"$id" ]]; then
            matches="${matches}${line}"$'\n'
        fi
    done <<< "$keys"
    matches="${matches%$'\n'}"

    local match_count=0
    [ -n "$matches" ] && match_count="$(wc -l <<< "$matches")"

    if [ "$match_count" -eq 0 ]; then
        print_error "No key at github.com/${GITHUB_USER}.keys ends with '$id'"
        exit 1
    fi
    if [ "$match_count" -gt 1 ]; then
        print_error "$match_count keys at github.com/${GITHUB_USER}.keys end with '$id' — give a longer --key-id"
        exit 1
    fi

    PUBKEY="$matches"
    print_info "Matched one key at github.com/${GITHUB_USER}.keys via '$id'"
}


# Steps

step_create_user() {
    if [ -z "$PUBKEY" ] && [ -n "$GITHUB_USER" ]; then
        resolve_github_pubkey
    fi

    if id "$TUNNEL_USER" &> /dev/null; then
        print_info "User $TUNNEL_USER already exists"
    else
        print_info "Creating user $TUNNEL_USER"
        useradd -m -s /bin/bash "$TUNNEL_USER"
    fi
    usermod -aG sudo "$TUNNEL_USER"

    local ssh_dir="/home/$TUNNEL_USER/.ssh"
    mkdir -p "$ssh_dir"
    touch "$ssh_dir/authorized_keys"

    if [ -n "$PUBKEY" ]; then
        local key_content
        if [ -f "$PUBKEY" ]; then
            key_content="$(cat "$PUBKEY")"
        else
            key_content="$PUBKEY"
        fi
        if ! grep -qxF "$key_content" "$ssh_dir/authorized_keys"; then
            echo "$key_content" >> "$ssh_dir/authorized_keys"
            print_info "Authorized key added for $TUNNEL_USER"
        fi
    else
        print_warn "No --pubkey given — add a key to $ssh_dir/authorized_keys manually before continuing"
    fi

    chmod 700 "$ssh_dir"
    chmod 600 "$ssh_dir/authorized_keys"
    chown -R "$TUNNEL_USER:$TUNNEL_USER" "$ssh_dir"

    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$TUNNEL_USER@localhost" "echo ok" &> /dev/null; then
        print_info "Key login for $TUNNEL_USER confirmed working"
    else
        print_warn "Couldn't confirm key login for $TUNNEL_USER — verify manually before the harden step, which disables password login"
    fi
}

step_harden() {
    bash "$SERVER_ROOT/harden.sh" --user "$TUNNEL_USER"
}

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
    bash "$SERVER_ROOT/derp/setup.sh" "${args[@]}"
}


# Flag parsing

while [ $# -gt 0 ]; do
    case "$1" in
        -u|--tunnel-user) TUNNEL_USER="$2"; shift 2 ;;
        -k|--pubkey) PUBKEY="$2"; shift 2 ;;
        -g|--github-user) GITHUB_USER="$2"; shift 2 ;;
        -i|--key-id) KEY_ID="$2"; shift 2 ;;
        -d|--domain) DOMAIN="$2"; shift 2 ;;
        -e|--email) EMAIL="$2"; shift 2 ;;
        -s|--subdomain) SUBDOMAIN="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --skip) SKIP="$2"; shift 2 ;;
        --start) START="$2"; shift 2 ;;
        --list-steps) list_steps; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) print_error "Unknown flag: $1"; usage; exit 1 ;;
    esac
done

require_root || { usage; exit 1; }


# Run

should_run "create-user"    && step_create_user
should_run "harden"         && step_harden
should_run "tailscale-up"   && step_tailscale_up
should_run "derp-setup"     && step_derp_setup

print_info "Done"
