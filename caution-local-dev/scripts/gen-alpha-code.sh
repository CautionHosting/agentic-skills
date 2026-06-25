#!/usr/bin/env bash
# Mint a single-use alpha/beta registration code in the running postgres.
# (Registration is alpha-gated by the `beta_codes` table; the CLI flag is --alpha-code.)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

docker ps --format '{{.Names}}' | grep -qx postgres || die "postgres not running — start it with ./up.sh"

code="$(openssl rand -hex 16)"
docker exec -e PGPASSWORD=postgres postgres \
  psql -U postgres -d caution -q -c \
  "INSERT INTO beta_codes (code, created_by) VALUES ('$code','local-dev')" >/dev/null

echo "$code"
echo "register:  caution register --alpha-code $code"
echo "       or:  open http://localhost:$GATEWAY_PORT and paste it"
