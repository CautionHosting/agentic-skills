---
name: caution-local-dev
description: Use when running, building, debugging, or testing the Caution platform itself locally (the api/gateway/metering/email services + Postgres) on a Linux amd64 host or VM, as opposed to deploying a customer enclave app — e.g. bring up the dashboard, curl an API endpoint, generate an alpha/beta code to register, rebuild a service image, validate an enclave-component pin with a branch-local CLI and QEMU-booted EIF, run the unit or e2e test suites against an ephemeral test DB, or fix a Docker cgroup-driver failure in a nested Linux VM. For authoring a Caution app config or deploying an enclave, use caution-platform instead.
---

# Caution Local Dev (running the platform itself)

This is about running the **platform repo** (`codeberg.org/caution/platform`) locally — the
control-plane services, not a customer enclave. For app configs/deploys use the
`caution-platform` skill; for reproducible enclave builds use `stagex-reproducible-builds`.

## Architecture

Three Rust services plus Postgres, all on a Docker network `caution-network`:

| Service | Port | Notes |
|---|---|---|
| `gateway` | `8000` (HTTP), `2222` (SSH) | Public front door. Serves the built frontend at `/`, proxies API calls, terminates WebAuthn/SSH. Image `caution-gateway`. |
| `api` | `8080` (internal) | Control plane. Image `caution-api`. `enclave-builder` is a **library compiled into it**, not a separate service. |
| `postgres` | `5432` | `postgres:16-alpine`, persistent volume `caution-postgres-data`, DB `caution`. |
| `email`, `metering` | `8082`, `8083` | Optional; not needed to bring up the dashboard or hit most endpoints. |

- The **frontend** (Vue + Vite) is built to `frontend/dist` and **baked into the `caution-gateway` image** — the gateway serves it. A frontend change needs `npm run build` *then* a gateway image rebuild to show up.
- The gateway nests public API routes under `/api` (`nest("/api", …)`) and proxies them to the API with the `/api` prefix stripped. **Root-level paths like `/.well-known/*` must be merged at the root**, not in the nested group, or they 404.

## You need a Linux amd64 environment

The stack is Linux/amd64 (StageX images, systemd units, x86 kernel) and runs Docker. You need
**a Linux amd64 host with Docker** — a bare box, a cloud instance, or a local VM — and a way to
run commands and reach its ports. On a non-Linux workstation (e.g. macOS/Apple Silicon) that
means a Linux amd64 VM; any provider works (a cloud instance, Lima/UTM/Multipass, or
OrbStack). All commands below run **inside that Linux environment**; adapt how you
shell into it and how you reach `localhost:8000`/`:8080` (direct, SSH tunnel, or the VM's
forwarded ports) to your setup.

Two things to keep straight whatever you use:

- **The repo and the images must be on the same Docker engine.** Build (`make build-*`) and run on
  the same Linux host. If your VM tool exposes a *different* Docker engine than the one where you
  built (some do), `docker images` won't show `caution-api`/`caution-gateway` — point your commands
  at the engine that has them.
- **Port reachability is yours to arrange.** `curl http://localhost:8000/...` only works from where
  those ports are exposed; from another machine use the host's IP or a tunnel.
- **Worktree/branch awareness.** Images are built from whatever path you pass to `make build-*`.
  If you're in a `git worktree` or a different branch, build and run `up.sh` with `CAUTION_REPO`
  pointing at that checkout — otherwise the stack silently runs stale code from another branch.
  Verify the running commit matches your checkout:
  `curl -s http://localhost:8000/.well-known/caution/build-inputs | jq .platform.commit`
  should equal `git rev-parse HEAD`.

## Provisioning a bare Linux amd64 VM

A fresh box (OrbStack `ubuntu-amd64`, a cloud instance, whatever) has none of this. One-time setup:

```bash
sudo apt-get update &&
sudo apt-get install -y docker.io make git curl jq postgresql-client qemu-system-x86 cpio
sudo usermod -aG docker $USER   # then start a new shell / `newgrp docker`
```

- **`docker.io`** — the stack is all Docker images/containers; also apply the cgroupfs fix below
  if you're on a nested/LXC-based VM (OrbStack included) — required before any `docker run`
  (`docker build` works fine without it).
