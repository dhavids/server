#!/bin/bash
# Stands up derper directly on the Pi (no container yet) to validate DERP
# relay connectivity before building the full compose stack. Two phases,
# run separately: --prepare (no outside-world dependency) and --activate
# (needs DNS/port-80 actually working). See --help and --list-steps for the
# full flag and step breakdown. Root-level hardening is assumed already run
# separately — this script does not harden anything.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVER_ROOT="$(dirname "$SCRIPT_DIR")"
readonly CACHE_FILE="$SCRIPT_DIR/.env"
source "$SERVER_ROOT/utils/sh/print.sh"
source "$SERVER_ROOT/utils/sh/guard.sh"

DOMAIN=""
SUBDOMAIN="derp"
DERP_HOST=""
EMAIL=""
DERPER_PORT="8443"
STUN_PORT="3478"
ONLY=""
SKIP=""
START=""
PREPARE_FLAG="0"
ACTIVATE_FLAG="0"
DOMAIN_OVERRIDE="0"
DERP_HOST_OVERRIDE="0"

readonly ALL_STEPS="install-req derper-build derper-service write-ingress start-cloudflared tailscale-acl reachability-check derper-cert verify"

# "prepare" only needs outbound internet (cloudflared included); "activate" needs DNS/port-80 working.
declare -A BUNDLES=(
    [prepare]="install-req derper-build derper-service write-ingress start-cloudflared tailscale-acl"
    [activate]="reachability-check derper-cert verify"
)


# Usage

usage() {
    cat << 'USAGE'
Usage: sudo bash setup.sh -d DOMAIN -e EMAIL [options]

Required:
  -d, --domain DOMAIN     Base domain, e.g. example.com (derives SUBDOMAIN.DOMAIN)
  -e, --email EMAIL       Real email address for Let's Encrypt notices

Optional:
  -s, --subdomain NAME    Subdomain prefix (default: derp) — e.g. -s derp-vm
                          gives derp-vm.DOMAIN, so a VM test run doesn't
                          collide with the real Pi's derp.DOMAIN
  --derp-host HOST        Override the derived SUBDOMAIN.DOMAIN entirely
  --derper-port PORT      Internal port derper listens on (default: 8443)
  --stun-port PORT        STUN port, must match the router's forwarded port (default: 3478)
  -p, --prepare           Run only the phase with no outside-world dependency
  -a, --activate          Run only the phase that needs DNS/port-80 working
                          (-e/--email may be overridden here; -d/-s/
                          --derp-host may not — re-run --prepare to change those)
  --only STEPS            Run only these comma-separated steps (or bundle names)
  --skip STEPS            Run all steps except these comma-separated ones
  --start STEP            Resume from this step onward (skip everything before it)
  --list-steps            Print available steps and exit
  -h, --help              Show this help and exit
USAGE
}

list_steps() {
    cat << 'STEPS'
Steps (run in this order by default):
  install-req          Call utils/sh/install-req.sh for cloudflared (no Docker on the VPS)
  derper-build         Install the derper binary
  derper-service       Write + start derper's systemd service (no cert yet)
  write-ingress        Write server/cloudflared's ingress fragment for derp
  start-cloudflared    Call server/cloudflared/start.sh (idempotent)
  tailscale-acl        Manual: print the derpMap ACL block to add
  reachability-check   Confirm DNS for derp-host resolves to this Pi
  derper-cert          Get derper's cert via certbot standalone (HTTP-01), restart derper
  verify               Status check + local curl test

Bundles (--prepare / --activate, or --only prepare / --only activate):
  prepare    -> install-req, derper-build, derper-service, write-ingress,
                start-cloudflared, tailscale-acl (needs nothing from the
                outside world)
  activate   -> reachability-check, derper-cert, verify
               (needs DNS + port 80 actually working)

Example: sudo bash setup.sh -d example.com -p
Example: sudo bash setup.sh -d example.com -e you@example.com -a
STEPS
}


# Step dispatch

