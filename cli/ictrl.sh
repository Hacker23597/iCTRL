#!/bin/sh
# Entry point for the bundled iCTRL CLI.
#
# Skill files arrive without the exec bit — the Minis importer writes every
# non-directory file as 0644 and never chmods — so invoking the binary directly
# fails with EACCES on a fresh install. This wrapper is run as `sh ictrl.sh`,
# which needs no exec bit itself, and fixes the binary's mode on first use.
#
# Usage: sh ictrl.sh [--host HOST:PORT] <command> [args...]

set -e
dir=$(dirname "$0")
bin="$dir/ictrl"

if [ ! -f "$bin" ]; then
    echo "ictrl.sh: $bin not found — the skill's binary is missing" >&2
    exit 1
fi

# chmod is cheap and idempotent; checking first costs an extra stat for nothing.
[ -x "$bin" ] || chmod +x "$bin" 2>/dev/null || true

exec "$bin" "$@"