- **`make`** — every build/up/down/test entrypoint is a `make` target.
- **`postgresql-client`** (`psql`) — needed for `utils/admin` and any other host-side script that
  queries Postgres directly (containers ship their own `psql`, but host scripts don't).
- **`jq`** — used by several `utils/*.sh` scripts and handy for `curl | jq` on JSON endpoints.
- **`qemu-system-x86` + `cpio`** — needed only for the enclave-component pin smoke test below.
- No Rust/Go/cargo toolchain needed on the VM — all service builds happen inside Docker via
  `make build-*`. Only install a native toolchain for things outside the container build path
  (e.g. `cargo test` for unit tests — see "Running tests locally" below).

## ⚠️ The cgroup wall (fix this first)

In some nested/containerized Linux environments (notably LXC-based VMs, which OrbStack
machines are), dockerd defaults to the **systemd cgroup driver**, which is broken
there. Every `docker run`
(but not `docker build`) fails with:

```
unable to apply cgroup configuration: unable to start unit "docker-….scope"
… Failed to determine whether process N is a kernel thread: Inappropriate ioctl for device
```

systemd often can't manage dockerd itself in that setup either (`systemctl restart docker` fails
the same way, and an orphan dockerd from boot holds the pidfile). Fix once — switch to the
`cgroupfs` driver and restart dockerd by hand (run inside the Linux env):

```bash
echo '{ "exec-opts": ["native.cgroupdriver=cgroupfs"] }' | sudo tee /etc/docker/daemon.json
sudo pkill -9 -x dockerd 2>/dev/null; sleep 2          # kill the orphan; pkill needs -9 here
sudo rm -f /var/run/docker.pid
sudo setsid dockerd >/tmp/dockerd.log 2>&1 < /dev/null &
sleep 5
docker info --format 'cgroupDriver={{.CgroupDriver}}'  # must print cgroupfs
docker run --rm hello-world                            # smoke test
```

On a normal (non-nested) Linux box with a healthy systemd-managed Docker, you won't hit this —
skip it. If `make run-*`/`make postgres` ever fail with that ioctl error, the driver reverted —
re-apply.

## Bring up the stack

The platform runs as Docker **images** (`make build-api build-gateway` first), not via systemd: a
fresh box has no `caution-*.service` units and no `~/.config/caution/` config, so `make up` /
`make postgres` (which use `systemctl --user`) don't apply. Use the bundled scripts in
[`scripts/`](scripts/) — provider-agnostic, idempotent, parameterized via env vars. Set
`CAUTION_REPO=/path/to/platform` when they run detached from the repo (e.g. as an installed skill):

```bash
cd scripts && CAUTION_REPO=/path/to/platform ./up.sh
```