expand_steps() {
    local raw="$1"
    local expanded=""
    local tok
    for tok in ${raw//,/ }; do
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
    bash "$SERVER_ROOT/utils/sh/install-req.sh" cloudflared
}

step_derper_build() {
    print_info "Installing derper"
    apt-get update
    apt-get install -y golang-go git certbot

    export GOPATH=/root/go
    export PATH="$PATH:/root/go/bin"
    go install tailscale.com/cmd/derper@latest
    cp /root/go/bin/derper /usr/local/bin/derper
    mkdir -p /var/lib/derper/certs
}

step_reachability_check() {
    print_info "Checking DNS for $DERP_HOST points at this Pi"
    local resolved pi_ip
    resolved="$(getent ahostsv4 "$DERP_HOST" | awk '{print $1}' | head -n1 || true)"
    pi_ip="$(curl -4 -s ifconfig.me || true)"
    if [ -z "$pi_ip" ]; then
        print_error "Could not detect this Pi's public IP (curl ifconfig.me failed) — check internet access"
        exit 1
    fi
    if [ "$resolved" != "$pi_ip" ]; then
        print_error "$DERP_HOST resolves to '${resolved:-<nothing>}', this Pi's public IP is '$pi_ip'"
        print_error "Fix DNS/dynamic-DNS before continuing — certbot's HTTP-01 challenge needs this to match"
        exit 1
    fi
    print_info "DNS OK: $DERP_HOST -> $pi_ip"
}

step_derper_cert() {
    print_info "Obtaining derper's cert via certbot standalone"
    certbot certonly --standalone -d "$DERP_HOST" \
        --preferred-challenges http -m "$EMAIL" --agree-tos --non-interactive

    cp "/etc/letsencrypt/live/$DERP_HOST/fullchain.pem" "/var/lib/derper/certs/$DERP_HOST.crt"
    cp "/etc/letsencrypt/live/$DERP_HOST/privkey.pem" "/var/lib/derper/certs/$DERP_HOST.key"

    # derper-service already enabled it without a cert, so it's crash-looping — pick up the real one now
    systemctl restart derper
}

step_derper_service() {
    print_info "Creating derper systemd service"
    cat > /etc/systemd/system/derper.service << EOF
[Unit]
Description=Tailscale DERP server (Pi validation run)
After=network.target

[Service]
ExecStart=/usr/local/bin/derper \\
  --hostname=$DERP_HOST \\
  --certmode=manual \\
  --certdir=/var/lib/derper/certs \\
  --a=:$DERPER_PORT \\
  --http-port=-1 \\
  --stun-port=$STUN_PORT
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now derper
}

step_write_ingress() {
    print_info "Writing cloudflared ingress fragment"
    cat > "$SCRIPT_DIR/cloudflared.ingress.yml" << FRAGMENT
  - hostname: $DERP_HOST
    service: https://localhost:$DERPER_PORT
    originRequest:
      noTLSVerify: true
      originServerName: $DERP_HOST
FRAGMENT
}

step_start_cloudflared() {
    print_info "Calling server/cloudflared/start.sh"
    bash "$SERVER_ROOT/cloudflared/start.sh"
}

step_verify() {
    print_info "Verifying"
    sleep 3
    systemctl is-active derper || print_warn "derper is not active"
    curl -sI "https://$DERP_HOST:$DERPER_PORT/" \
        || print_warn "local curl failed — check derper logs with: journalctl -u derper"
}

step_tailscale_acl() {
    local vps_ip
    vps_ip="$(curl -4 -s ifconfig.me || echo '<could-not-detect-run-curl -4 ifconfig.me-manually>')"

    cat << ACL

MANUAL STEP: add this to your Tailscale ACL policy at
https://login.tailscale.com/admin/acls (as a sibling of "acls", keep everything else):

  "derpMap": {
    "OmitDefaultRegions": false,
    "Regions": {
      "900": {
        "RegionID": 900,
        "RegionCode": "custom",
        "RegionName": "My Pi",
        "Nodes": [
          {
            "Name": "900a",
            "RegionID": 900,
            "HostName": "$DERP_HOST",
            "IPv4": "$vps_ip"
          }
        ]
      }
    }
  }

Then verify from any tailnet device:
  tailscale netcheck        # the custom region should show a real latency
  tailscale ping <peer-ip>  # should show via DERP(custom) once selected
ACL
}


# Cache

write_cache() {
    cat > "$CACHE_FILE" << CACHE
DOMAIN="$DOMAIN"
SUBDOMAIN="$SUBDOMAIN"
EMAIL="$EMAIL"
DERP_HOST="$DERP_HOST"
DERPER_PORT="$DERPER_PORT"
STUN_PORT="$STUN_PORT"
CACHE
}

if [ -f "$CACHE_FILE" ]; then
    print_info "Loading cached config from $CACHE_FILE (flags below override it)"
    source "$CACHE_FILE"
fi


# Flag parsing

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--domain) DOMAIN="$2"; DOMAIN_OVERRIDE="1"; shift 2 ;;
        -s|--subdomain) SUBDOMAIN="$2"; DOMAIN_OVERRIDE="1"; shift 2 ;;
        --derp-host) DERP_HOST="$2"; DOMAIN_OVERRIDE="1"; DERP_HOST_OVERRIDE="1"; shift 2 ;;
        -e|--email) EMAIL="$2"; shift 2 ;;
        --derper-port) DERPER_PORT="$2"; shift 2 ;;
        --stun-port) STUN_PORT="$2"; shift 2 ;;
        -p|--prepare) ONLY="prepare"; PREPARE_FLAG="1"; shift ;;
        -a|--activate) ONLY="activate"; ACTIVATE_FLAG="1"; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        --skip) SKIP="$2"; shift 2 ;;
        --start) START="$2"; shift 2 ;;
        --list-steps) list_steps; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) print_error "Unknown flag: $1"; usage; exit 1 ;;
    esac
