#!/usr/bin/env bash
# Stage the boot config the services need (idempotent — won't clobber existing files).
# Fills in dev dummies for deploy-only knobs so the api/gateway will actually start.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

mkdir -p "$CFG"

if [ ! -f "$CFG/.env" ]; then
  log "writing $CFG/.env"
  grep -vE '^\s*#|^\s*$' "$REPO/env.example" > "$CFG/.env"
  cat >> "$CFG/.env" <<EOF

# --- local-dev overrides (dummies for deploy-only knobs) ---
DATABASE_URL=postgres://postgres:postgres@postgres:5432/caution
CSRF_SECRET=$(openssl rand -hex 16)
BUILDER_AMI_ID=ami-0000000000dummy
BUILDER_SECURITY_GROUP_ID=sg-0000000000dummy
BUILDER_SUBNET_ID=subnet-0000000000dummy
BUILDER_INSTANCE_PROFILE=dummy-profile
TERRAFORM_STATE_BUCKET=dummy-bucket
EOF
else
  log "$CFG/.env exists — leaving it"
fi

# Ensure the secrets that services refuse to boot without are non-empty.
# env.example ships INTERNAL_SERVICE_SECRET/CSRF_SECRET blank; the metering and
# gateway services exit immediately if they're empty (the dev stack skips
# metering, but the e2e suites need it). Idempotent — only fills blanks.
ensure_secret() {
  local key="$1"
  if grep -qE "^${key}=$" "$CFG/.env"; then
    log "setting $key in $CFG/.env"
    local val; val="$(openssl rand -hex 24)"
    sed -i.bak "s|^${key}=$|${key}=${val}|" "$CFG/.env" && rm -f "$CFG/.env.bak"
  fi
}
ensure_secret INTERNAL_SERVICE_SECRET
ensure_secret CSRF_SECRET

[ -f "$CFG/prices.json" ] || { log "copying prices.json"; cp "$REPO/prices.json.example" "$CFG/prices.json"; }
[ -f "$CFG/config.json" ] || { log "copying config.json"; cp "$REPO/config.json.example" "$CFG/config.json"; }

log "config ready in $CFG"
