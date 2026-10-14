#!/bin/bash
# Installs Docker + the Compose plugin on the Pi, following Docker's own apt
# repository setup for Ubuntu. Run once, before any target's compose comes
# up. See --help and --list-steps for the full breakdown.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/sh/print.sh"

readonly ALL_STEPS="prereqs add-repo install enable add-user verify"
readonly KEYRING="/etc/apt/keyrings/docker.asc"

ADMIN_USER="${SUDO_USER:-}"
ONLY=""
SKIP=""
START=""


# Usage

usage() {
    cat << 'USAGE'
Usage: sudo bash install-docker.sh [options]

Optional:
  --user NAME   Account to add to the docker group (default: whoever ran sudo)
  --only STEPS  Run only these comma-separated steps
  --skip STEPS  Run all steps except these comma-separated ones
  --start STEP  Resume from this step onward (skip everything before it)
  --list-steps  Print available steps and exit
  -h, --help    Show this help and exit
USAGE
}

list_steps() {
    cat << 'STEPS'
Steps (run in this order by default):
  prereqs    Install ca-certificates, curl, gnupg
  add-repo   Add Docker's official apt repository + GPG key
  install    Install docker-ce, containerd.io, buildx + compose plugins
  enable     systemctl enable --now docker
  add-user   Add --user to the docker group (so compose works without sudo)
  verify     docker --version, docker compose version, docker run hello-world
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

step_prereqs() {
    print_info "Installing prerequisites"
    apt-get update
    apt-get install -y ca-certificates curl gnupg
}

step_add_repo() {
    print_info "Adding Docker's apt repository"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$KEYRING"
    chmod a+r "$KEYRING"

    local arch codename
    arch="$(dpkg --print-architecture)"
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    echo "deb [arch=$arch signed-by=$KEYRING] https://download.docker.com/linux/ubuntu $codename stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update
}

step_install() {
    print_info "Installing Docker"
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

step_enable() {
    print_info "Enabling Docker"
    systemctl enable --now docker
}

step_add_user() {
    if [ -z "$ADMIN_USER" ]; then
        print_warn "No --user given and \$SUDO_USER is empty — skipping docker group membership"
        return
    fi
    print_info "Adding $ADMIN_USER to the docker group"
    usermod -aG docker "$ADMIN_USER"
    print_warn "$ADMIN_USER needs to log out and back in (or run 'newgrp docker') for this to take effect"
}

step_verify() {
    print_info "Verifying"
    docker --version
    docker compose version
    docker run --rm hello-world
}


# Flag parsing

while [ $# -gt 0 ]; do
    case "$1" in
        --user) ADMIN_USER="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --skip) SKIP="$2"; shift 2 ;;
        --start) START="$2"; shift 2 ;;
        --list-steps) list_steps; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) print_error "Unknown flag: $1"; usage; exit 1 ;;
    esac
done


# Run

should_run "prereqs"    && step_prereqs
should_run "add-repo"   && step_add_repo
should_run "install"    && step_install
should_run "enable"     && step_enable
should_run "add-user"   && step_add_user
should_run "verify"     && step_verify

print_info "Done"