done

require_root || { usage; exit 1; }

[ -n "$ONLY" ] && ONLY="$(expand_steps "$ONLY")"
[ -n "$SKIP" ] && SKIP="$(expand_steps "$SKIP")"

if [ "$ACTIVATE_FLAG" = "1" ] && [ "$DOMAIN_OVERRIDE" = "1" ]; then
    print_error "--domain/--subdomain/--derp-host can't be changed via --activate — the host was"
    print_error "already fixed by --prepare (derper's service, ingress fragment, and tunnel are"
    print_error "built around it). Re-run --prepare to change it, which rebuilds all three."
    exit 1
fi

# Recompute from DOMAIN+SUBDOMAIN unless --derp-host overrides, so a cached DERP_HOST never goes stale.
[ "$DERP_HOST_OVERRIDE" != "1" ] && [ -n "$DOMAIN" ] && DERP_HOST="${SUBDOMAIN}.${DOMAIN}"

if [ -z "$DERP_HOST" ]; then
    print_error "--domain (or --derp-host) is required (nothing cached yet at $CACHE_FILE)"
    usage
    exit 1
fi
if [ -z "$EMAIL" ] && { should_run "derper-cert" || [ "$PREPARE_FLAG" = "1" ]; }; then
    print_error "--email is required (caches now so --activate won't need it later)"
    usage
    exit 1
fi

print_info "DERP_HOST=$DERP_HOST DERPER_PORT=$DERPER_PORT STUN_PORT=$STUN_PORT"
write_cache


# Run

should_run "install-req"          && step_install_req
should_run "derper-build"         && step_derper_build
should_run "derper-service"       && step_derper_service
should_run "write-ingress"        && step_write_ingress
should_run "start-cloudflared"    && step_start_cloudflared
should_run "tailscale-acl"        && step_tailscale_acl
should_run "reachability-check"   && step_reachability_check
should_run "derper-cert"          && step_derper_cert
should_run "verify"               && step_verify

print_info "Done"
