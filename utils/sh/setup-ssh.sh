#!/bin/bash
# Run first, as root: creates --user and hardens SSH. Once done, SSH in as
# that user (now with full sudo) and run --next for everything else — no
# need to stay in this root session. Shared by vps/ and guac/'s own
# setup-ssh.sh wrappers, which just supply --user/--next.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVER_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# copy-repo rm -rf's SERVER_ROOT's parent — if the invoking shell (or any
# child process this spawns) is cd'd inside it, getcwd() breaks afterward.
cd /

source "$SERVER_ROOT/utils/sh/print.sh"
source "$SERVER_ROOT/utils/sh/guard.sh"
source "$SERVER_ROOT/utils/sh/github_keys.sh"

readonly ALL_STEPS="create-user copy-repo harden"

ADMIN_USER=""
NEXT_SCRIPT="setup.sh"
PUBKEY=""
GITHUB_USER=""
KEY_ID=""
EMAIL=""
ONLY=""
SKIP=""
START=""
FORCE=""


# Usage

usage() {
    cat << 'USAGE'
Usage: sudo bash setup-ssh.sh --user NAME [options]

Required:
  -u, --user NAME         Account to create with full sudo

Optional:
  --next PATH             Script to point to in the final message
                          (default: setup.sh)
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
  -f, --force             Redo setup even if run as --user (normally
                          refused — this re-ran this account already)
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
  create-user  Create --user, full sudo, authorize --pubkey if given
  copy-repo    Overwrite ~<user>/server with this repo, so git pull
               works there without re-cloning
  harden       Call utils/sh/harden.sh --user <user>

After this, SSH in as --user and run --next — no need to keep this root
session open.
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

# Sets PUBKEY from github.com/$GITHUB_USER.keys via select_github_key.
resolve_github_pubkey() {
    local id="$KEY_ID"
    [ -z "$id" ] && id="$EMAIL"
    if [ -z "$id" ]; then
        print_error "--github-user needs --key-id (or --email) to pick among its keys"
        exit 1
    fi

    command -v curl &> /dev/null || { apt-get update; apt-get install -y curl; }

    PUBKEY="$(select_github_key "$GITHUB_USER" "$id")" || exit 1
    print_info "Matched one key at github.com/${GITHUB_USER}.keys via '$id'"
}


# Steps

step_create_user() {
    if [ -z "$PUBKEY" ] && [ -n "$GITHUB_USER" ]; then
        resolve_github_pubkey
    fi

    if id "$ADMIN_USER" &> /dev/null; then
        print_info "User $ADMIN_USER already exists"
    else
        print_info "Creating user $ADMIN_USER"
        useradd -m -s /bin/bash "$ADMIN_USER"
    fi
    usermod -aG sudo "$ADMIN_USER"

    # No password is ever set for $ADMIN_USER (key-only account), so sudo
    # needs NOPASSWD or it has nothing to prompt for.
    local sudoers_tmp
    sudoers_tmp="$(mktemp)"
    echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" > "$sudoers_tmp"
    if visudo -cf "$sudoers_tmp" &> /dev/null; then
        install -m 0440 -o root -g root "$sudoers_tmp" "/etc/sudoers.d/$ADMIN_USER"
        print_info "Passwordless sudo configured for $ADMIN_USER"
    else
        print_error "Generated sudoers drop-in failed validation, not installed"
        rm -f "$sudoers_tmp"
        exit 1
    fi
    rm -f "$sudoers_tmp"

    local ssh_dir="/home/$ADMIN_USER/.ssh"
    mkdir -p "$ssh_dir"
    touch "$ssh_dir/authorized_keys"

    local key_content=""
    if [ -n "$PUBKEY" ]; then
        if [ -f "$PUBKEY" ]; then
            key_content="$(cat "$PUBKEY")"
        else
            key_content="$PUBKEY"
        fi
        if ! grep -qxF "$key_content" "$ssh_dir/authorized_keys"; then
            echo "$key_content" >> "$ssh_dir/authorized_keys"
            print_info "Authorized key added for $ADMIN_USER"
        fi
    else
        print_warn "No --pubkey given. $ssh_dir/authorized_keys is empty."
    fi

    chmod 700 "$ssh_dir"
    chmod 600 "$ssh_dir/authorized_keys"
    chown -R "$ADMIN_USER:$ADMIN_USER" "$ssh_dir"

    # Confirms the key is in authorized_keys — can't test login, this host
    # rarely holds the private key.
    if [ -n "$key_content" ] && grep -qxF "$key_content" "$ssh_dir/authorized_keys"; then
        print_info "Key authorized for $ADMIN_USER in $ssh_dir/authorized_keys"
    elif should_run "harden"; then
        print_error "No key authorized for $ADMIN_USER. harden runs next and disables password login."
        print_error "Authorize a working key first, or run with --only create-user."
        exit 1
    else
        print_warn "No key authorized for $ADMIN_USER. harden is not running this time."
    fi
}

step_copy_repo() {
    local dest="/home/$ADMIN_USER/server"
    local staging
    staging="$(mktemp -d)"
    cp -a "$SERVER_ROOT/." "$staging/"
    rm -rf "$dest"
    mv "$staging" "$dest"
    chown -R "$ADMIN_USER:$ADMIN_USER" "$dest"
    print_info "Repo copied to $dest"
}

step_harden() {
    bash "$SERVER_ROOT/utils/sh/harden.sh" --user "$ADMIN_USER"
}


# Flag parsing

while [ $# -gt 0 ]; do
    case "$1" in
        -u|--user) ADMIN_USER="$2"; shift 2 ;;
        --next) NEXT_SCRIPT="$2"; shift 2 ;;
        -k|--pubkey) PUBKEY="$2"; shift 2 ;;
        -g|--github-user) GITHUB_USER="$2"; shift 2 ;;
        -i|--key-id) KEY_ID="$2"; shift 2 ;;
        -e|--email) EMAIL="$2"; shift 2 ;;
        -f|--force) FORCE="1"; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        --skip) SKIP="$2"; shift 2 ;;
        --start) START="$2"; shift 2 ;;
        --list-steps) list_steps; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) print_error "Unknown flag: $1"; usage; exit 1 ;;
    esac
done

require_root || { usage; exit 1; }

if [ -z "$ADMIN_USER" ]; then
    print_error "--user is required"
    usage
    exit 1
fi

# Already hardened means setup-ssh already ran to completion. Refuse
# unless --force, regardless of which user/session is re-running it.
if [ -f "$HARDENED_MARKER" ] && [ -z "$FORCE" ]; then
    print_info "setup-ssh.sh already run for $ADMIN_USER. SSH in and run ~/server/$NEXT_SCRIPT."
    print_info "Pass --force to redo it."
    exit 0
fi


# Run

should_run "create-user"   && step_create_user
should_run "copy-repo"     && step_copy_repo
should_run "harden"        && step_harden

if should_run "harden" && [ ! -f "$HARDENED_MARKER" ]; then
    print_warn "Not hardened. Password login is still enabled."
else
    print_info "Done. SSH in as $ADMIN_USER and run ~/server/$NEXT_SCRIPT next."
fi
