---
name: caution-platform
description: Use when writing a Caution app config (caution.hcl, or the legacy Procfile), or deploying, debugging, or testing Caution enclave apps — locally with QEMU (on a Linux host, or inside a Linux amd64 VM on macOS), or on AWS Nitro (health check failures, attestation errors, vsock issues, SSH debug mode, nitro-cli, service logs). Covers the full CLI surface, deploy flow (git push caution main), BYOC provisioning, Locksmith secret management, STEVE end-to-end encryption, and PCR verification.
---

# Caution Platform

## Source Of Truth

Prefer current primary sources over memory:

- Caution docs: `https://docs.caution.co/`
- Caution reference: `https://docs.caution.co/reference`
- Caution caution.hcl reference: `https://docs.caution.co/reference/caution-hcl/`
- Caution Procfile reference (legacy): `https://docs.caution.co/reference/procfile/`
- Caution containerizing guide: `https://docs.caution.co/guides/containerize-an-application/`
- Caution debugging guide: `https://docs.caution.co/reference/debugging/`
- Caution key services guide: `https://docs.caution.co/concepts/key-services/`
- Caution platform source: `https://codeberg.org/caution/platform`
- Locksmith source: `https://codeberg.org/caution/locksmith`
- STEVE source: `https://git.distrust.co/public/steve`
- EnclaveOS source: `https://git.distrust.co/public/enclaveos`
- Keyfork source: `https://git.distrust.co/public/keyfork`

## Overview

Caution is a general-purpose, verifiable confidential compute platform for deploying sensitive workloads inside secure enclaves. Built by Distrust, fully open source on Codeberg (`https://codeberg.org/caution`). Dashboard at `dashboard.caution.co`, website at `caution.co`.

Its core differentiator: it connects running enclave measurements back to the **intended source code and build inputs** that produced the enclave image, then lets any independent party verify it. This moves sensitive cloud services from "trust us" to "verify it yourself."

Currently supports **AWS Nitro Enclaves**. Multi-hardware attestation (Intel TDX, AMD SEV-SNP, TPM 2.0) is on the 2026 roadmap, being delivered via **EnclaveOS** — requiring multiple attestation technologies to agree on workload state, distributing trust across hardware vendors.

Four combined security properties: Isolation, Verifiability, Reproducibility, End-to-end encryption. Grounded in the Distrust Threat Model (`distrust.co/threatmodel.html`), which assumes systems may already be compromised at some level.

Caution runs apps inside AWS Nitro Enclaves. The enclave boots a custom Linux kernel (`linux-nitro`) with a rootfs built by `caution apps build`, served via `eif_build`. Local debugging uses QEMU to boot the same rootfs with a swapped kernel.

Two files define a Caution app:

- **`Containerfile`** — the reproducible build recipe. Authored with the `stagex-reproducible-builds` skill.
- **`caution.hcl`** — tells Caution how to run the resulting image. Covered below. (A legacy key-value **`Procfile`** is still accepted as a fallback; `caution.hcl` wins when both are present. Convert with `caution apps migrate-procfile [--procfile <path>] [--output <path>] [--force]`.)

## CLI command surface

Verified against the `caution` CLI (subcommands: `register`, `login`, `logout`, `init`, `teardown`, `verify`, `apps`, `ssh-keys`, `cache`, `credentials`, `secret`). There is **no `deploy` subcommand** — don't invent it. `apps` has exactly: `create`, `list`, `get`, `destroy`, `build`, `rename`, `download-eif`, `migrate-procfile`. Deployment is triggered by `git push caution main` (a git remote named `caution`), not by any CLI subcommand.

### Deploy flow

From a repo containing a `caution.hcl` + `Containerfile`:

```bash
caution register --alpha-code <your_code>   # first time only; alpha-gated, FIDO2/WebAuthn passkey
caution login                                # subsequent sessions — FIDO2/WebAuthn, interactive
caution ssh-keys add --from-agent            # add an SSH key for deployment auth
caution init                                 # initialize the deployment in the cwd; writes caution.hcl + .caution/deployment.json
# (optional) caution apps build              # local inspection only — build the EIF to inspect / QEMU-debug it; does NOT deploy
git push caution main                        # DEPLOY: push to the `caution` git remote; Caution builds & deploys
caution verify                                # reproduce & compare PCRs
```

