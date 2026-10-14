#!/bin/bash
# Shared logging helpers for server/* scripts. Source, don't execute.

print_info() {
    echo "[info] $1"
}

print_warn() {
    echo "[warn] $1" >&2
}

# Non-error stderr output, safe even if the caller captures stdout.
print_hint() {
    echo "[hint] $1" >&2
}

print_error() {
    echo "[error] $1" >&2
}
