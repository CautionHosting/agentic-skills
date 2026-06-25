#!/usr/bin/env bash
# Bring up the Caution platform locally from the already-built images
# (caution-api, caution-gateway). Idempotent. Run inside your Linux amd64 host.
#
# Prereqs: built images (`make build-api build-gateway` in the repo), Docker running.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# 0. images present?
for img in caution-api caution-gateway; do
  docker image inspect "$img" >/dev/null 2>&1 \
    || die "image '$img' not found — build it: (cd $REPO && make build-api build-gateway)"
done

# 1. cgroup driver (no-op on a healthy Docker)
"$SCRIPT_DIR/fix-docker-cgroup.sh"

# 2. boot config
"$SCRIPT_DIR/setup-config.sh"

# 3. network + postgres (+ migrations on first creation)
docker network inspect "$NETWORK" >/dev/null 2>&1 || { log "creating network $NETWORK"; docker network create "$NETWORK" >/dev/null; }

if ! docker ps --format '{{.Names}}' | grep -qx postgres; then
  log "starting postgres"
  docker rm -f postgres >/dev/null 2>&1 || true
  docker run -d --name postgres --network "$NETWORK" \
    -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=caution \
    -v "$DB_VOLUME:/var/lib/postgresql/data" -p 5432:5432 postgres:16-alpine >/dev/null
  log "waiting for postgres"
  until docker exec postgres pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
  log "applying migrations"
  for m in "$REPO"/src/api/migrations/*.sql; do
    docker run --rm --network "$NETWORK" -v "$REPO/src/api/migrations:/m:ro" \
      -e PGPASSWORD=postgres postgres:16-alpine \
      psql -h postgres -U postgres -d caution -q -f "/m/$(basename "$m")" >/dev/null 2>&1 || true
  done
else
  log "postgres already up"
fi

# 4. api + gateway
mkdir -p "$DATA_DIR"
log "starting api"
docker rm -f api >/dev/null 2>&1 || true
docker run -d --name api --network "$NETWORK" -p "$API_PORT:8080" \
  --env-file "$CFG/.env" -e CAUTION_DATA_DIR=/var/cache/caution \
  -v "$CFG/prices.json:/app/prices.json:ro" \
  -v "$CFG/config.json:/app/config.json:ro" \
  -v "$DATA_DIR:/var/cache/caution" caution-api >/dev/null

log "starting gateway"
docker rm -f gateway >/dev/null 2>&1 || true
docker run -d --name gateway --network "$NETWORK" -p "$GATEWAY_PORT:8080" -p "$SSH_PORT:2222" \
  --env-file "$CFG/.env" -e CAUTION_DATA_DIR=/var/cache/caution \
  -v "$DATA_DIR:/var/cache/caution" caution-gateway >/dev/null

sleep 5
log "status"
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'postgres|api|gateway' || true
log "build-inputs endpoint (through gateway :$GATEWAY_PORT)"
curl -s "http://localhost:$GATEWAY_PORT/.well-known/caution/build-inputs" || true
echo
log "dashboard: http://localhost:$GATEWAY_PORT   (register with: ./gen-alpha-code.sh)"
