#!/usr/bin/env bash
# Stop and remove the platform containers. Keeps the postgres data volume and
# the network, so the next `up.sh` is fast and your DB (accounts, codes) persists.
# For a full wipe use down-clean.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

log "removing containers: gateway api postgres"
docker rm -f gateway api postgres >/dev/null 2>&1 || true

log "stopped. data volume '$DB_VOLUME' and network '$NETWORK' kept."
log "full reset: ./down-clean.sh"
