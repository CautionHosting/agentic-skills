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
- **`caution apps build` builds the current working directory, but its Docker image tag is derived from `HEAD`.** With the cache enabled, uncommitted application/Containerfile changes can therefore reuse an image built from older content. The EIF cache key also includes the parsed deployment configuration, so an uncommitted `caution.hcl` change does not reuse an EIF with different generated `run.sh` configuration. Use a clean committed tree for reproducible evidence; use `--no-cache` when intentionally testing working-tree changes or a newly compiled `DEFAULT_*_COMMIT`.
- `caution apps create` creates the app record on Caution (done during `caution init`); it is not the deploy mechanism itself.
- These commands are **interactive** (FIDO2/WebAuthn signing) — wrapping them in a Makefile/CI adds little and can't be fully automated. Keep ops Makefiles to local build/test/reproducibility (`go build`, `vite build`, the two-build `cmp` repro check) and run the `caution` commands directly.
- **Commit** `.caution/deployment.json` (app resource ID, needed for CLI to target the right app), `.caution/quorum-bundle.json`, `.caution/keymaker-pcr-policy.json` for V1, and `.caution/secrets/*.asc`. **Do not commit** plaintext inputs (`.env`) or generated private keyrings (e.g. `alice.private.asc`). Build output (EIF files) should remain gitignored.
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
      cors_origins = ["https://client.example.com"]
      key_exchange = "xwing-draft10"
    }
  }
  ```

  `key_exchange` is deployment-fixed: omit it for `x25519`, or set it to
  `"xwing-draft10"`. Use explicit browser origins; current STEVE rejects `*`.
  A UI served from loopback may need both `http://localhost:3000` and
  `http://127.0.0.1:3000`, which are distinct origins. For the production
  browser/WASM + Rust release gate, read
  [references/steve-nitro.md](references/steve-nitro.md).

- **Secrets (Locksmith)** — `env::vault("NAME")` in a unit's `env` map automatically enables Locksmith; there is no separate flag. It does not copy files into the image. Include the complete bundle at `/etc/caution/bundle.json`, the verified V1 generation policy at `/etc/caution/keymaker-pcr-policy.json`, and encrypted values under `/etc/caution/secrets/`. ImportedV0 needs no Keymaker policy. Use the full `containerfile` image; `build.binary` discards these files. Locksmith listens on reserved port 49504; do not configure that ingress yourself. See [Locksmith](#locksmith-caution-secret) below for creation, packaging and release commands.

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

```bash
caution init --byoc    # provisions AWS infra + registers scoped deployment credentials automatically
```

`init` needs AWS credentials in the environment and writes an encrypted managed-credentials
file (`credentials.json.gpg`). If you already have one — provisioned earlier, or handed to you
by whoever owns the AWS account — point `init` at it instead of re-provisioning:

```bash
caution init --byoc --config /path/to/credentials.json.gpg
```

To deploy into an existing VPC, set `provider.vpc_id` (and `subnet_ids`/`security_group_id`
as needed) in the `caution { provider { … } }` block above rather than letting provisioning
create a new VPC.

Provisioning creates: a dedicated `/16` VPC with IGW/routing, S3 bucket (`caution-<deployment-id>-images`), EC2 instance role (read EIFs), builder role (publish EIFs), launch template, Auto Scaling Group (starts at 0), and a scoped IAM user with tag-based resource policies.

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
  bash -euc 'apt-get update -q
    apt-get install -y linux-image-generic
    kernel="$(find /boot -maxdepth 1 -type f -name "vmlinuz-*-generic" | sort | tail -n 1)"
    test -n "$kernel"
    chmod 0644 "$kernel"
    cp "$kernel" /out/vmlinuz-amd64'
```
On an amd64 host or VM this runs natively. If you must build it on an arm64 host, add `--platform linux/amd64` to the `docker run` (and note that `apt-get download linux-image-generic:amd64` won't work on arm64 unless amd64 is added first with `dpkg --add-architecture amd64`).

### Getting the rootfs

After `caution apps build`, copy the exact path printed under `=== Build Directory ===` / `Location:`:

```bash
BUILD_DIR=<printed-location>
```

The rootfs is then `$BUILD_DIR/output/rootfs.cpio.gz`. The default location is under `~/.cache/caution/build/local/`; it is not normally written into the app directory. Pass the rootfs as `-initrd` — never pass the `.eif` directly.

### QEMU commands

**Logs only (Nitro kernel):**
```bash
qemu-system-x86_64 \
  -m 512M -nographic \
  -kernel ./bzImage \
  -initrd "$BUILD_DIR/output/rootfs.cpio.gz" \
  -append "console=ttyS0 reboot=k panic=1 nomodules nit.target=/run.sh"
