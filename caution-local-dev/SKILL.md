---
name: caution-local-dev
description: Use when running, building, or debugging the Caution platform itself locally (the api/gateway/frontend services + Postgres) on a Linux amd64 host or VM, as opposed to deploying a customer enclave app — e.g. bring up the dashboard, curl an API endpoint, generate an alpha/beta code to register, rebuild a service image, or fix a Docker cgroup-driver failure in a nested Linux VM. For authoring a Caution app config or deploying an enclave, use caution-platform instead.
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
means a Linux amd64 VM; any provider works (a cloud instance, Lima/UTM/Multipass, or an OrbStack
`ubuntu-amd64` machine). All commands below run **inside that Linux environment**; adapt how you
shell into it and how you reach `localhost:8000`/`:8080` (direct, SSH tunnel, or the VM's
forwarded ports) to your setup.

Two things to keep straight whatever you use:

- **The repo and the images must be on the same Docker engine.** Build (`make build-*`) and run on
  the same Linux host. If your VM tool exposes a *different* Docker engine than the one where you
  built (some do), `docker images` won't show `caution-api`/`caution-gateway` — point your commands
  at the engine that has them.
- **Port reachability is yours to arrange.** `curl http://localhost:8000/...` only works from where
  those ports are exposed; from another machine use the host's IP or a tunnel.

## ⚠️ The cgroup wall (fix this first)

In some nested/containerized Linux environments (notably LXC-based VMs, which OrbStack machines
are), dockerd defaults to the **systemd cgroup driver**, which is broken there. Every `docker run`
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
| `gen-alpha-code.sh` | Mint a registration code (see below). |

Override `CAUTION_CFG`, `CAUTION_NETWORK`, `CAUTION_DB_VOLUME`, `CAUTION_*_PORT`, etc. — see
`scripts/_common.sh`.

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

## Register / log in (alpha codes)

Registration is alpha-gated by the **`beta_codes`** table (note: table is `beta_codes`, flag is `--alpha-code`). Mint one with `scripts/gen-alpha-code.sh` (inserts a random code against the running DB).

Then register with a passkey — `RP_ID=localhost`, `RP_ORIGINS` includes `http://localhost:8000`, so Touch ID / platform passkeys work against `localhost`:

- **Dashboard:** open `http://localhost:8000`, register, paste the code, create passkey.
- **CLI:** `caution register --alpha-code <code>`.

A code is valid while `used_at IS NULL` and unexpired; redemption sets `used_at`.

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

## Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `docker run` → `…cgroup…: Inappropriate ioctl for device` | dockerd on systemd cgroup driver in the LXC VM | Switch to `cgroupfs` + restart dockerd by hand (see cgroup wall) |
| `Unit caution-postgres.service not found` / `make up` fails | systemd units not installed in a fresh VM | Run containers directly / use `~/caution-dev-up.sh` |
| api exits: `DATABASE_URL must be set` / `prices.json not found` / `config.json not found` / `BUILDER_AMI_ID required` | missing boot config | Stage `~/.config/caution/.env` + `prices.json` + `config.json` with dummies |
| gateway exits: `CSRF_SECRET environment variable must be set` | missing secret | Add `CSRF_SECRET=…` to the env file |
| Endpoint `200` direct on `:8080` but `404` through `:8000` | gateway route registered under nested `/api`, or stale gateway image | Register root paths at the router root (not in the `/api` nest); rebuild `caution-gateway` |
| Footer/UI change not visible though gateway rebuilt | `frontend/dist` not rebuilt before the image | `npm run build` then `make build-gateway` |
| `caution-api`/`caution-gateway` missing from `docker images` | built on a different Docker engine than the one you're running against | Build and run on the same Linux host/engine |
