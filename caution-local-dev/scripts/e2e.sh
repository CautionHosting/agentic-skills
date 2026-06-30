#!/usr/bin/env bash
# Run a Caution e2e suite locally. Stages the config the test stack needs, then
# invokes a `make test-e2e-*` target. Each target stands up an *ephemeral* test
# Postgres + the services it needs, runs the suite, and tears everything down.
#
# Requires a Linux amd64 host with Docker (on a non-Linux workstation, run this
# inside a Linux amd64 VM). Idempotent.
#
# Usage:
#   ./e2e.sh                       # default: test-e2e-billing
#   ./e2e.sh test-e2e-byoc         # any make test-e2e-* target
#   CAUTION_REPO=/path ./e2e.sh    # when detached from the repo
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

TARGET="${1:-test-e2e-billing}"

# 1. Boot config in ~/.config/caution (.env, prices.json, config.json). Also
#    guarantees a non-empty INTERNAL_SERVICE_SECRET — metering won't start
#    without it, and the billing/metering suites need metering up.
"$SCRIPT_DIR/setup-config.sh"

# 2. run-api-test loads an --env-file .env from the repo root *in addition* to
#    the shared one; stage it from the example if missing.
if [ ! -f "$REPO/.env" ]; then
  log "writing $REPO/.env (repo-root env for run-api-test)"
  cp "$REPO/env.example" "$REPO/.env"
fi

log "running make $TARGET (ephemeral test stack; auto torn down)"
cd "$REPO"
exec make "$TARGET"
