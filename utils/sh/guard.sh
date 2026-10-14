#!/bin/bash
# Shared pre-flight checks for server/* scripts. Source, don't execute.
# Depends on print.sh already being sourced (uses print_error).

readonly HARDENED_MARKER="/etc/server-hardened"

require_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This must be run as root (sudo bash $(basename "$0"))"
        return 1
    fi
}

# Checks the account that invoked sudo (not root itself, which anyone can
# become many ways) matches $1 — e.g. require_user tunnel.
require_user() {
    local expected="$1"
    if [ "${SUDO_USER:-}" != "$expected" ]; then
        print_error "This must be run via 'sudo' as $expected (got '${SUDO_USER:-<none, running as root directly>}')"
        return 1
    fi
}

# Checks utils/sh/harden.sh's ssh-harden step has actually completed
# (it writes $HARDENED_MARKER right after restarting sshd with the
# hardened config) — not just that harden.sh was run with some subset of
# steps that skipped ssh-harden entirely.
require_hardened() {
    if [ ! -f "$HARDENED_MARKER" ]; then
        print_error "This box hasn't been hardened yet — run utils/sh/harden.sh's ssh-harden step first"
        return 1
    fi
}
