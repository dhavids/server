#!/bin/bash
# Stands up Guacamole on the Pi (guacd + guacamole webapp + postgres, via
# Docker). Two phases, run separately: --prepare (no outside-world
# dependency beyond joining the tailnet) and --activate (needs the VPS
# reachable over the tailnet — runs vps/update.sh there, over ssh, to wire
# guac's tunnel route). Per-host RDP provisioning (GatewayPorts, host
# accounts, Guacamole connection entries) is separate — see add-host.sh
# and client.sh. Root-level hardening is assumed already run separately
# (guac/setup-ssh.sh) — this script does not harden anything.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVER_ROOT="$(dirname "$SCRIPT_DIR")"
readonly ENV_FILE="$SCRIPT_DIR/.env"
readonly INITDB_DIR="$SCRIPT_DIR/initdb"
readonly GUAC_IMAGE="guacamole/guacamole:1.6.0"
source "$SERVER_ROOT/utils/sh/print.sh"
source "$SERVER_ROOT/utils/sh/guard.sh"
source "$SERVER_ROOT/utils/sh/tailscale.sh"
source "$SERVER_ROOT/utils/sh/vps_ssh.sh"

POSTGRES_PASSWORD=""
TAILSCALE_IP=""
VPS_HOST=""
VPS_ID=""
SUBDOMAIN=""
GUAC_PORT=""
ONLY=""
SKIP=""
START=""
STEPS_SELECTED="0"

readonly ALL_STEPS="install-req tailscale-up init-schema write-env compose-up update"

declare -A BUNDLES=(
    [prepare]="install-req tailscale-up init-schema write-env compose-up"
    [activate]="update"
)


# Usage

usage() {
    cat << 'USAGE'
Usage: sudo bash setup.sh [options]

Run guac/setup-ssh.sh first, as root, then SSH in as the guac user it
created and run this.

Optional:
  -p, --prepare    Run only the phase with no outside-world dependency
                   (default when no step-selecting flag is given)
  -a, --activate   Run only the phase that needs the VPS reachable over
                   the tailnet — currently just wires up guac's tunnel
                   route (vps/update.sh, run remotely via ssh). Per-host
                   RDP provisioning isn't built yet (needs the host->port
                   registry decided first).
  --vps-host HOST  VPS's Tailscale IP/hostname, for -a
  -i, --vps-id ID  VPS's <hostname-prefix>-<ip-suffix> (e.g. v22-62),
                   resolved via 'tailscale status' — alternative to
                   --vps-host. If neither is given, -a auto-resolves to
                   the one tailnet peer whose hostname contains "vps" —
                   errors out if there's none or more than one.
  -s, --subdomain NAME  Passed through to vps/update.sh (default: guac-test)
  --guac-port PORT      Passed through to vps/update.sh (default: 8080)
  --only STEPS     Run only these comma-separated steps (or bundle names)
  --skip STEPS     Run all steps except these comma-separated ones
  --start STEP     Resume from this step onward (skip everything before it)
  --list-steps     Print available steps and exit
  -h, --help       Show this help and exit
USAGE
}

list_steps() {
    cat << 'STEPS'
Steps (run in this order by default):
  install-req   Call utils/sh/install-req.sh for docker
  tailscale-up  Install Tailscale, join the tailnet (tailscale up)
  init-schema   Generate initdb/01-schema.sql from the guacamole image,
                if not already present
  write-env     Write .env: POSTGRES_PASSWORD (generated once, cached) and
                TAILSCALE_IP (refreshed every run)
  compose-up    docker compose up -d
  update        ssh to --vps-host, run vps/update.sh there (wires guac's
                tunnel route) — needs --vps-host

Bundles (--prepare / --activate, or --only prepare / --only activate):
  prepare    -> install-req, tailscale-up, init-schema, write-env,
                compose-up (needs nothing but the tailnet)
  activate   -> update (ssh to --vps-host, run vps/update.sh there —
                per-host RDP provisioning is separate and not built yet)
STEPS
}


# Step dispatch