Key points:
- **Deploy is `git push caution main`** — Caution manages a git remote named `caution`. The push triggers Caution to build a reproducible enclave image (standard `docker build -f <containerfile> .` from the repo root) and deploy it into the enclave.
- `caution init` creates the `caution.hcl` (if absent) and `.caution/deployment.json` (app resource ID, needed for CLI to target the right app). **Commit both to your repository.** To convert an existing legacy `Procfile`, run `caution apps migrate-procfile` (`--procfile <path>` to specify a non-default input, `--output <path>` to write elsewhere, `--force` to overwrite an existing `caution.hcl`).
- **`caution init` validates `caution.hcl` locally before any network call** (verified against `src/cli/src/lib.rs`: `init()` calls `read_config()` at line ~4023, which is the same `caution_config::ConfigurationFile::from_str` the API runs server-side at deploy time; an explicit `containerfile` path is also re-checked locally in `resolve_local_build_command_from_dir`, lib.rs:7817-7830). So bad HCL syntax, a port in the reserved `49500`–`49600` range, an invalid env key/expression, or a missing explicit `containerfile` all fail **at `caution init`**, before any resource is created or anything is pushed — not just at `git push`. The API repeats the same checks server-side (`load_build_config_for_deploy` in `src/api/src/main.rs`) as defense-in-depth, e.g. if a push bypasses the CLI. If you're debugging "why did `caution init` reject my config," the error is the exact same one the deploy path would give — no need to push just to see it.
  - **`migrate-procfile` output needs manual review** (verified against `caution-config::from_procfile` + the deploy path in `api/src/main.rs:2059`):
    1. **Env-prefix in `run:` is split across `command` and `args`.** `migrate-procfile` shlex-splits `run:` and takes the first token as `command`, so `run: FOO=1 /usr/bin/app` becomes `command = "FOO=1"`, `args = ["/usr/bin/app"]`. This is handled correctly by the platform: leading `NAME=value` tokens in `command` are treated as inline env assignments, so the result runs `FOO=1 /usr/bin/app` as expected. Review the output to confirm the split looks right.
    2. **`locksmith: true` is dropped without warning.** This is expected — HCL has no `locksmith` field (it's implied by `env::vault`), and the Procfile doesn't say which secrets to vault, so the migrator can't synthesize the `env::vault(...)` entries. But it emits no warning. Re-add Locksmith by hand: reference each secret with `env::vault("NAME")` in the unit `env` map (any `env::vault` enables Locksmith — see Secrets below).
- `caution apps build` is **local inspection only** (build the enclave image to look at it / QEMU-debug it). It is not a deploy step.
- `caution apps create` creates the app record on Caution (done during `caution init`); it is not the deploy mechanism itself.
- These commands are **interactive** (FIDO2/WebAuthn signing) — wrapping them in a Makefile/CI adds little and can't be fully automated. Keep ops Makefiles to local build/test/reproducibility (`go build`, `vite build`, the two-build `cmp` repro check) and run the `caution` commands directly.
- **Commit** `.caution/deployment.json` (app resource ID, needed for CLI to target the right app), `.caution/quorum-bundle.json`, and `.caution/secrets/*.asc`. **Do not commit** plaintext inputs (`.env`) or generated private keyrings (e.g. `alice.private.asc`). Build output (EIF files) should remain gitignored.
- **Alpha access**: registration requires an access code: `caution register --alpha-code <your_code>`. Request one at `info@caution.co`. Passkey required (browser/platform/password-manager/YubiKey/NitroKey/LibremKey).
- **Platform support**: CLI runs on Linux (x86_64) or macOS (arm64). On macOS Apple Silicon, enable Rosetta in Docker Desktop for `caution verify` (x86_64/amd64 emulation).

### Deploy is per-branch — keep `caution.hcl` + `Containerfile` at the repo root

Caution deploys a **specific git branch** (it reports e.g. `Deploying branch 'main' at <sha>`) and looks for a **root `caution.hcl`** (or legacy `Procfile`) on *that* branch. Two consequences that bite in practice:

- **Put both files at the repo root**, not in a subdir. The `caution.hcl` *must* be at the root. The `Containerfile` is best at the root too: omit the `containerfile` field and let Caution auto-detect a root `Containerfile` (before `Dockerfile`). A subpath like `containerfile = "deploy/Containerfile"` is supported but more fragile — root + auto-detect is the reliable convention. The Docker build context is the repo root regardless, so a root `Containerfile` can still `COPY deploy/ ...`.
- **Deploy the branch that actually carries these files.** Pushing a branch without them (e.g. a bare `main` while the work lives on a feature branch) fails with `No configuration file found in repository root. Add a 'caution.hcl' file or a 'Procfile' with a required 'run:' field.`. Either merge the feature branch to the deployed branch first, or push the feature branch to the deploy ref (`git push caution <feature>:main`).

## caution.hcl

`caution.hcl` is an [HCL](https://github.com/hashicorp/hcl) file at the repo root. It tells Caution how to run the app, which build recipe to use, and what to publish for verification. The Containerfile builds the image; `caution.hcl` launches it.

It has an optional top-level `caution { }` block (account/provider settings) and **exactly one** `enclave "<name>" { }` block (multiple enclaves → `Multiple enclaves defined; only one enclave is supported`). The enclave holds `build`, `resources`, `network`, `debug`, and one or more `unit` blocks:

```hcl
caution {
  # account / provider settings (optional)
}

enclave "main" {
  build     { }        # what to build
  resources { }        # cpu / memory
  network   { }        # ingress, egress, http
  debug     { }        # debug + ssh access
  unit "default" { }   # the command to run (required)
}
```

### Required: the `default` unit

The `unit "default"` block is **required** — Caution runs the command from the unit literally named `default` (the API does `units.get("default")`; a unit with any other name is ignored for startup, so `unit "main"` will NOT start). Use an absolute path matching the image (an `ENTRYPOINT ["/app/server"]` pairs with `command = "/app/server"`).

```hcl
unit "default" {
  command = "/app/server"
  args    = ["--port", "8080"]
  env     = { LOG_LEVEL = "info" }
}
```

- `command` — **required**. Executed by the enclave via `sh -c '<command>'`, so it can be a full shell string (`"FOO=1 /app/server --port 8080"`), not just a bare binary path.
- `args` — list of arguments. Joined with `command` and shell-quoted into the final `sh -c` string by `caution-config`. A leading run of `NAME=value` tokens in `command` is treated as inline env assignments and emitted verbatim (value shlex-quoted), so `command = "FOO=1"` + `args = ["/app/server"]` correctly produces `FOO=1 /app/server`.
- `env` — map of env vars. Values must be string literals or function calls; anything else errors with `Invalid env expression for key '<K>'; only string literals and function calls are allowed`. **⚠️ Plain `env` literals are currently NOT injected** — the map is only scanned by `has_vault_env()` to enable Locksmith. The only env that reaches the app is what `locksmith-oneshot` exports from `/etc/caution/secrets/*.asc`. So: use `env::vault("NAME")` for secrets (works, via Locksmith), but set non-secret env vars as an inline prefix in `command` (e.g. `command = "LOG_LEVEL=info /app/server"`).

### `build` — choosing the container input

```hcl
build {
  containerfile = "deploy/Containerfile"
  app_sources   = ["https://codeberg.org/example/api"]
  cache         = true
}
```

| Field | Use when |
|---|---|
| `containerfile` | You build from a Containerfile/Dockerfile (most common). Path relative to repo root. Defaults to `Containerfile`/`Dockerfile` at the root if omitted. |
| `binary` | Only for a fully self-contained static binary with no config files, shared libraries, or other filesystem deps. Unsuitable for most apps. **Incompatible with secrets** — `binary` extracts only the named file and discards the rest of the image, so the `/etc/caution/bundle.json` you `ADD`ed never reaches the EIF rootfs and `locksmithd` panics. Omit `binary` (use `containerfile`) when using Locksmith. |
| `app_sources` | List of git URLs for application source verification, embedded in the attestation manifest. |
| `cache` | Defaults `true`; set `false` to disable the docker build cache. |

Caution builds with `docker build -f <containerfile> .` from the repo root. There is no custom build command and no extra docker build args — put all build logic in the Containerfile. (HCL has no `oci_tarball`, `enclave_sources`, or `metadata` field; those were legacy Procfile keys.)

### `network` — ports, traffic, and TLS

`network` holds repeatable `ingress`/`egress` rules and an optional `http` block. Each port the app exposes needs an `ingress` rule. Do **not** use the reserved `49500`–`49600` range (`Ports 49500-49600 are reserved; choose a different application port.`).

```hcl
network {
  ingress {
    cidr_ipv4   = "0.0.0.0/0"
    port        = 8080
    ip_protocol = "tcp"
  }
  ingress {
    cidr_ipv4  = "0.0.0.0/0"
    start_port = 40000
    end_port   = 40005
  }
  egress { cidr_ipv4 = "0.0.0.0/0" }

  http {
    domain = "api.example.com"
    port   = 8080
  }
}
```

- `ingress`/`egress` — `cidr_ipv4` (required), then either a single `port` or a `start_port`/`end_port` range, plus optional `ip_protocol`.
- `http` — fronts one `port` with Caddy for TLS on 443; pair with `domain`. **The `http` port must be covered by an `ingress` rule**, else `http_port X must also be present in ingress rules`. Any non-`http` ingress port is exposed as raw TCP (P2P, binary protocols).

### `resources`

```hcl
resources {
  cpu       = 2     # vCPUs, default 2
  memory_mb = 512   # MB, default 512
}
```

### Features

- **End-to-end encryption** — add an `e2e_encryption` block inside `http`. Encryption via **STEVE** (Secure Transport Encryption via Enclave), a transparent proxy with an SDK that verifies the attested key and encrypts so data is only exposed in the client and inside the enclave. Runs on reserved port 49500 for `/e2p/*` traffic. TLS is complementary (transport/domain trust), not a replacement — terminating TLS outside the enclave defeats the purpose. See `https://git.distrust.co/public/steve`.

  ```hcl
  http {
    domain = "secure.example.com"
    port   = 8080
    e2e_encryption {
      enabled      = true
      cors_origins = ["*"]
    }
  }
  ```

- **Secrets (Locksmith)** — reference a managed secret with `env::vault("NAME")` in a unit's `env` map. **Using `env::vault` anywhere automatically enables Locksmith — there is no separate flag.** Prefer this over baking secrets into the image. **The app image must include `/etc/caution/bundle.json`** (the quorum bundle from `caution secret new`, stored at `.caution/quorum-bundle.json`) and `/etc/caution/secrets/*.asc` — `locksmithd` reads the bundle at startup and panics with `No such file or directory` if absent. `ADD` them explicitly: `ADD .caution/quorum-bundle.json /etc/caution/bundle.json` and `ADD .caution/secrets/ /etc/caution/secrets/`. **Do not set `binary`** — it strips `/etc/caution/`, so locksmithd still panics. Build from the full `containerfile` image; a `scratch` image with the static binary + bundle + encrypted secrets stays minimal and lets PCR2 measure the bundle. Locksmithd listens on reserved port 49504 for shard submissions.

  ```hcl
  unit "default" {
    command = "/app/server"
    env = {
      DATABASE_URL = env::vault("DATABASE_URL")
    }
  }
  ```

- **Debug** — a `debug { enabled = true }` block enables debug mode (zeros PCR values, breaks `caution verify`; remove before production). `ssh_keys` is a list of full OpenSSH public keys for host access (opens port 22; debug only). See Production Debugging.

  ```hcl
  debug {
    enabled  = true
    ssh_keys = ["ssh-ed25519 AAAA... you@host"]
  }
  ```

### Reserved ports (49500–49600)

User apps must not declare ports in the `49500`–`49600` range in `ingress`, `egress`, `http`, or application startup commands.

| Port | Service |
|------|---------|
| 49500 | STEVE proxy for `/e2p/*` traffic (when e2e encryption is enabled) |
| 49501 | Auxiliary internal proxy slot |
| 49502 | bootproofd internal attestation service, proxied to the public `/attestation` path |
| 49504 | Locksmith shard receiver (when secrets are used) |

The public attestation endpoint is the deployment's app URL plus `/attestation`; do not add `:49502` unless your operator explicitly exposes that internal port.

### BYOC (bring your own compute)

Set a `provider` block inside the top-level `caution { }` block:

```hcl
caution {
  machine_type       = "m5.xlarge"   # optional host instance type
  build_machine_type = "m5.xlarge"   # optional builder instance type
  provider {
    type              = "aws"
    region            = "us-east-1"
    vpc_id            = "vpc-..."        # optional
    subnet_ids        = ["subnet-..."]   # optional
    security_group_id = "sg-..."         # optional
  }
}
```

`provider.type` is currently `aws`. Top-level `managed_credentials` points to a managed credentials file.

#### BYOC provisioning

Two paths to set up BYOC:

**CLI-guided (recommended):**
```bash
caution init --byoc    # provisions AWS infra + registers scoped deployment credentials automatically
```

**Manual provisioning:**
```bash
git clone https://codeberg.org/caution/bring-your-own-cloud-setup.git
cd bring-your-own-cloud-setup
cp .env.example .env   # edit with AWS credentials
docker build -t caution-provisioner-setup .
docker run --rm --env-file .env -v "$(pwd)/out:/out" caution-provisioner-setup
# produces credentials.json.gpg in out/
caution init --byoc --config /path/to/credentials.json.gpg
```

For an existing VPC, set `VPC_ID=vpc-xxxxxxxx` in `.env` before running the Docker command.

The setup creates: a dedicated `/16` VPC with IGW/routing, S3 bucket (`caution-<deployment-id>-images`), EC2 instance role (read EIFs), builder role (publish EIFs), launch template, Auto Scaling Group (starts at 0), and a scoped IAM user with tag-based resource policies.

Instance types: m5.xlarge/2xlarge/4xlarge/8xlarge (host reserves ~2 vCPUs, ~2 GB).

#### BYOC teardown

```bash
caution teardown --byoc    # tears down BYOC deployment from the CLI
```

Run from your application directory (or ensure local BYOC state exists in `~/.caution/<app>/bring-your-own-cloud.json`) with AWS credentials available.

### Examples

Web app fronted with TLS:
```hcl
enclave "main" {
  build {
    containerfile = "deploy/Containerfile"
    app_sources   = ["https://codeberg.org/example/api"]
  }
  network {
    ingress {
      cidr_ipv4 = "0.0.0.0/0"
      port      = 3000
    }
    http {
      domain = "api.example.com"
      port   = 3000
    }
  }
  unit "default" {
    command = "/app/server"
  }
}
```

Multi-port node passing CLI flags (8232 fronted with TLS, 8233 raw TCP):
```hcl
enclave "main" {
  network {
    ingress {
      cidr_ipv4 = "0.0.0.0/0"
      port      = 8232
    }
    ingress {
      cidr_ipv4 = "0.0.0.0/0"
      port      = 8233
    }
    http {
      domain = "node.example.com"
      port   = 8232
    }
  }
  unit "default" {
    command = "/app/server"
    args    = ["--rpc-port", "8232", "--p2p-port", "8233"]
  }
}
```

Secret management with custom resources (`env::vault` auto-enables Locksmith):
```hcl
enclave "main" {
  resources {
    cpu       = 4
    memory_mb = 4096
  }
  network {
    ingress {
      cidr_ipv4 = "0.0.0.0/0"
      port      = 3000
    }
    http {
      domain = "secrets.example.com"
      port   = 3000
    }
  }
  unit "default" {
    command = "/app/server"
    args    = ["--port", "3000"]
    env = {
      DATABASE_URL = env::vault("DATABASE_URL")
    }
  }
}
```

## Local Debugging with QEMU

### Environment

Local debugging boots the same rootfs under QEMU. You need a Linux environment with Docker and `qemu-system-x86_64`:

- **Linux (amd64):** run everything directly on the host.
- **macOS (any chip):** Docker and x86_64 acceleration aren't native here. Run the whole flow inside a Linux **amd64** VM you have access to — Lima, UTM, OrbStack, Multipass, a cloud instance, or any amd64 Linux box. An amd64 VM keeps the StageX images (amd64-only) and the standard x86_64 kernel native, avoiding cross-architecture emulation.

Build (`caution apps build`), fetch the kernel, and boot QEMU inside that Linux environment. Reach forwarded ports at `localhost` when you run `curl` from inside it, or at the VM's hostname/IP from your host machine.

### Getting the kernels

Two kernel modes depending on what you need.

**Nitro bzImage** — logs only, no networking (kernel has no virtio-net or vsock drivers):
```bash
docker create --name tmp-kernel \
  stagex/user-linux-nitro@sha256:aa1006d91a7265b33b86160031daad2fdf54ec2663ed5ccbd312567cc9beff2c
docker cp tmp-kernel:/bzImage ./bzImage
docker rm tmp-kernel
```
The digest is pinned in your `Containerfile.eif` — prefer that one over this example.

**Standard x86_64 kernel** — enables networking and port access (needed to test HTTP endpoints):
```bash
docker run --rm -v "$(pwd):/out" ubuntu:24.04 \
  bash -c "apt-get update -q && apt-get install -y linux-image-generic \
    && chmod 644 /boot/vmlinuz-* \
    && cp /boot/vmlinuz-*-generic /out/vmlinuz-amd64"
```
On an amd64 host or VM this runs natively. If you must build it on an arm64 host, add `--platform linux/amd64` to the `docker run` (and note that `apt-get download linux-image-generic:amd64` won't work on arm64 unless amd64 is added first with `dpkg --add-architecture amd64`).

### Getting the rootfs

After `caution apps build`, the rootfs is at `eif-stage/output/rootfs.cpio.gz` in the app directory (also cached under `~/.cache/caution/build/.../`). Pass this as `-initrd` — never pass the `.eif` directly.

### QEMU commands

**Logs only (Nitro kernel):**
```bash
qemu-system-x86_64 \
  -m 512M -nographic \
  -kernel ./bzImage \
  -initrd ./eif-stage/output/rootfs.cpio.gz \
  -append "console=ttyS0 reboot=k panic=1 nomodules nit.target=/run.sh"
```

**With networking (standard kernel) — adjust ports to match `caution.hcl`:**
```bash
qemu-system-x86_64 \
  -m 512M -nographic \
  -kernel ./vmlinuz-amd64 \
  -initrd ./eif-stage/output/rootfs.cpio.gz \
  -append "console=ttyS0 reboot=k panic=1 nomodules nit.target=/run.sh" \
  -netdev user,id=net0,hostfwd=tcp:0.0.0.0:8083-:8083,hostfwd=tcp:0.0.0.0:49502-:49502 \
  -device virtio-net-pci,netdev=net0
```

The `hostfwd` ports must match the `ingress` ports in your `caution.hcl` (plus the attestation port).

**Do NOT include `pci=off` in `-append`** — it disables PCI and breaks virtio-net.

### Testing endpoints

Run these from inside the Linux environment (use `localhost`); from your host machine, replace `localhost` with the VM's hostname or IP.

```bash
# App
curl http://localhost:8083/

# Attestation — nonce is base64-encoded 32 bytes
curl -X POST http://localhost:49502/attestation \
  -H "Content-Type: application/json" \
  -d '{"nonce": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}'
```

Expected attestation response locally (correct behavior — NSM not available in QEMU):
```json
{"errors":["unable to get nonced attestation: AttestationGeneration (...)","could not initialize the NSM driver"]}
```

Any other error before NSM indicates a real problem.

### Local limitations

| Feature | Local QEMU | Production |
|---|---|---|
| App starts, logs visible | Yes | Yes |
| Networking / port access | Standard kernel only | Yes (vsock tunnel) |
| NSM / attestation document | No | Yes |
| VSock proxies | No (AF_VSOCK absent in std kernel) | Yes |
| PCR measurements | No | Yes |

Expected warnings in logs — not errors:
- `socat: TUNSETIFF {"eth0"}: Invalid argument` — vsock TUN creation failed, but virtio-net eth0 still comes up
- `open("/dev/vsock"): No such file or directory` — standard kernel has no vsock
- `WARNING: NSM module not found at /nsm.ko` — expected, no hardware

## Production Debugging

### Enable debug mode

Add a `debug` block to the enclave before deploying (`git push caution main`):
```hcl
debug {
  enabled  = true
  ssh_keys = ["ssh-ed25519 AAAA... you@host"]
}
```

**Remove the whole block before production** — debug mode zeros PCR values (breaks `caution verify`) and SSH opens port 22.

### SSH and read enclave logs

```bash
ssh ec2-user@<instance-ip>

ENCLAVE_ID=$(nitro-cli describe-enclaves | grep -o '"EnclaveID": "[^"]*"' | cut -d'"' -f4)
nitro-cli console --enclave-id "$ENCLAVE_ID"
```

### Key host-side service logs

```bash
journalctl -u nitro-enclave.service --no-pager -n 100   # enclave lifecycle
systemctl status vsock-proxy-<port>.service              # per-port vsock bridge
systemctl status vsock-network.service                   # enclave internet access tunnel
journalctl -u caddy.service --no-pager -n 50             # TLS termination
cat /var/log/nitro_enclaves/nitro_enclaves.log           # nitro-cli errors
cat /var/log/user-data.log                               # full boot + provisioning log
```

## caution verify and PCR Debugging

`caution verify --attestation-url <url>` fetches the live attestation manifest, re-downloads the app source at the **declared commit**, rebuilds the EIF, and compares PCR0/PCR1 against the attestation. A mismatch means the reproduced build differs from the deployed one.

### What the attestation manifest does and does NOT contain

The `EnclaveManifest` embedded in the attestation records:
- `app_source` — URL, commit SHA, branch
- `enclave_source`, `framework_source` — with pinned commits
- `run_command`, `enclaveos_commit`, `bootproof_commit`, `steve_commit` (and `locksmith_commit` when secrets are used)

It does **not** store the `network` ports or e2e setting. During verification, `caution verify` re-reads the app source's `caution.hcl` (or legacy `Procfile`) at the declared commit to recover these values — they drive `run.sh` generation (STEVE inclusion, VSOCK port proxies). If the re-read is skipped or wrong, `run.sh` differs → PCR mismatch.

### The tool commits (`*_COMMIT`) are the authoritative reproduction inputs — read them from the manifest, not from your CLI

The four tool commits (`enclaveos_commit`, `bootproof_commit`, `steve_commit`, `locksmith_commit`) are git refs the enclave **clones and builds at image-build time** (e.g. `Containerfile.eif` does `git clone bootproof && git checkout {{BOOTPROOF_COMMIT}}`). They directly feed PCR0/PCR1. Each is resolved with this precedence:

1. the value pinned in the build's `manifest.json`
2. the `ENCLAVEOS_COMMIT` / `BOOTPROOF_COMMIT` / `STEVE_COMMIT` / `LOCKSMITH_COMMIT` env var
3. a `DEFAULT_*_COMMIT` constant compiled into the CLI/builder (`enclave-builder/src/build.rs`)

**`caution verify` reproduces correctly because it pulls these commits from the deployed enclave's attestation manifest (path 1).** A bare `caution apps build` has no manifest, so it falls back to the **compiled-in defaults (path 3)** — which can be *stale relative to what production deployed*. The platform's `Cargo.lock` (the tool *libraries* linked into the CLI) and the `DEFAULT_*_COMMIT` constants (the tool *binaries* built into the enclave) are two independent things and **drift apart**: a dep bump can move Cargo.lock forward while the `DEFAULT_*_COMMIT` constant lags. So you cannot read "what commit is deployed" off the CLI source tree — neither file is a reliable source of truth.

**To see what a *platform* currently pins, GET its public `build-inputs` endpoint** — for the managed platform, `https://dashboard.caution.co/.well-known/caution/build-inputs` (any deployment exposes `/.well-known/caution/build-inputs`). It's an unauthenticated GET returning that platform's resolved `platform` + `enclaveos`/`bootproof`/`steve`/`locksmith` commits — i.e. the refs it will build **new** enclaves from right now (the env-var/`DEFAULT_*_COMMIT` resolution as the server sees it). Use it as the quick first debugging check: compare these against your CLI's compiled-in defaults to spot drift *before* deploying, or against an app's attestation manifest to see if it was built with the platform's current pins. It is **not** app-specific and is the platform's own claim, not attested — for a specific deployed app the live attestation manifest below is still the source of truth.

**The source of truth for a deployed app is its live attestation manifest** — the same data `caution verify` consumes. The `/attestation` endpoint is a **POST** (it takes a challenge nonce) and returns JSON with two relevant fields: `attestation_document` (base64 COSE_Sign1, holds the PCRs) and `manifest` (plain JSON `EnclaveManifest`, holds the tool commits). The commits are in `.manifest`, **not** inside the COSE document.

**Trust note — the manifest is unsigned.** Only the `attestation_document` (PCRs) is signed by the Nitro NSM. The sibling `manifest` field is an **unsigned claim** about which commits/source produced the enclave; a malicious or buggy host could serve commits that don't match the running image. The manifest becomes trustworthy only via the reproduction loop: rebuild from its declared commits and confirm the result matches the **signed** PCR0/PCR1. That is exactly what `caution verify` does — so trust verify's pass/fail, not the raw manifest values. When you read `.manifest` directly (e.g. the env-var route below), treat the commits as a *hint for reproduction*, not as attested fact.

To reproduce a deployed PCR with `caution apps build` (e.g. to inspect or QEMU-debug the exact deployed image), read the commits from the manifest, then pass them as env vars:

```bash
# Fetch the deployed manifest and read the tool commits (nonce is base64 of 32 bytes)
curl -s -X POST https://<app-url>/attestation \
  -H 'Content-Type: application/json' \
  -d '{"nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}' \
  | jq '.manifest | {enclaveos_commit, bootproof_commit, steve_commit, locksmith_commit}'

# Reproduce locally with those exact commits (don't rely on the CLI's compiled-in defaults)
BOOTPROOF_COMMIT=<from-manifest> \
ENCLAVEOS_COMMIT=<from-manifest> \
STEVE_COMMIT=<from-manifest> \
LOCKSMITH_COMMIT=<from-manifest> \
  caution apps build --no-cache
```

(The simplest path is still `caution verify`, which does all of this for you. Use the manual env-var route only when you specifically need `apps build` artifacts — a local EIF/rootfs to inspect or boot under QEMU — for the exact deployed image.) If a fresh `caution apps build` yields a PCR0/PCR1 that doesn't match production but `caution verify` passes, this drift is the likely cause: verify used the manifest's commits, your build used stale defaults. (`PCR2` is the app layer and is unaffected by the tool commits.)

### PCR mismatch — ordered diagnosis

1. **Wrong dev branch / wrong CLI build.** Ensure the CLI was built from the correct branch. If using Docker-based `make install-cli`, add `NO_CACHE=--no-cache` to force a rebuild from source.
2. **`run.sh` is wrong.** Inspect the cached `run.sh`: `cat ~/.cache/caution/reproductions/local/<app_commit>/eif-stage/run.sh`. Confirm it has the STEVE block and correct VSOCK port proxies matching the deployed app's `caution.hcl`. If not, the ports/e2e re-read from the config isn't working.
3. **Deployed enclave was built from a different commit** than what the manifest declares. The manifest's `app_source.commit` may be stale — the deploy may have used a different branch state, a force-push, or a rebuild without updating the manifest. Try building from nearby commits on the same branch to find the actual source that matches the deployed PCR.
4. **Non-deterministic user app build.** If the app Containerfile runs `npm install && npm run build` without `SOURCE_DATE_EPOCH=1`, or fetches mutable content, the output differs between builds. See the `stagex-reproducible-builds` skill for remediation.
5. **A `COPY`ed file's mode tracks the build host's umask.** Git records only the exec bit, so a committed non-exec file's checked-out mode is `0666 & ~umask` (0644 on a umask-022 host like macOS, 0664 on a umask-002 Linux builder). Docker `COPY` preserves that mode into the initramfs, so the deployed enclave (built on Caution's Linux builder) and a local repro can differ by a single permission bit — changing PCR0/PCR1 while every file's *content* is identical. This is the subtlest cause and survives `cache=false`, a clean rebuild, and matching commits. (Exposed by `enclave-builder` commit `0667439`, which replaced a umask-normalizing `RUN cp -r` with a mode-preserving `COPY app/ /build/initramfs/` — so the app image's modes are now measured verbatim.) **Fix in the app Containerfile by setting the mode in-container, not with `COPY --chmod`:** `COPY file /tmp/x` + `RUN chmod 0644 /tmp/x`, then `COPY --from=build /tmp/x /dest`. Avoid `COPY --chmod=0644 file /dest` — `--chmod` also rewrites the auto-created parent dirs (`/etc`, `/etc/pq`) to `0644`, dropping their `x` bit; the enclave runs (root ignores it) but `caution verify` then crashes extracting the app tar as non-root: `failed to unpack etc/hostname … Permission denied`. The EIF comparison below is what surfaces the original mode diff.

### EIF filesystem comparison (deeper diagnosis)

When the ordered steps above don't identify the cause, compare the **ramdisk cpio archives** of the local repro and the deployed EIF. Two non-obvious traps make the naive approach miss things:

- **The ramdisk is not "the second gzip stream," and not the biggest.** A Nitro EIF contains the kernel (bzImage, internally gzip-compressed — usually the *largest* gzip stream) plus the ramdisk (a `newc` cpio, gzip-compressed). Identify the ramdisk by the cpio magic `070701`, not by size or order. `binwalk` is often not installed; a short Python scan is more reliable.
- **Compare the cpio *archives*, never the *extracted trees*.** `cpio -idm` recreates files applying the local umask, which **erases mode differences** (both sides normalize to 0644) — exactly the bit you're hunting. Run `diffoscope` / `cmp` / `cpio -tv` on the `.cpio` files directly.

```bash
caution apps build               # local repro: eif-stage/output/{enclave.eif,rootfs.cpio.gz}
caution apps download-eif        # deployed EIF (filename shown in output)

# Carve the ramdisk cpio from each EIF: scan gzip streams, keep the one whose
# decompression starts with cpio newc magic 070701 (skip the larger = kernel).
python3 - deployed.eif deployed.cpio <<'PY'
import sys, zlib
d=open(sys.argv[1],'rb').read(); i=0; best=None
while True:
    j=d.find(b'\x1f\x8b\x08',i)
    if j<0: break
    try:
        o=zlib.decompressobj(32+zlib.MAX_WBITS); out=o.decompress(d[j:])+o.flush()
        if out[:6]==b'070701' and (best is None or len(out)>len(best)): best=out
    except Exception: pass
    i=j+3
open(sys.argv[2],'wb').write(best); print(len(best),'bytes')
PY
gzip -dc eif-stage/output/rootfs.cpio.gz > repro.cpio   # macOS: use gzip -dc, not zcat

# Best finish: diffoscope on the archives (parses newc headers, reports per-member
# mode/owner/mtime AND content):
diffoscope deployed.cpio repro.cpio

# Manual ladder if diffoscope is unavailable — narrows to the exact field:
cmp deployed.cpio repro.cpio                                  # same size + one diff point => metadata, not content
diff <(cpio -tv < deployed.cpio) <(cpio -tv < repro.cpio)     # per-file mode/owner/size/mtime/name
```

### Cache paths for debugging

```
~/.cache/caution/downloads/{sha256_of_url}/          # downloaded app source
~/.cache/caution/reproductions/local/{app_commit}/   # EIF reproduction
~/.cache/caution/reproductions/local/{app_commit}/eif-stage/run.sh       # inspect this
~/.cache/caution/reproductions/local/{app_commit}/eif-stage/manifest.json
```

Clear the reproduction cache to force a full rebuild:
```bash
rm -rf ~/.cache/caution/reproductions/local/<app_commit>/
```

## Locksmith (`caution secret`)

Caution's secret management uses Shamir secret sharing: a master secret is split into shards encrypted to OpenPGP keys, with a configurable quorum threshold. Shard-holders independently send shards to the enclave; once the threshold is met, the enclave reconstructs the secret and derives cryptographic keys.

### Components

- **Keymaker** — setup-time component that generates the quorum (master secret split into shards). Deployed from the Locksmith repo (`https://codeberg.org/caution/locksmith`). Health check: `$KEYMAKER_URL/health` returns `{"service":"keymaker","status":"ok"}`.
- **Locksmithd** — runs inside the enclave at startup on reserved port **49504**. Reads `/etc/caution/bundle.json`, verifies signed shards via Nitro attestation, reconstructs the master secret, then starts **keyforkd** (key derivation daemon).
- **Locksmith-oneshot** — after keyforkd starts, runs once to derive an OpenPGP key, decrypt all `.asc` files in `/etc/caution/secrets/`, and output `export KEY=value` statements. The enclave startup script sources this: `source <(/usr/bin/locksmith-oneshot)`.

### Deploying Keymaker

```bash
git clone https://codeberg.org/caution/locksmith
cd locksmith
caution init
git push caution main
```

After deployment, set `KEYMAKER_URL` to the deployed Locksmith application URL.

### Generating a quorum (`caution secret new`)

`caution secret new keyring.asc --threshold N --max M` calls the keymaker service to mint a quorum bundle. It requires each OpenPGP certificate in the keyring to have a **signing subkey**, an **encryption subkey**, and an **authentication subkey** — all three.

Default `gpg --full-generate-key` on macOS (and Linux) produces only a certify primary + signing primary + encryption subkey — no auth subkey, and no dedicated signing *sub*key:

```
pub  ed25519  [SC]
sub  cv25519  [E]      ← present
                       ← authentication subkey missing
                       ← signing subkey missing → "keyring contains no Keymaker-eligible public certificates"
```

To add both missing subkeys (must be done for every shard-holder key):

```bash
gpg --expert --edit-key alice@example.com
# Add signing subkey:
# gpg> addkey → (11) ECC (set your own capabilities) → leave Sign ON, toggle Encrypt/Auth OFF → Curve 25519 → save
# Add authentication subkey:
# gpg> addkey → (11) ECC (set your own capabilities) → toggle Sign OFF, Authenticate ON → Curve 25519 → save
# gpg> save
```

For test/dev keys, use `caution secret keygen --shoot-self-in-foot` instead — it generates a compliant key (S+E+A subkeys) directly. The `--shoot-self-in-foot` flag is an explicit unsafe acknowledgement that writes unencrypted private keyrings; never use for production shard holders.

```bash
caution secret keygen alice.asc --name "Alice" --email alice@example.com --shoot-self-in-foot
# Also writes alice.private.asc for later shard submission
```

Verify before exporting:
```bash
gpg --list-keys --with-colons alice@example.com | grep '^sub'
# must show all three:  sub … s … ed25519   (signing)
#                       sub … e … cv25519   (encryption)
#                       sub … a … ed25519   (authentication)
```

Export to keyring:
```bash
gpg --armor --export alice@example.com bob@example.com > keyring.asc
export KEYMAKER_URL=https://your-locksmith-deployment.example
caution secret new keyring.asc --threshold 2 --max 2   # writes .caution/quorum-bundle.json
```

`--max` must match the number of certificates in the keyring. If `KEYMAKER_URL` is unset, the CLI exits with `KEYMAKER_URL environment variable is required`.

The public key for encrypting secrets is in the `public_key` field of the bundle:
```bash
jq -r '.public_key' .caution/quorum-bundle.json > recipient.asc
```

### Encrypting secrets (`caution secret encrypt`)

Encrypts values from a `.env` file to the quorum's public key, writing one armored OpenPGP message per non-empty value to `.caution/secrets/<KEY>.asc`:

```bash
caution secret encrypt                    # reads .env, writes .caution/secrets/*.asc
caution secret encrypt DATABASE_URL API_KEY   # encrypt only selected keys
caution secret encrypt --env-file ./prod.env --bundle ./.caution/quorum-bundle.json --secrets-dir ./.caution/secrets
```

The filename (minus `.asc`) becomes the environment variable name. `.caution/quorum-bundle.json` and `.caution/secrets/*.asc` are safe to commit (encrypted to the enclave-only key). Do not commit plaintext `.env` or private keyrings.

### Sending shards (`caution secret send-shard`)

!!! warning "Temporary CLI build requirement"
    `caution secret send-shard` currently requires the **host-toolchain untrusted CLI build** (`make install-cli-untrusted`) because the StageX-reproducible default CLI hits a musl static-linking limitation with PC/SC `libpcsclite_real.so.1`. "Untrusted" means not built via StageX — it inherits host-toolchain supply-chain risks. Production shard-holders use YubiKey/smart cards.

```bash
# Development:
caution secret send-shard --keyring alice.private.asc
caution secret send-shard --keyring bob.private.asc    # repeat per holder

# Production (smart card / YubiKey):
caution secret send-shard    # CLI finds the connected card, prompts for PIN
```

The command looks up the enclave's public IP, reads the bundle, connects on port 49504, verifies the Nitro attestation, encrypts and sends the shard, and reports whether the quorum threshold has been met.

## Common Failures

| Symptom | Cause | Fix |
|---|---|---|
| `Attestation endpoint did not become healthy within 120 seconds` | bootproofd can't complete NSM attestation — often `vsock-network.service` is down (no internet in enclave) | SSH in, check `vsock-network.service` and `nitro_enclaves.log` |
| `Enclave failed to start` | Insufficient memory/CPU, or EIF failed to download from S3 | Check `nitro-enclaves-allocator.service` and `nitro-enclave.service` |
| App unreachable | vsock proxy not running for that port | `systemctl status vsock-proxy-<port>.service` |
| App unreachable, port has no ingress rule | Port the app listens on has no `ingress` rule in `network` | Add an `ingress` rule for that port (and `hostfwd` for local QEMU) |
| `http_port X must also be present in ingress rules` | An `http { port = X }` was set but no `ingress` rule covers X | Add an `ingress { port = X }` rule alongside the `http` block |
| `Multiple enclaves defined; only one enclave is supported` | More than one `enclave "..." { }` block in `caution.hcl` | Define exactly one `enclave` block |
| `Invalid env expression for key '...'` | A unit `env` value is not a string literal or function call | Use a quoted string or `env::vault("NAME")` |
| `caution verify` fails after debug deploy | PCRs are zeroed in debug mode | Remove the `debug` block, redeploy |
| `caution apps build` PCR0/PCR1 ≠ production, but `caution verify` passes | The tool commits (`bootproof`/`enclaveos`/`steve`/`locksmith`) compiled into the CLI as `DEFAULT_*_COMMIT` are stale vs what production deployed; `verify` uses the deployed manifest's commits, your local build used the stale defaults | Read the commits from the deployed manifest (`curl <app-url>/attestation \| jq`) and pass them as `BOOTPROOF_COMMIT=…` etc. to `caution apps build`. See "tool commits are the authoritative reproduction inputs" above. |
| `caution verify` PCR0/PCR1 mismatch that survives `cache=false`, matching commits, and a clean redeploy — content identical, only a file mode differs | A committed non-exec file `COPY`ed from the build context carries the build host's umask mode (0664 on Caution's Linux builder, 0644 on a umask-022 Mac). The bit lands in the measured initramfs. Verifying on a Mac is what exposes it. | Set the mode in-container: `COPY file /tmp/x` + `RUN chmod 0644 /tmp/x`, then `COPY --from=build /tmp/x /dest`. NOT `COPY --chmod=` (see next row). Confirm with the EIF cpio-archive comparison above (diff `cpio -tv` of the two ramdisks). See PCR mismatch diagnosis step 5. |
| `caution verify` fails: `Failed to extract tar archive … failed to unpack etc/hostname … Permission denied` | The app Containerfile used `COPY --chmod=0644 <file> /etc/.../<file>`; `--chmod` also set the auto-created parent dirs (`/etc`, `/etc/pq`) to `0644` (no `x`). The enclave runs (root bypasses), but `caution verify` extracts the app tar as your non-root user and can't traverse the dir. | Drop `--chmod`; set the file mode in a build stage and `COPY --from=build` it, so parents are created at `0755`. Clear the crashed repro cache: `rm -rf ~/.cache/caution/reproductions/local/<app_commit>-*`. |
| Port forwarding not working in QEMU | `pci=off` in kernel cmdline, or Nitro kernel (no virtio-net driver) | Use standard kernel, remove `pci=off` |
| App image build fails with `wget: error getting response: Connection reset by peer` | busybox `wget` has no TLS — can't fetch `https://` URLs inside a stagex pallet | Vendor the tarball locally: `curl -sL <url> -o file.tar.gz`, commit it, use `COPY file.tar.gz .` instead of `wget` in the Containerfile |
| `locksmithd` panics: `has bundle: No such file or directory` | Two causes: (a) the app image is missing `/etc/caution/bundle.json` — using `env::vault` does not inject it; or (b) the bundle IS `ADD`ed but `build` sets `binary`, which extracts only that one file and drops `/etc/caution/`. | (a) `ADD .caution/quorum-bundle.json /etc/caution/bundle.json` and `ADD .caution/secrets/ /etc/caution/secrets/` in the Containerfile. (b) Remove `binary` and deploy via `containerfile` so the full image filesystem becomes the EIF rootfs. |
| `keyring contains no Keymaker-eligible public certificates` during `caution secret new` | Key(s) missing a signing, encryption, or authentication subkey (all three required) | For dev keys: `caution secret keygen --shoot-self-in-foot`. For GPG keys: add a signing subkey and an auth subkey via `gpg --expert --edit-key`. See Locksmith section above. |
| `no match for platform in manifest: not found` during `caution apps build` | StageX images are linux/amd64 only; on an arm64 host (e.g. Apple Silicon) the builder defaults to arm64 | Build inside an amd64 environment, or add `--platform=linux/amd64` to every `FROM` line in the Containerfile: `FROM --platform=linux/amd64 stagex/...` |
| buildx lint warning `FromPlatformFlagConstDisallowed: FROM --platform flag should not use constant value "linux/amd64"` | You pinned `--platform=linux/amd64` on `FROM` (the fix above) | **Benign — don't "fix" it.** The constant pin is deliberate for amd64-only StageX images; it prevents the arm64 default footgun. The build proceeds and stays reproducible. |
