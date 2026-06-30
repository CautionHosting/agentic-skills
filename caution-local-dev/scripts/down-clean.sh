#!/usr/bin/env bash
# Full reset: remove containers, the postgres data volume, the network, and the
# host data dir. The next up.sh starts from an empty DB and re-runs migrations.
# Does NOT touch built images or your ~/.config/caution config.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

log "removing containers"
docker rm -f gateway api postgres >/dev/null 2>&1 || true

log "removing data volume '$DB_VOLUME'"
docker volume rm "$DB_VOLUME" >/dev/null 2>&1 || true

log "removing network '$NETWORK'"
docker network rm "$NETWORK" >/dev/null 2>&1 || true

log "removing host data dir '$DATA_DIR'"
rm -rf "$DATA_DIR" 2>/dev/null || true

log "clean. (images and $CFG left intact)"