```

**With networking (standard kernel) — adjust ports to match `caution.hcl`:**
```bash
qemu-system-x86_64 \
  -m 512M -nographic \
  -kernel ./vmlinuz-amd64 \
  -initrd "$BUILD_DIR/output/rootfs.cpio.gz" \
  -append "console=ttyS0 reboot=k panic=1 nomodules nit.target=/run.sh" \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:8083-:8083,hostfwd=tcp:127.0.0.1:49500-:49500,hostfwd=tcp:127.0.0.1:49502-:49502 \
  -device virtio-net-pci,netdev=net0
```

The application `hostfwd` ports must match the `ingress` ports in your `caution.hcl`. Add STEVE `49500` when `e2e_encryption` is enabled and Bootproof `49502` for the local attestation-boundary check. Bind to `127.0.0.1` unless you intentionally want other machines to reach the guest.

**Do NOT include `pci=off` in `-append`** — it disables PCI and breaks virtio-net.

### Testing endpoints

Run these from inside the Linux environment (use `localhost`); from your host machine, replace `localhost` with the VM's hostname or IP.

```bash
# App
curl http://localhost:8083/

# STEVE plaintext fallback — proves STEVE started and reached its app upstream
curl http://localhost:49500/

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

The production STEVE binary in the EIF cannot complete a protected session under QEMU because session establishment requires Nitro evidence from `/dev/nsm`. Treat QEMU as a package/start/routing smoke. For successful browser/SDK encryption without Nitro, run STEVE's explicit synthetic-attestation E2E separately; that validates protocol behavior but is not the production EIF binary. Platform contributors validating a changed `DEFAULT_STEVE_COMMIT` should use `caution-local-dev/scripts/test-enclave-component-pin.sh`, which builds a branch-local CLI and automates these package checks.

### Local limitations

| Feature | Local QEMU | Production |
|---|---|---|
| App starts, logs visible | Yes | Yes |
| Networking / port access | Standard kernel only | Yes (vsock tunnel) |
| STEVE process + plaintext fallback routing | Yes, with port 49500 forwarded | Yes |
| Successful production STEVE attested session | No (`/dev/nsm` absent) | Yes |
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
caution apps build               # copy the printed Build Directory Location
BUILD_DIR=<printed-location>
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
gzip -dc "$BUILD_DIR/output/rootfs.cpio.gz" > repro.cpio   # macOS: use gzip -dc, not zcat

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