expand_steps() {
    local input="$1"
    local expanded=""
    local tok
    for tok in ${input//,/ }; do
        if [ -n "${BUNDLES[$tok]:-}" ]; then
            expanded="$expanded ${BUNDLES[$tok]}"
        else
            expanded="$expanded $tok"
        fi
    done
    echo "${expanded// /,}" | sed 's/^,//'
}

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

step_install_req() {
    bash "$SERVER_ROOT/utils/sh/install-req.sh" docker
}

step_tailscale_up() {
    bash "$SERVER_ROOT/utils/sh/install-req.sh" tailscale
    if tailscale ip -4 &> /dev/null; then
        print_info "Already joined a tailnet ($(tailscale ip -4))"
        return
    fi
    print_info "Running 'tailscale up' — this opens a URL to authorize in a browser"
    tailscale up
    if ! tailscale ip -4 &> /dev/null; then
        print_error "tailscale up returned but no tailnet IP is assigned — not joined."
        print_error "Open the URL above and approve it (or check for pending admin approval), then re-run."
        exit 1
    fi
    print_info "Tailscale joined: $(tailscale ip -4)"
}

step_init_schema() {
    if [ -f "$INITDB_DIR/01-schema.sql" ]; then
        print_info "initdb/01-schema.sql already present"
        return
    fi
    print_info "Generating Guacamole's Postgres schema from $GUAC_IMAGE"
    mkdir -p "$INITDB_DIR"
    docker run --rm "$GUAC_IMAGE" /opt/guacamole/bin/initdb.sh --postgresql > "$INITDB_DIR/01-schema.sql"
}

step_write_env() {
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    fi
    if [ -z "$POSTGRES_PASSWORD" ]; then
        # pipefail + SIGPIPE: head closing early kills tr non-zero even
        # though the output is fine — the `|| true` absorbs that.
        POSTGRES_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)"
        print_info "Generated a new POSTGRES_PASSWORD"
    fi
    if ! tailscale ip -4 &> /dev/null; then
        print_error "No tailnet IP assigned — tailscale-up must succeed before write-env runs."
        exit 1
    fi
    TAILSCALE_IP="$(tailscale ip -4)"
    cat > "$ENV_FILE" << ENV
POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
TAILSCALE_IP="$TAILSCALE_IP"
ENV
    print_info "Wrote $ENV_FILE (TAILSCALE_IP=$TAILSCALE_IP)"
}

step_compose_up() {
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" --env-file "$ENV_FILE" up -d
}

# Runs vps/update.sh on the VPS, over ssh — it can't run locally, guac's
# webapp info (Tailscale IP) only exists here, but the tunnel it's merged
# into lives on the VPS.
step_update() {
    if [ -z "$VPS_HOST" ]; then
        # resolve_tailscale_peer's own stderr (error/candidates) stays
        # visible either way; || true just stops its exit status (unset
        # on no/ambiguous match) from tripping set -e on this assignment.
        VPS_HOST="$(resolve_tailscale_peer vps)" || true
        if [ -n "$VPS_HOST" ]; then
            print_info "No --vps-host/--vps-id given — auto-resolved to the one tailnet peer matching 'vps': $VPS_HOST"
        fi
    fi
    if [ -z "$VPS_HOST" ]; then
        print_error "--vps-host (or --vps-id) is required for the update step"
        exit 1
    fi
    if ! tailscale ip -4 &> /dev/null; then
        print_error "No tailnet IP assigned — tailscale-up must succeed before update runs."
        exit 1
    fi

    ensure_vps_ssh_access "$VPS_HOST" || exit 1

    local guac_ip
    guac_ip="$(tailscale ip -4)"
    local remote_args=(--guac-ip "$guac_ip")
    [ -n "$SUBDOMAIN" ] && remote_args+=(--subdomain "$SUBDOMAIN")
    [ -n "$GUAC_PORT" ] && remote_args+=(--guac-port "$GUAC_PORT")
    print_info "Running vps/update.sh on $VPS_HOST via ssh"
    ssh -i "$VPS_SSH_KEY" "tunnel@$VPS_HOST" "sudo bash ~/server/vps/update.sh ${remote_args[*]}"
}


# Flag parsing

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--prepare) ONLY="prepare"; STEPS_SELECTED="1"; shift ;;
        -a|--activate) ONLY="activate"; STEPS_SELECTED="1"; shift ;;
        --vps-host) VPS_HOST="$2"; shift 2 ;;
        -i|--vps-id) VPS_ID="$2"; shift 2 ;;
        -s|--subdomain) SUBDOMAIN="$2"; shift 2 ;;
        --guac-port) GUAC_PORT="$2"; shift 2 ;;
        --only) ONLY="$2"; STEPS_SELECTED="1"; shift 2 ;;
        --skip) SKIP="$2"; STEPS_SELECTED="1"; shift 2 ;;
        --start) START="$2"; STEPS_SELECTED="1"; shift 2 ;;
        --list-steps) list_steps; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) print_error "Unknown flag: $1"; usage; exit 1 ;;
    esac
done

require_root || { usage; exit 1; }
require_user guac || exit 1
require_hardened || exit 1

if [ -z "$VPS_HOST" ] && [ -n "$VPS_ID" ]; then
    VPS_HOST="$(resolve_tailscale_peer "$VPS_ID")" || exit 1
    print_info "Resolved --vps-id '$VPS_ID' to $VPS_HOST"
fi

# No -p/-a/--only/--skip/--start at all means: just run prepare, not
# everything — activate needs --vps-host and the VPS reachable.
[ "$STEPS_SELECTED" = "0" ] && ONLY="prepare"

[ -n "$ONLY" ] && ONLY="$(expand_steps "$ONLY")"
[ -n "$SKIP" ] && SKIP="$(expand_steps "$SKIP")"


# Run

should_run "install-req"    && step_install_req
should_run "tailscale-up"   && step_tailscale_up
should_run "init-schema"    && step_init_schema
should_run "write-env"      && step_write_env
should_run "compose-up"     && step_compose_up
should_run "update"         && step_update

if [ -z "$TAILSCALE_IP" ] && [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi
print_info "Done. Guacamole webapp: http://${TAILSCALE_IP:-<tailscale-ip>}:8080/guacamole (default login guacadmin/guacadmin — change it immediately)."
