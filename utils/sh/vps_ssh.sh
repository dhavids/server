#!/bin/bash
# Bootstraps and checks this box's dedicated SSH key for reaching the VPS
# as `tunnel`. Source, don't execute. Assumes print.sh is in scope.

readonly VPS_SSH_KEY="/root/.ssh/vps_tunnel_ed25519"

# Generates $VPS_SSH_KEY if missing, then confirms tunnel@$1 accepts it —
# prints the exact authorized_keys command and returns 1 if it doesn't.
ensure_vps_ssh_access() {
    local vps_host="$1"

    if [ ! -f "$VPS_SSH_KEY" ]; then
        mkdir -p "$(dirname "$VPS_SSH_KEY")"
        ssh-keygen -t ed25519 -N '' -f "$VPS_SSH_KEY" -C "guac-host->vps tunnel access" &> /dev/null
        print_info "Generated a new SSH key at $VPS_SSH_KEY"
    fi

    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -i "$VPS_SSH_KEY" "tunnel@$vps_host" "echo ok" &> /dev/null; then
        cat << INSTR
On $vps_host, as tunnel, run this then come back and re-run this:

echo "$(cat "$VPS_SSH_KEY.pub")" >> ~/.ssh/authorized_keys
INSTR
        return 1
    fi
}