Follow the [Key Services guide](https://docs.caution.co/concepts/key-services/) for the current setup flow. Reuse an existing quorum bundle when changing secrets or restarting an enclave. Keymaker is needed only to create a new quorum; a timeout or lost generation response is an unknown outcome, so check for a saved bundle before another explicit attempt.

External-PGP holders keep their private keys. Passkey holders authorize keys derived inside the key-service enclave, which re-encrypts their shares to the verified application. Distinct holders contribute to the same threshold; multiple passkeys for one holder remain one share. After recovery, locksmithd starts keyforkd and locksmith-oneshot decrypts the application values.

### Creating or downloading a bundle

Managed creation uses Platform's hosted Keymaker when neither `--keymaker-url` nor `KEYMAKER_URL` is set. Both PGP-only and mixed/passkey quorums are supported. From the initialized application checkout, with Alice's PGP key and Bob's passkey registered in the selected organization:

```bash
caution login
caution verify --service keymaker
env -u KEYMAKER_URL caution secret init \
  --holder alice=external-pgp --holder bob=webauthn --threshold 2 \
  --name "Application secrets"
```

Review the holders, approval methods and threshold before authorizing creation. Set the threshold explicitly: the CLI defaults to one; the dashboard defaults to two. If a holder has several PGP keys, use `--pgp-key alice=FULL_REGISTERED_PGP_FINGERPRINT`. `--max`, when supplied, must match the combined holder count. A local public-only keyring can also be combined with `--holder` selections.

The CLI saves `.caution/quorum-bundle.json` and `.caution/keymaker-pcr-policy.json`. Alternatively, create a bundle in **Secrets → Create quorum bundle** and download the complete JSON as `.caution/quorum-bundle.json`. Dashboard creation does not encrypt application values or collect holders' release approvals. For a download, package the independently verified generation policy; if the project has no existing policy, export it from the exact Keymaker trust file printed by successful service verification:

```bash
jq '.policy' /path/to/saved/keymaker.json > .caution/keymaker-pcr-policy.json
caution secret inspect --bundle .caution/quorum-bundle.json
```

Keep the complete bundle; do not extract a top-level `public_key` field or discard its proof. `secret inspect` reports holder fingerprints, threshold and generation evidence. Retain the historical verified policy for an existing bundle; verifying today's Keymaker cannot establish missing trust in an older generation image.

### Manual PGP creation

Deploy and verify your Keymaker in a **separate checkout/application**, following the guide's [manual setup](https://docs.caution.co/concepts/key-services/#self-hostedmanual). Return to the application checkout before generating its bundle. Export only public holder certificates, each with signing, encryption and authentication keys:

```bash
gpg --armor --export alice@example.com bob@example.com > keyring.asc
caution secret init keyring.asc --threshold 2 --max 2 \
  --keymaker-url https://YOUR_KEYMAKER \
  --keymaker-pcr-policy /path/to/keymaker-checkout/.caution/trusted_hashes.json \
  --no-upload
```

Use the Keymaker checkout's trusted hashes only after successful verification; the CLI saves a normalized `sets` policy beside the bundle. `--no-upload` keeps creation local; omit it to upload after authentication. A failed upload does not require regenerating a saved bundle. Either the explicit URL or `KEYMAKER_URL` selects direct PGP-only mode; `KEYMAKER_URL` is not required for managed creation. `caution secret new` remains an alias for `caution secret init`.

For development keys only:

```bash
caution secret keygen alice.asc --name "Alice" --email alice@example.com --shoot-self-in-foot
```

This creates `alice.asc` and an unencrypted `alice.private.asc`. Never commit the private keyring or use it for production holders; use OpenPGP smartcards for production external-PGP keys. See the guide for keyring preparation.

### Trust and image inputs

Keep three policies distinct: Keymaker generation measurements verify V1 bundle proofs; application measurements in `.caution/trusted_hashes.json` authorize the destination; the key-service live policy authorizes passkey release. Obtain measurements through independent verification, not by copying a failing endpoint's PCRs or substituting all-zero QEMU measurements.

For generation, Keymaker policy precedence is `--keymaker-pcr-policy`, `KEYMAKER_PCR_POLICY_PATH`, `.caution/keymaker-pcr-policy.json`, then shared Platform trust. Encryption and release have no `--keymaker-pcr-policy` flag; use the environment, project policy or saved trust. `secret inspect` and encryption do not initiate discovery. Client trust setup does not update operator policies or files already packaged in an enclave.

Reference each secret with `env::vault("NAME")` and copy these inputs into the **final image stage** for V1:

```dockerfile
COPY .caution/quorum-bundle.json /etc/caution/bundle.json
COPY .caution/keymaker-pcr-policy.json /etc/caution/keymaker-pcr-policy.json
COPY .caution/secrets/ /etc/caution/secrets/
```

`env::vault` enables Locksmith but does not copy files. Do not use `build.binary`, which discards this filesystem. Normalize public/encrypted files to `0644` and directories to `0755`. ImportedV0 needs the imported bundle and ciphertext only; no Keymaker policy is required for its CLI, image preflight or runtime.

### Encrypting secrets (`caution secret encrypt`)

Encrypt values from a private `.env` file with the existing bundle:

```bash
caution secret encrypt                       # reads .env, writes .caution/secrets/*.asc
caution secret encrypt DATABASE_URL API_KEY   # encrypt only selected keys
caution secret encrypt --env-file ./prod.env --bundle ./.caution/quorum-bundle.json --secrets-dir ./.caution/secrets
```

Each non-empty value becomes `.caution/secrets/<KEY>.asc`; the filename determines the environment variable. Locksmith currently trims leading/trailing whitespace when exporting decrypted values. Commit the complete bundle, public policies and encrypted `.asc` files, keeping plaintext env files and private keys outside Git. Updating a value requires rebuilding/redeploying, verifying the new application image and collecting shares again, using the same bundle.

### Sending shards (`caution secret send-shard`)

Use the host-toolchain CLI: `make install-cli` (also `make install-cli-host`). It inherits host-toolchain/library risks and does not have StageX's reproducibility or full-source-bootstrap guarantees. `make install-cli-stagex` can hit the PC/SC `libpcsclite_real.so.1` static-linking limitation on the shard-sending path.

After deploying the application, verify its live image before release:

```bash
caution verify
caution secret inspect
# External PGP: each holder uses their own smartcard or private keyring.
caution secret send-shard --holder CERTIFICATE_FINGERPRINT
caution secret send-shard --keyring alice.private.asc
```

For passkey holders, establish key-service trust on the selected Platform, then choose browser/QR or native USB FIDO2 approval:

```bash
caution verify --service key-service
caution --qr secret send-shard --holder CERTIFICATE_FINGERPRINT
# Native USB FIDO2 alternative:
caution secret send-shard --holder CERTIFICATE_FINGERPRINT
```

Explicit service configuration uses `--recryptor-url` and `--recryptor-pcr-policy`; verify that endpoint's policy independently. Compare release details and wait for the destination acknowledgement. Creation approval does not count as a release, and repeated submissions by one holder do not meet a multi-holder quorum. New passkeys registered after bundle creation cannot authorize release for that unchanged bundle.

After an application restart, holders must release shares again. A key-service restart requires its operators to recover the existing root before passkey releases work; do not generate a replacement root. For receiver clock errors, check signer/enclave clocks: external-PGP signatures permit up to 60 seconds of future skew. Receiver upgrades require rebuilding, redeploying and verifying the application; changing the CLI alone does not update the running enclave.

### Existing V0 PGP bundles

Raw V0 requires a one-time holder-assisted import; it preserves the quorum key and existing ciphertext and has no Keymaker generation proof:

```bash
caution secret import-legacy --bundle /path/original-v0.json --keyring /path/holder.private.asc
# Smartcard alternative: omit --keyring and use --holder FULL_FINGERPRINT.
caution secret inspect --bundle .caution/quorum-bundle.json
```

Import refuses to overwrite its output; use `--output PATH` when needed and retain the original. Package the imported artifact at `/etc/caution/bundle.json` with the existing ciphertext, rebuild/redeploy and verify the application. Do not regenerate the quorum or re-encrypt unchanged values. ImportedV0 supports external PGP only; use explicit legacy acceptance for each encryption or release:

```bash
caution secret encrypt DATABASE_URL --env-file /private/app.env --allow-legacy
caution secret send-shard --holder FULL_FINGERPRINT --allow-legacy
```

`secret inspect` needs neither a Keymaker policy nor `--allow-legacy` for ImportedV0. Failed V1 proof verification must never fall back to legacy acceptance.

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
| `locksmithd` panics: `has bundle: No such file or directory` | The final image lacks `/etc/caution/bundle.json`, or `build.binary` discarded its filesystem | Copy the complete bundle, encrypted secrets and (for V1) verified Keymaker policy as shown above. Use the full `containerfile` image; `env::vault` does not copy files. |
| `keyring contains no Keymaker-eligible public certificates` during `caution secret init` | A holder certificate lacks signing, encryption or authentication keys | Prepare eligible public holder certificates; use `caution secret keygen --shoot-self-in-foot` only for development. See the Key Services guide for keyring preparation. |
| `no match for platform in manifest: not found` during `caution apps build` | StageX images are linux/amd64 only; on an arm64 host (e.g. Apple Silicon) the builder defaults to arm64 | Build inside an amd64 environment, or add `--platform=linux/amd64` to every `FROM` line in the Containerfile: `FROM --platform=linux/amd64 stagex/...` |
| EIF build fails at `Containerfile.eif` step `mkdir: can't create directory '/build/initramfs/bin': No such file or directory` (also hits `/lib`, `/etc/ssl/certs`) | The app image's `/bin`,`/lib`,`/sbin` are **dangling symlinks into `/usr`**. `stagex/core-filesystem` ships them as `bin -> usr/bin` etc., but a **fully static** app (no busybox/musl pallet in the final stage) never populates `usr/bin`,`usr/lib`,`usr/sbin`. The platform packer does `test -e /build/initramfs/bin || mkdir -p …`; `test -e` is false on a dangling link and `mkdir -p` through it fails ENOENT. Confirm by exporting the image: `docker export <img> \| tar -tv \| grep -E ' (bin\|usr/bin)'` shows `bin -> usr/bin` with no `usr/bin/` dir. | Materialize the symlink targets in the app image so they resolve. In a build stage that has a shell, `install -d /staged/usr/bin /staged/usr/lib /staged/usr/sbin /staged/etc/ssl/certs` into the tree you `COPY` into the final stage (created in-container, so modes are deterministic — don't use `COPY --chmod`). Then `test -e` sees the real `usr/*` dir and skips the `mkdir`. |
| buildx lint warning `FromPlatformFlagConstDisallowed: FROM --platform flag should not use constant value "linux/amd64"` | You pinned `--platform=linux/amd64` on `FROM` (the fix above) | **Benign — don't "fix" it.** The constant pin is deliberate for amd64-only StageX images; it prevents the arm64 default footgun. The build proceeds and stays reproducible. |
