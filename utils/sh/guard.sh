#!/bin/bash
# Shared pre-flight checks for server/* scripts. Source, don't execute.
# Depends on print.sh already being sourced (uses print_error).

require_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This must be run as root (sudo bash $(basename "$0"))"
        return 1
    fi
}
