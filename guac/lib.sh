#!/bin/bash
# Shared host-registry helpers for add-host.sh/remove-host.sh. Source,
# don't execute. Assumes REGISTRY_FILE and BASE_PORT are already set.

# Prints (stdout) NAME's assigned port, or fails if it's not registered.
registry_port_for() {
    [ -f "$REGISTRY_FILE" ] || return 1
    awk -v n="$1" '$1 == n {print $2; found=1} END {exit !found}' "$REGISTRY_FILE"
}

# Prints (stdout) the next unused port, starting at BASE_PORT.
next_free_port() {
    local used max="$((BASE_PORT - 1))"
    if [ -f "$REGISTRY_FILE" ]; then
        used="$(awk '{print $2}' "$REGISTRY_FILE")"
        local p
        for p in $used; do
            [ "$p" -gt "$max" ] && max="$p"
        done
    fi
    echo "$((max + 1))"
}

# Removes NAME's line from the registry, if present.
registry_remove() {
    [ -f "$REGISTRY_FILE" ] || return 0
    sed -i "/^$1 /d" "$REGISTRY_FILE"
}

# The VPS's live view of every provisioned host, as "NAME PORT" lines —
# the actual source of truth, so two independent guac-hosts never collide.
# Assumes VPS_SSH_KEY is already set (source utils/sh/vps_ssh.sh first).
remote_ports() {
    ssh -i "$VPS_SSH_KEY" "tunnel@$1" "sudo bash ~/server/vps/list-ports.sh"
}

# Prints (stdout) NAME's port on the VPS, or fails if it's not there.
remote_port_for() {
    remote_ports "$1" | awk -v n="$2" '$1 == n {print $2; found=1} END {exit !found}'
}

# Prints (stdout) the next port free on the VPS, starting at BASE_PORT.
remote_next_free_port() {
    local used max="$((BASE_PORT - 1))"
    used="$(remote_ports "$1" | awk '{print $2}')"
    local p
    for p in $used; do
        [ "$p" -gt "$max" ] && max="$p"
    done
    echo "$((max + 1))"
}