| Script | Does |
|---|---|
| `up.sh` | cgroup fix (if needed) → stage config → postgres + migrations (if down) → api + gateway; prints the endpoint + dashboard URL. Idempotent. |
| `down.sh` | Remove containers, **keep** the DB volume + network (fast restart, data persists). |
| `down-clean.sh` | Full reset — also drop the volume, network, host data dir (keeps images + config). |
| `setup-config.sh` | Stage `~/.config/caution/{.env,prices.json,config.json}` with dev dummies. |
| `fix-docker-cgroup.sh` | Switch dockerd to cgroupfs (the cgroup-wall fix); no-op on healthy Docker. |
| `e2e.sh` | Stage config + run a `make test-e2e-*` suite against an ephemeral test DB (see [Running tests locally](#running-tests-locally)). |
| `test-enclave-component-pin.sh` | Build/use a branch-local CLI, validate its STEVE pin in a real EIF, boot the rootfs under QEMU, and smoke-test app/STEVE/Bootproof packaging. |

Override `CAUTION_CFG`, `CAUTION_NETWORK`, `CAUTION_DB_VOLUME`, `CAUTION_*_PORT`, etc. — see
`scripts/_common.sh`.

**`up.sh` does not start the email service** — only postgres/api/gateway. If you need real
(test-mode) email delivery — verifying a user's email, testing notification flows — build and
start it separately:

```bash
make build-email-dev && make run-email
```

Starts on `http://localhost:8082`. With `EMAIL_TEST_MODE=true` (default in `.env`), sent emails
are logged, not delivered — inspect via `curl -s http://localhost:8082/sent | jq`. Without this,
email-dependent flows fail silently or error client-side (e.g. "We couldn't send the verification
link").

### Running `utils/admin` (or other host-side scripts needing DB/API access)

`utils/admin` runs on the host (not in a container) and sources `platform/.env` (gitignored,
distinct from `~/.config/caution/.env` which the containers use). Two things commonly break it on
a fresh checkout:

1. **No `psql` client on the host.** Install once: `sudo apt-get install -y postgresql-client`
   (also covered in "Provisioning a bare Linux amd64 VM" above).
2. **`platform/.env` is a stale template.** It ships with `API_SERVICE_URL=http://api:8080` (a
   container-network hostname, unreachable from the host) and a blank `INTERNAL_SERVICE_SECRET`.
   Fix both to match the running stack before using commands that call the API (e.g.
   `publish-legal-doc`'s notify step):
   ```bash
   grep INTERNAL_SERVICE_SECRET ~/.config/caution/.env   # the real secret the running stack uses
   # then in platform/.env (gitignored — safe to edit):
   #   API_SERVICE_URL=http://localhost:8080
   #   INTERNAL_SERVICE_SECRET=<value from above>
   ```
   Postgres itself is reachable at `localhost:5432` from the host (container publishes the port),
   so `DB_HOST`/`DB_PORT` defaults in `utils/admin` work as-is.

### Why the services need config to boot

`up.sh` stages this for you; know it for debugging. The **`api`** reads, in order, and dies on the
first missing one: `DATABASE_URL` (env) → `prices.json` → `config.json` (both in cwd `/app`) →
`BUILDER_AMI_ID` (env). The **`gateway`** additionally needs `CSRF_SECRET`. Other `BUILDER_*`/AWS/
Paddle vars are optional (warnings only). `prices.json`/`config.json` come from the repo's
`*.example`; the deploy-only knobs get dev-safe dummies. Sanity after boot: `docker logs api | tail`
ends with `API server listening on 0.0.0.0:8080`, gateway with `Gateway listening on 0.0.0.0:8080`.

## Building the images

```bash
make build-api build-gateway        # release-ish images
make build-api-dev build-gateway-dev  # faster debug builds (DEV_BUILD_ARGS)
```

- After a **frontend** change: `cd frontend && npm run build`, **then** `make build-gateway` (it bakes `frontend/dist`). The dev server (`npm run dev`, port 3000) is the hot-reload alternative; it proxies `/api`, `/auth`, `/health`, `/.well-known` to `VITE_PROXY_TARGET` (default `http://localhost:8000`).
- `enclave-builder` is compiled into `caution-api`, so `make build-api` picks up changes to it.
- Image build runs fine under the broken cgroup driver; only `docker run` needs the cgroupfs fix.

### Fast inner loop (API-only changes)

When iterating on API code only, skip the full `make up` and rebuild just the api image + restart only that container:

```bash
make build-api-dev run-api    # rebuild dev image, restart only api
docker logs -f api            # watch boot / runtime logs
```

This avoids rebuilding gateway/email/metering and is the tightest loop for API work. For systemd-based setups (where `make up` manages the services), the equivalent is `make build-api-dev` then `systemctl --user restart caution-api`. The same pattern applies per-service: `make build-gateway-dev run-gateway`, `make build-email-dev run-email`, etc.

### Validate an enclave-component pin with QEMU

Use this when a Platform branch changes `DEFAULT_STEVE_COMMIT` or the measured
STEVE configuration generated by `enclave-builder`. This is Platform development:
the application is a fixture, while the branch-local CLI/builder is the subject
under test.

The app must be a Git repository with a root `caution.hcl` or `Procfile` and a
container build. For X-Wing, configure:

```hcl
e2e_encryption {
  enabled      = true
  cors_origins = ["*"]
  key_exchange = "xwing-draft10"
}
```

Run the full integration smoke inside Linux amd64:

```bash
cd scripts
CAUTION_REPO=/path/to/platform ./test-enclave-component-pin.sh all \
  --app /path/to/test-app \
  --expected-steve-commit <40-character-sha> \
  --key-exchange XWING-DRAFT10 \
  --app-port 8083 \
  --expect-path usr/local/bin/hello
```

By default the script:

1. Refuses dirty Platform and app repositories.
2. Builds and installs a StageX CLI from the selected Platform checkout.
3. Leaves `STEVE_COMMIT` unset, proving the CLI's compiled default.
4. Runs `caution apps build --no-cache`.
5. Checks `manifest.json`, `Containerfile.eif`, generated `run.sh`, and the
   rootfs for the exact STEVE commit, selected suite, STEVE, Bootproof, and
   requested application paths.
6. Boots the generated rootfs with a swapped standard x86_64 kernel, matching
   virtio-net support, and a QEMU-only network bootstrap overlay. The app port,
   STEVE `49500`, and Bootproof `49502` are forwarded to the host.
7. Compares the direct app response with STEVE's plaintext fallback response
   and requires Bootproof to reach the expected missing-NSM boundary.

Use `--caution-bin /path/to/caution` to test an already-built branch-local CLI.
For a pre-bump experiment only, `--override-steve-commit <sha>` explicitly sets
the environment override; omit it when validating the committed default.
`build`, `run`, and `smoke` modes expose the same phases separately. Run
`./test-enclave-component-pin.sh --help` for all options.
When running QEMU inside OrbStack, pass `--host-address 0.0.0.0` so OrbStack
publishes the forwarded ports to macOS. The default `127.0.0.1` keeps them
local to the Linux host or VM.

The helper supports both official QEMU kernel modes:

- `all` uses `--kernel-mode standard`: a standard x86_64 kernel and its matching
  virtio-net support are swapped in. A temporary initrd overlay configures the
  fixed QEMU user-network address before handing off to the generated
  `/run.sh`; the built EIF and generated rootfs remain unchanged.
- For the closest boot/package compatibility check, first run `build`, copy its
  printed `BUILD_DIR`, then run:

  ```bash
  ./test-enclave-component-pin.sh run \
    --build-dir <printed-build-directory> \
    --kernel-mode nitro
  ```

  This extracts the exact `stagex/user-linux-nitro@sha256:...` image referenced
  by the generated `Containerfile.eif`. It provides serial/application logs but
  no networking because the Nitro kernel lacks virtio-net and VSOCK drivers.

This test proves package composition, generated startup configuration, process
startup, and local TCP routing. It does **not** prove Nitro authenticity,
PCR measurement, VSOCK transport, Caddy/TLS behavior, or a successful attested
STEVE session: QEMU has no `/dev/nsm`. Run STEVE's explicit synthetic browser
E2E separately for protocol coverage, then retain a real-Nitro test as the
release gate.

## Register / log in (alpha codes)

Registration is alpha-gated by the **`beta_codes`** table (note: table is `beta_codes`, flag is `--alpha-code`). Generate codes with the repo's `utils/generate-beta-codes.sh`:

Then register with a passkey — `RP_ID=localhost`, `RP_ORIGINS` includes `http://localhost:8000`, so Touch ID / platform passkeys work against `localhost`:

```bash
# generate 10 codes (default 50), against the running postgres container
bash "$REPO/utils/generate-beta-codes.sh" 10
```

Then register with a passkey:

- **Dashboard:** open `http://localhost:8000`, register, paste a code, create passkey.
- **CLI:** `caution register --alpha-code <code>`.

A code is valid while `used_at IS NULL` and unexpired; redemption sets `used_at`.

To list only unused (available) codes:

```bash
docker exec -e PGPASSWORD=postgres postgres psql -U postgres -d caution -t -A -c "SELECT code FROM beta_codes WHERE used_at IS NULL ORDER BY created_at DESC;"
```

### Credit codes (for billing/metering testing)

To test paid plans, billing flows, or metering without real payment, generate credit codes that add balance to a user's account. `utils/generate-credit-codes.sh` inserts into the credit codes table:

```bash
# generate 50 codes worth $100 each (default count 1, default container "postgres")
bash "$REPO/utils/generate-credit-codes.sh" 100 50
```

Args: `<amount_dollars> [count] [container]`. Amount is a positive integer (dollars, not cents). These let you test billing-gated features, plan upgrades, and metering against a local stack without Paddle or real payment.

## Verify it's working

```bash
curl -s http://localhost:8000/.well-known/caution/build-inputs   # through gateway
curl -s http://localhost:8080/.well-known/caution/build-inputs   # api direct (if -p 8080 published)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8000/  # dashboard HTML → 200
```

`/.well-known/caution/build-inputs` returns the platform's resolved enclave tool commits
(`enclaveos/bootproof/steve/locksmith`) — these come from `*_COMMIT` env vars on the API host
(else pinned defaults). Set e.g. `BOOTPROOF_COMMIT=…` in `~/.config/caution/.env` and restart
`api` to confirm the override flows through. (See `caution-platform` for why these commits are
the deploy-time source of truth.)

## Running tests locally

Two tiers, run from the repo on the Linux amd64 host (the e2e tiers need Docker; on a
non-Linux workstation run them inside the Linux amd64 VM):

- **Unit tests** — `make test-unit` (`cargo test --workspace`). No Docker, no stack; just the
  Rust toolchain + native deps. Fast inner loop for service logic.
- **E2E suites** — `make test-e2e-*`. Each target builds the service images, stands up an
  **ephemeral** test Postgres (`postgres-test`, DB `caution_test`, dropped afterwards), runs all
  migrations, runs a `tests/e2e/*.sh` script against the live services, then tears everything down.
  Targets: `test-e2e` (happy-path/ports/env/ssh), `test-e2e-billing`, `test-e2e-billing-gates`,
  `test-e2e-legal`, `test-e2e-byoc`, `test-e2e-platform-ports`, `test-e2e-ssh-units`,
  `test-e2e-webauthn` (login/username-claim/QR).

The e2e stack needs two pieces of config the dev `up.sh` doesn't — both handled by
[`e2e.sh`](scripts/e2e.sh), the wrapper to use:

```bash
cd scripts && CAUTION_REPO=/path/to/platform ./e2e.sh                 # default: test-e2e-billing
cd scripts && CAUTION_REPO=/path/to/platform ./e2e.sh test-e2e-byoc   # any target
```

What it sets up (know it for debugging a raw `make test-e2e-*`):

1. **`INTERNAL_SERVICE_SECRET` must be non-empty** in `~/.config/caution/.env`. `env.example` ships
   it blank and the dev stack skips metering, but the e2e suites run metering — which **exits at
   boot** with `INTERNAL_SERVICE_SECRET must be set` if it's empty. `setup-config.sh` now fills any
   blank secret; symptom if missing is a Step 1 "metering not responding" failure.
2. **A repo-root `.env`** — `run-api-test` loads `--env-file .env` from the repo root *in addition*
   to `~/.config/caution/.env`. If it's absent the api container never starts
   (`docker: --env-file: open .env: no such file or directory`); `e2e.sh` stages it from
   `env.example`.

When authoring a gateway e2e that reuses a session across steps, know that **`/auth/e2e-login`
sessions are credential-bound**: the auth middleware resolves the user from their credential, so a
step that `DELETE`s a user's `fido2_credentials` (or otherwise removes the credential) invalidates
that user's `X-Session-ID` — every subsequent authed call with it returns **401**, not the status
you were testing for. Order credential-destroying steps last, or mint a fresh `/auth/e2e-login`
session afterward.

The e2e scripts use `set -euo pipefail`, so a single failed `curl`/`psql` aborts the whole run at
that step (the summary shows the steps that passed before it). When a run dies mid-suite, bring the
stack up without the auto-teardown to probe by hand:

```bash
make up-test-billing        # leaves services running; Gateway :8000, Metering :8083, postgres-test
docker logs metering        # panics/boot errors land here
make down-test-billing      # clean up when done
```

## Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `docker run` → `…cgroup…: Inappropriate ioctl for device` | dockerd on systemd cgroup driver in the LXC VM | Switch to `cgroupfs` + restart dockerd by hand (see cgroup wall) |
| `Unit caution-postgres.service not found` / `make up` fails | systemd units not installed in a fresh VM | Run containers directly / use the bundled `scripts/up.sh` |
| api exits: `DATABASE_URL must be set` / `prices.json not found` / `config.json not found` / `BUILDER_AMI_ID required` | missing boot config | Stage `~/.config/caution/.env` + `prices.json` + `config.json` with dummies |
| gateway exits: `CSRF_SECRET environment variable must be set` | missing secret | Add `CSRF_SECRET=…` to the env file |
| Endpoint `200` direct on `:8080` but `404` through `:8000` | gateway route registered under nested `/api`, or stale gateway image | Register root paths at the router root (not in the `/api` nest); rebuild `caution-gateway` |
| Footer/UI change not visible though gateway rebuilt | `frontend/dist` not rebuilt before the image | `npm run build` then `make build-gateway` |
| `caution-api`/`caution-gateway` missing from `docker images` | built on a different Docker engine than the one you're running against | Build and run on the same Linux host/engine |
| Component-pin QEMU smoke reports a stale STEVE commit | Old CLI binary, `STEVE_COMMIT` override, or cached EIF | Use the script without `--caution-bin`/`--override-steve-commit`; it builds the selected Platform checkout and forces `apps build --no-cache` |
| Component-pin QEMU smoke reaches Bootproof but reports missing NSM | Expected under QEMU; the production binary requires Nitro `/dev/nsm` | Treat this as the local hardware boundary, then run the separate synthetic STEVE E2E and retain real Nitro as the release gate |
| e2e Step 1: `metering not responding` / metering exits `INTERNAL_SERVICE_SECRET must be set` | secret blank in `~/.config/caution/.env` | Set a non-empty `INTERNAL_SERVICE_SECRET` (re-run `setup-config.sh` / use `e2e.sh`) |
| e2e: `docker: --env-file: open .env: no such file or directory` (`run-api-test`) | no repo-root `.env` | `cp env.example .env` in the repo (or use `e2e.sh`) |
| Toggling a flag in `~/.config/caution/.env` + `docker restart` has no effect | `docker restart` reuses the container's original env; `--env-file` is only read at `docker run` time | Edit the `.env`, then recreate the container (`up.sh`) — and `sed -i` the old line first to avoid duplicates |
