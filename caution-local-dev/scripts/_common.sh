#!/usr/bin/env bash
# Shared config for the local-dev scripts. Sourced by up.sh / down.sh / etc.
# Override any of these via environment variables.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Path to the platform repo. Set CAUTION_REPO explicitly (required when these
# scripts run from an installed skill, detached from the repo). Otherwise probe
# a few common locations relative to the scripts.
REPO="${CAUTION_REPO:-}"
if [ -z "$REPO" ]; then
  for _c in "$SCRIPT_DIR/../platform" "$SCRIPT_DIR/../../platform" \
            "$SCRIPT_DIR/../../caution-stuff/platform" "$HOME/laab/caution-stuff/platform"; do
    if [ -f "$_c/env.example" ]; then REPO="$(cd "$_c" && pwd)"; break; fi
  done
fi
[ -n "$REPO" ] && [ -f "$REPO/env.example" ] \
  || { echo "error: platform repo not found — set CAUTION_REPO=/path/to/platform" >&2; exit 1; }

# Where boot config (.env, prices.json, config.json) lives — matches the Makefile.
CFG="${CAUTION_CFG:-$HOME/.config/caution}"

NETWORK="${CAUTION_NETWORK:-caution-network}"
DB_VOLUME="${CAUTION_DB_VOLUME:-caution-postgres-data}"
DATA_DIR="${CAUTION_DATA_DIR_HOST:-/tmp/caution-data}"

# Published ports
GATEWAY_PORT="${CAUTION_GATEWAY_PORT:-8000}"
API_PORT="${CAUTION_API_PORT:-8080}"   # api published too so you can curl it directly
SSH_PORT="${CAUTION_SSH_PORT:-2222}"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
