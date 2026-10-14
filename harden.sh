#!/bin/bash
# Box-level hardening for the Pi, run once before any target's compose comes
# up — not specific to derp/guac/cloudflared, which each open their own
# ports separately. See --help and --list-steps for the full breakdown.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/sh/print.sh"
source "$SCRIPT_DIR/utils/sh/guard.sh"

readonly ALL_STEPS="baseline firewall ssh-harden"

ADMIN_USER="${SUDO_USER:-}"
ASSUME_YES="0"
ONLY=""
SKIP=""
START=""


# Usage

usage() {
    cat << 'USAGE'
Usage: sudo bash harden.sh [options]

Optional:
  --user NAME   Admin account to verify key-login for before locking SSH down
                (default: whoever ran sudo)
  -y, --yes     Don't prompt before restarting SSH
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
  baseline     apt upgrade, install + enable ufw/fail2ban/unattended-upgrades
  firewall     ufw: allow SSH + outgoing, deny incoming, enable
  ssh-harden   Disable root/password login, enable key-only, set ClientAlive

Each target (derp, guac, cloudflared) opens whatever ports it specifically
needs on its own — this script only sets the box-level baseline.
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

step_baseline() {
    print_info "Baseline packages"
    apt-get update
    apt-get upgrade -y
    apt-get install -y ufw fail2ban unattended-upgrades

    systemctl enable --now fail2ban
    dpkg-reconfigure -f noninteractive unattended-upgrades
}

step_firewall() {
    print_info "Configuring ufw"
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow OpenSSH
    ufw --force enable
}

step_ssh_harden() {
    if [ -z "$ADMIN_USER" ]; then
        print_error "--user is required for ssh-harden (couldn't infer it from \$SUDO_USER)"
        exit 1
    fi

    print_info "About to set PermitRootLogin/PasswordAuthentication no, PubkeyAuthentication yes, ClientAlive*"
    cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"

    local pair key val
    for pair in "PermitRootLogin:no" "PasswordAuthentication:no" "PubkeyAuthentication:yes" \
                "ClientAliveInterval:30" "ClientAliveCountMax:3"; do
        key="${pair%%:*}"
        val="${pair##*:}"
        if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" /etc/ssh/sshd_config; then
            sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+.*|${key} ${val}|" /etc/ssh/sshd_config
        else
            echo "${key} ${val}" >> /etc/ssh/sshd_config
        fi
    done

    # Cloud images ship /etc/ssh/sshd_config.d/50-cloud-init.conf with
    # PasswordAuthentication yes, read via an Include near the TOP of the
    # main config — it wins over anything edited above (first match wins).
    # A drop-in that sorts before it overrides that regardless.
    mkdir -p /etc/ssh/sshd_config.d
    if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
    fi
    {
        echo "PermitRootLogin no"
        echo "PasswordAuthentication no"
        echo "PubkeyAuthentication yes"
        echo "ClientAliveInterval 30"
        echo "ClientAliveCountMax 3"
    } > /etc/ssh/sshd_config.d/00-harden.conf

    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$ADMIN_USER@localhost" "echo ok" &> /dev/null; then
        print_info "Key login for $ADMIN_USER confirmed working before restarting SSH"
    else
        print_warn "Couldn't confirm key login for $ADMIN_USER automatically — verify it yourself before continuing"
    fi

    confirm "Restart SSH now to apply PermitRootLogin/PasswordAuthentication no? Open a second terminal and confirm $ADMIN_USER@<pi-ip> still logs in with a key before answering yes." \
        || { print_warn "sshd_config was edited but SSH was not restarted — changes aren't active yet"; return; }

    systemctl restart ssh
    print_info "SSH restarted with hardened config"
}


# Flag parsing

while [ $# -gt 0 ]; do
    case "$1" in
        --user) ADMIN_USER="$2"; shift 2 ;;
        -y|--yes) ASSUME_YES="1"; shift ;;
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

should_run "baseline"     && step_baseline
should_run "firewall"     && step_firewall
should_run "ssh-harden"   && step_ssh_harden

print_info "Done"
