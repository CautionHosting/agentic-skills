---
name: caution-platform
description: Use when writing a Caution Procfile, or deploying, debugging, or testing Caution enclave apps — locally with QEMU (on a Linux host, or inside a Linux amd64 VM on macOS), or on AWS Nitro (health check failures, attestation errors, vsock issues, SSH debug mode, nitro-cli, service logs).
---

# Caution Platform

## Source Of Truth

Prefer current primary sources over memory:

- Caution docs: `https://docs.caution.co/`
- Caution reference: `https://docs.caution.co/reference`
- Caution Procfile reference: `https://docs.caution.co/reference/procfile/`
- Caution containerizing guide: `https://docs.caution.co/guides/containerize-an-application/`
- Caution debugging guide: `https://docs.caution.co/reference/debugging/`
- Caution platform source: `https://codeberg.org/caution/platform`

## Overview

Caution runs apps inside AWS Nitro Enclaves. The enclave boots a custom Linux kernel (`linux-nitro`) with a rootfs built by `caution apps build`, served via `eif_build`. Local debugging uses QEMU to boot the same rootfs with a swapped kernel.

Two files define a Caution app:

- **`Containerfile`** — the reproducible build recipe. Authored with the `stagex-reproducible-builds` skill.
- **`Procfile`** — tells Caution how to run the resulting image. Covered below.

## Procfile

The `Procfile` is a key-value file (one `key: value` per line) at the repo root. It tells Caution how to run the app, which build recipe to use, and what metadata to publish. The Containerfile builds the image; the Procfile launches it.

### Required field

- `run` — the command Caution executes to start the app inside the enclave. The full container filesystem is in the EIF, so use an absolute path that matches the image. It must line up with the binary location the Containerfile produces (e.g. an `ENTRYPOINT ["/app/server"]` pairs with `run: /app/server`).

```procfile
run: /app/server
```

### Choosing the container input (pick one)

| Field | Use when |
|---|---|
| `containerfile` | You build from a Containerfile/Dockerfile (most common). Path relative to repo root, e.g. `deploy/Containerfile`. Defaults to `Containerfile`/`Dockerfile` at the root if omitted. |
| `oci_tarball` | You ship a prebuilt reproducible OCI tarball instead of building. Path to the tarball. |
| `binary` | Only for a fully self-contained static binary with no config files, shared libraries, or other filesystem deps. Unsuitable for most apps. |

Caution builds with `docker build -f <containerfile> .` from the repo root. It no longer supports a `build:` key in the Procfile and passes no extra docker build args — put all build logic in the Containerfile.

### Networking

- `ports` — comma-separated ports to expose, e.g. `ports: 8232, 8233`. Must match the ports the app listens on (and the `hostfwd` rules used for local QEMU). Do **not** use the reserved `49500`–`49600` range.
- `http_port` — a single port Caution fronts with Caddy for TLS termination. Pair with `domain`.
- `domain` — domain name for the deployment.

### Resources

- `memory` — MB, default `512`.
- `cpus` — vCPUs, default `2`.

### Verification metadata

- `app_sources` — comma-separated git URLs for application source verification.
- `enclave_sources` — comma-separated git URLs for enclave source verification.
- `metadata` — custom string published in the manifest.

### Features

- `e2e: true` — end-to-end encryption (default `false`).
- `locksmith: true` — enclave secret management (default `false`). Prefer this over baking secrets into the image.
- `debug: true` — debug mode. Zeros PCR values (breaks `caution verify`); remove before production. See Production Debugging.
- `ssh_keys` — a full OpenSSH public key on one line for host access. Debug only; remove before production.
- `no_cache` — disable the docker build cache.

### BYOC (bring your own cloud)

- `managed_on_prem: true`, `platform: aws`, `aws_region: us-east-1`.

### Examples

Web app fronted with TLS:
```procfile
run: /app/server
containerfile: deploy/Containerfile
domain: api.example.com
http_port: 3000
ports: 3000
app_sources: https://codeberg.org/example/api
```

Multi-port node passing CLI flags:
```procfile
run: /app/server --rpc-port 8232 --p2p-port 8233
ports: 8232, 8233
http_port: 8232
domain: node.example.com
```

Secret management with custom resources:
```procfile
run: /app/server --port 3000
locksmith: true
ports: 3000
http_port: 3000
memory: 4096
cpus: 4
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

**With networking (standard kernel) — adjust ports to match the Procfile:**
```bash
qemu-system-x86_64 \
  -m 512M -nographic \
  -kernel ./vmlinuz-amd64 \
  -initrd ./eif-stage/output/rootfs.cpio.gz \
  -append "console=ttyS0 reboot=k panic=1 nomodules nit.target=/run.sh" \
  -netdev user,id=net0,hostfwd=tcp:0.0.0.0:8083-:8083,hostfwd=tcp:0.0.0.0:49502-:49502 \
  -device virtio-net-pci,netdev=net0
```

The `hostfwd` ports must match the `ports` in your Procfile (plus the attestation port).

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

Add to `Procfile` before pushing:
```procfile
debug: true
ssh_keys: "ssh-ed25519 AAAA... you@host"
```

**Remove both before production** — debug mode zeros PCR values (breaks `caution verify`) and SSH opens port 22.

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

## Common Failures

| Symptom | Cause | Fix |
|---|---|---|
| `Attestation endpoint did not become healthy within 120 seconds` | bootproofd can't complete NSM attestation — often `vsock-network.service` is down (no internet in enclave) | SSH in, check `vsock-network.service` and `nitro_enclaves.log` |
| `Enclave failed to start` | Insufficient memory/CPU, or EIF failed to download from S3 | Check `nitro-enclaves-allocator.service` and `nitro-enclave.service` |
| App unreachable | vsock proxy not running for that port | `systemctl status vsock-proxy-<port>.service` |
| App unreachable, port not in `ports` | Port the app listens on is missing from the Procfile `ports` list | Add the port to `ports` (and `hostfwd` for local QEMU) |
| `caution verify` fails after debug deploy | PCRs are zeroed in debug mode | Remove `debug: true`, redeploy |
| Port forwarding not working in QEMU | `pci=off` in kernel cmdline, or Nitro kernel (no virtio-net driver) | Use standard kernel, remove `pci=off` |
| App image build fails with `wget: error getting response: Connection reset by peer` | busybox `wget` has no TLS — can't fetch `https://` URLs inside a stagex pallet | Vendor the tarball locally: `curl -sL <url> -o file.tar.gz`, commit it, use `COPY file.tar.gz .` instead of `wget` in the Containerfile |
| `no match for platform in manifest: not found` during `caution apps build` | StageX images are linux/amd64 only; on an arm64 host (e.g. Apple Silicon) the builder defaults to arm64 | Build inside an amd64 environment, or add `--platform=linux/amd64` to every `FROM` line in the Containerfile: `FROM --platform=linux/amd64 stagex/...` |
