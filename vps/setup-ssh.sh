#!/bin/bash
# Run first, as root: creates the tunnel user and hardens SSH. Once done,
# SSH in as that user (now with full sudo) and run setup.sh for everything
# else — no need to stay in this root session.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVER_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SERVER_ROOT/utils/sh/print.sh"
source "$SERVER_ROOT/utils/sh/guard.sh"

readonly ALL_STEPS="create-user harden"

TUNNEL_USER="tunnel"
PUBKEY=""
GITHUB_USER=""
KEY_ID=""
EMAIL=""
ONLY=""
SKIP=""
START=""


# Usage

usage() {
    cat << 'USAGE'
Usage: sudo bash setup-ssh.sh [options]

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
  -e, --email VALUE       Fallback id for -g if -i isn't given
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
  create-user  Create --tunnel-user, full sudo, authorize --pubkey if given
  harden       Call utils/sh/harden.sh --user <tunnel-user>

After this, SSH in as --tunnel-user and run setup.sh for tailscale-up and
derp-setup — no need to keep this root session open.
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
        print_warn "No --pubkey given. $ssh_dir/authorized_keys is empty."
    fi

    chmod 700 "$ssh_dir"
    chmod 600 "$ssh_dir/authorized_keys"
    chown -R "$TUNNEL_USER:$TUNNEL_USER" "$ssh_dir"

    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$TUNNEL_USER@localhost" "echo ok" &> /dev/null; then
        print_info "Key login for $TUNNEL_USER confirmed working"
    elif should_run "harden"; then
        print_error "Key login for $TUNNEL_USER not confirmed. harden runs next and disables password login."
        print_error "Authorize a working key first, or run with --only create-user."
        exit 1
    else
        print_warn "Key login for $TUNNEL_USER not confirmed. harden is not running this time."
    fi
}

step_harden() {
    bash "$SERVER_ROOT/utils/sh/harden.sh" --user "$TUNNEL_USER"
}


# Flag parsing

while [ $# -gt 0 ]; do
    case "$1" in
        -u|--tunnel-user) TUNNEL_USER="$2"; shift 2 ;;
        -k|--pubkey) PUBKEY="$2"; shift 2 ;;
        -g|--github-user) GITHUB_USER="$2"; shift 2 ;;
        -i|--key-id) KEY_ID="$2"; shift 2 ;;
        -e|--email) EMAIL="$2"; shift 2 ;;
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

should_run "create-user"   && step_create_user
should_run "harden"        && step_harden

if should_run "harden" && [ ! -f "$HARDENED_MARKER" ]; then
    print_warn "Not hardened. Password login is still enabled."
else
    print_info "Done. SSH in as $TUNNEL_USER and run setup.sh next."
fi
