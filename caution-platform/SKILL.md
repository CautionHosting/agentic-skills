---
name: caution-platform
description: Use when deploying, debugging, or testing Caution enclave apps — locally with QEMU on OrbStack, or on AWS Nitro (health check failures, attestation errors, vsock issues, SSH debug mode, nitro-cli, service logs).
---

# Caution Platform

## Overview

Caution runs apps inside AWS Nitro Enclaves. The enclave boots a custom Linux kernel (`linux-nitro`) with a rootfs built by `caution apps build`, served via `eif_build`. Local debugging uses QEMU to boot the same rootfs with a swapped kernel.

## Local Debugging with QEMU (OrbStack)

Run QEMU inside the OrbStack Ubuntu ARM64 VM. Two kernel modes depending on what you need.

### Getting the kernels

**Nitro bzImage** — logs only, no networking (kernel has no virtio-net or vsock drivers):
```bash
docker create --name tmp-kernel \
  stagex/user-linux-nitro@sha256:aa1006d91a7265b33b86160031daad2fdf54ec2663ed5ccbd312567cc9beff2c
docker cp tmp-kernel:/bzImage ./bzImage
docker rm tmp-kernel
```

**Standard x86_64 kernel** — enables networking and port access (needed to test HTTP endpoints).

On Mac Silicon or any ARM64 host, `--platform linux/amd64` is required to get an x86_64 kernel. On a native amd64 host it can be omitted.

```bash
docker run --rm --platform linux/amd64 \
  -v $(pwd):/out ubuntu:24.04 \
  bash -c "apt-get update -q && apt-get install -y linux-image-generic \
    && chmod 644 /boot/vmlinuz-* \
    && cp /boot/vmlinuz-*-generic /out/vmlinuz-amd64"
```

Note: `apt-get download linux-image-generic:amd64` will fail on ARM64 hosts unless amd64 is added via `dpkg --add-architecture amd64` first. The Docker approach above is simpler.

### Getting the rootfs

After `caution apps build`, the rootfs is at `eif-stage/output/rootfs.cpio.gz` in the app directory (also cached at `~/.cache/caution/build/.../`). Pass this as `-initrd` — never pass the `.eif` directly.

### QEMU commands

**Logs only (Nitro kernel):**
```bash
qemu-system-x86_64 \
  -m 512M -nographic \
  -kernel ./bzImage \
  -initrd ./eif-stage/output/rootfs.cpio.gz \
  -append "console=ttyS0 reboot=k panic=1 nomodules nit.target=/run.sh"
```

**With networking (standard kernel) — adjust ports to match Procfile:**
```bash
qemu-system-x86_64 \
  -m 512M -nographic \
  -kernel ./vmlinuz-amd64 \
  -initrd ./eif-stage/output/rootfs.cpio.gz \
  -append "console=ttyS0 reboot=k panic=1 nomodules nit.target=/run.sh" \
  -netdev user,id=net0,hostfwd=tcp:0.0.0.0:8083-:8083,hostfwd=tcp:0.0.0.0:49502-:49502 \
  -device virtio-net-pci,netdev=net0
```

From macOS, OrbStack exposes the VM at `ubuntu.orb.local`.

**Do NOT include `pci=off` in `-append`** — it disables PCI and breaks virtio-net.

### Testing endpoints

```bash
# App
curl http://ubuntu.orb.local:8083/

# Attestation — nonce is base64-encoded 32 bytes
curl -X POST http://ubuntu.orb.local:49502/attestation \
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
```yaml
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
| `caution verify` fails after debug deploy | PCRs are zeroed in debug mode | Remove `debug: true`, redeploy |
| Port forwarding not working in QEMU | `pci=off` in kernel cmdline, or Nitro kernel (no virtio-net driver) | Use standard kernel, remove `pci=off` |
| App image build fails with `wget: error getting response: Connection reset by peer` | busybox `wget` has no TLS — can't fetch `https://` URLs inside a stagex pallet | Vendor the tarball locally: `curl -sL <url> -o file.tar.gz`, commit it, use `COPY file.tar.gz .` instead of `wget` in the Containerfile |
