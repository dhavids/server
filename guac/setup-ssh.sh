#!/bin/bash
# Thin wrapper around utils/sh/setup-ssh.sh for the Pi's pi user. See that
# script's --help for the full flag list (-u/--next are fixed here).
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVER_ROOT="$(dirname "$SCRIPT_DIR")"

exec bash "$SERVER_ROOT/utils/sh/setup-ssh.sh" --user pi --next guac/setup.sh "$@"
