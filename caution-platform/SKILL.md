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

## CLI command surface

Verified against the `caution` CLI (subcommands: `register`, `login`, `logout`, `init`, `teardown`, `verify`, `apps`, `ssh-keys`, `cache`, `credentials`, `secret`). There is **no `caution apps push`** and **no `deploy` subcommand** — don't invent them. `apps` has exactly: `create`, `list`, `get`, `destroy`, `build`, `rename`, `download-eif`.

Deploy flow from a repo containing a `Procfile` + `Containerfile`:

```bash
caution login           # (or `register` first) — FIDO2/WebAuthn, interactive
caution init            # initialize the deployment in the cwd; writes .caution/
caution apps build      # OPTIONAL: build the EIF locally to inspect it — does NOT deploy
caution apps create     # create + deploy the app
caution verify --attestation-url https://<domain>/attestation   # reproduce & compare PCRs
```

Key points:
- `caution apps build` is **local inspection only** (build the enclave image to look at it / QEMU-debug it). It is not a deploy step.
- Deploy is `caution init` then `caution apps create`.
- These commands are **interactive** (FIDO2 signing) — wrapping them in a Makefile/CI adds little and can't be fully automated. Keep ops Makefiles to local build/test/reproducibility (`go build`, `vite build`, the two-build `cmp` repro check) and run the `caution` commands directly.
- **Commit** `.caution/deployment.json` (app resource ID, needed for CLI to target the right app), `.caution/quorum-bundle.json`, and `.caution/secrets/*.asc`. **Do not commit** plaintext inputs (`.env`) or generated private keyrings (e.g. `alice.private.asc`). Build output (EIF files) should remain gitignored.

### Deploy is per-branch — keep `Procfile` + `Containerfile` at the repo root

Caution deploys a **specific git branch** (it reports e.g. `Deploying branch 'main' at <sha>`) and looks for a **root `Procfile`** on *that* branch. Two consequences that bite in practice:

- **Put both files at the repo root**, not in a subdir. The `Procfile` *must* be at the root. The `Containerfile` is best at the root too: omit the `containerfile:` key and let Caution auto-detect a root `Containerfile` (before `Dockerfile`). A subpath like `containerfile: deploy/Containerfile` is supported but more fragile — root + auto-detect is the reliable convention. The Docker build context is the repo root regardless, so a root `Containerfile` can still `COPY deploy/ ...`.
- **Deploy the branch that actually carries these files.** Pushing a branch without them (e.g. a bare `main` while the work lives on a feature branch) fails with `error: No Procfile found in repository root`. Either merge the feature branch to the deployed branch first, or push the feature branch to the deploy ref (`git push caution <feature>:main`).

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
| `binary` | Only for a fully self-contained static binary with no config files, shared libraries, or other filesystem deps. Unsuitable for most apps. **Incompatible with `locksmith: true`** — `binary:` extracts only the named file and discards the rest of the image, so the `/etc/caution/bundle.json` you `ADD`ed never reaches the EIF rootfs and `locksmithd` panics. Use `containerfile:` when using locksmith. |

Caution builds with `docker build -f <containerfile> .` from the repo root. It no longer supports a `build:` key in the Procfile and passes no extra docker build args — put all build logic in the Containerfile.

### Networking

- `ports` — comma-separated string of ports to expose, e.g. `ports: 8232, 8233`. **Not a YAML array** — `ports: [8080]` is wrong; use `ports: 8080`. Must match the ports the app listens on (and the `hostfwd` rules used for local QEMU). Do **not** use the reserved `49500`–`49600` range.
- `http_port` — a single port Caution fronts with Caddy for TLS termination. Pair with `domain`. **The `http_port` value must also appear in `ports`** — Caution's Procfile validation (at `apps create`) rejects it otherwise (`Invalid Procfile: http_port X must also be listed in ports`).
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
- `locksmith: true` — enclave secret management (default `false`). Prefer this over baking secrets into the image. **The app image must include `/etc/caution/bundle.json`** (the quorum bundle output by `caution secret new`, stored at `.caution/quorum-bundle.json`) and `/etc/caution/secrets/*.asc` — `locksmithd` reads the bundle at startup and panics with `No such file or directory` if it is absent. Add these to the Containerfile explicitly: `ADD .caution/quorum-bundle.json /etc/caution/bundle.json` and `ADD .caution/secrets/ /etc/caution/secrets/`. **Do not also set `binary:`** — it extracts only the named binary and strips `/etc/caution/`, so locksmithd still panics despite the `ADD`. Build from the full `containerfile:` image; a `scratch` image with just the static binary + bundle + encrypted secrets stays minimal and lets PCR2 measure the bundle.
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

Add to `Procfile` before deploying (`apps create`):
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

## caution verify and PCR Debugging

`caution verify --attestation-url <url>` fetches the live attestation manifest, re-downloads the app source at the **declared commit**, rebuilds the EIF, and compares PCR0/PCR1 against the attestation. A mismatch means the reproduced build differs from the deployed one.

### What the attestation manifest does and does NOT contain

The `EnclaveManifest` embedded in the attestation records:
- `app_source` — URL, commit SHA, branch
- `enclave_source`, `framework_source` — with pinned commits
- `run_command`, `enclaveos_commit`, `bootproof_commit`, `steve_commit`

It does **not** store `ports` or `e2e`. During verification, `caution verify` re-reads the app source's `Procfile` at the declared commit to recover these values — they drive `run.sh` generation (STEVE inclusion, VSOCK port proxies). If the re-read is skipped or wrong, `run.sh` differs → PCR mismatch.

### PCR mismatch — ordered diagnosis

1. **Wrong dev branch / wrong CLI build.** Ensure the CLI was built from the correct branch. If using Docker-based `make install-cli`, add `NO_CACHE=--no-cache` to force a rebuild from source.
2. **`run.sh` is wrong.** Inspect the cached `run.sh`: `cat ~/.cache/caution/reproductions/local/<app_commit>/eif-stage/run.sh`. Confirm it has the STEVE block and correct VSOCK port proxies matching the deployed app's `Procfile`. If not, the ports/e2e re-read from the Procfile isn't working.
3. **Deployed enclave was built from a different commit** than what the manifest declares. The manifest's `app_source.commit` may be stale — the deploy may have used a different branch state, a force-push, or a rebuild without updating the manifest. Try building from nearby commits on the same branch to find the actual source that matches the deployed PCR.
4. **Non-deterministic user app build.** If the app Containerfile runs `npm install && npm run build` without `SOURCE_DATE_EPOCH=1`, or fetches mutable content, the output differs between builds. See the `stagex-reproducible-builds` skill for remediation.

### EIF filesystem comparison (deeper diagnosis)

When the ordered steps above don't identify the cause, compare the local and deployed EIF filesystems directly using `diffoscope`:

```bash
# 1. Build locally
caution apps build
# EIF is at: eif-stage/output/enclave.eif

# 2. Download the deployed EIF
caution apps download-eif
# Saves the deployed EIF locally (filename shown in output)

# 3. Extract both filesystems — find the second gzip entry offset in each
mkdir /tmp/local-extract /tmp/deployed-extract
binwalk eif-stage/output/enclave.eif
# Note the offset of the second gzip entry, then:
cd /tmp/local-extract
dd if=/path/to/enclave.eif bs=1 skip=<offset> | zcat | cpio --no-absolute-filenames -idmv

cd /tmp/deployed-extract
dd if=/path/to/downloaded.eif bs=1 skip=<offset> | zcat | cpio --no-absolute-filenames -idmv

# 4. Compare
diffoscope /tmp/local-extract/ /tmp/deployed-extract/
```

`diffoscope` produces a detailed report of every difference — file additions, removals, content diffs, permission differences.

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

## Locksmith (`caution secret new`)

`caution secret new keyring.asc --threshold N --max N` calls the keymaker service to mint a quorum bundle. It requires each OpenPGP certificate in the keyring to have a **signing subkey**, an **encryption subkey**, and an **authentication subkey** — all three.

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

For test/dev keys, use `caution secret keygen --shoot-self-in-foot` instead — it generates a compliant key (S+E+A subkeys) directly.

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
caution secret new keyring.asc --threshold 2 --max 2   # writes .caution/quorum-bundle.json
```

The public key for encrypting secrets is in the `public_key` field of the bundle:
```bash
jq -r '.public_key' .caution/quorum-bundle.json > recipient.asc
printf '%s' "$MY_SECRET" | gpg --batch --yes --trust-model always \
  --encrypt --armor --recipient-file recipient.asc \
  --output ".caution/secrets/MY_SECRET.asc"
```

`.caution/quorum-bundle.json` and `.caution/secrets/*.asc` are safe to commit (encrypted to the enclave-only key).

## Common Failures

| Symptom | Cause | Fix |
|---|---|---|
| `Attestation endpoint did not become healthy within 120 seconds` | bootproofd can't complete NSM attestation — often `vsock-network.service` is down (no internet in enclave) | SSH in, check `vsock-network.service` and `nitro_enclaves.log` |
| `Enclave failed to start` | Insufficient memory/CPU, or EIF failed to download from S3 | Check `nitro-enclaves-allocator.service` and `nitro-enclave.service` |
| App unreachable | vsock proxy not running for that port | `systemctl status vsock-proxy-<port>.service` |
| App unreachable, port not in `ports` | Port the app listens on is missing from the Procfile `ports` list | Add the port to `ports` (and `hostfwd` for local QEMU) |
| `Invalid Procfile: http_port X must also be listed in ports` | `http_port` was set but `ports` was omitted or doesn't include that same port number | Add `ports: X` (or include X in the ports list) alongside `http_port: X` |
| `caution verify` fails after debug deploy | PCRs are zeroed in debug mode | Remove `debug: true`, redeploy |
| Port forwarding not working in QEMU | `pci=off` in kernel cmdline, or Nitro kernel (no virtio-net driver) | Use standard kernel, remove `pci=off` |
| App image build fails with `wget: error getting response: Connection reset by peer` | busybox `wget` has no TLS — can't fetch `https://` URLs inside a stagex pallet | Vendor the tarball locally: `curl -sL <url> -o file.tar.gz`, commit it, use `COPY file.tar.gz .` instead of `wget` in the Containerfile |
| `locksmithd` panics: `has bundle: No such file or directory` | Two causes: (a) the app image is missing `/etc/caution/bundle.json` — `locksmith: true` does not inject it; or (b) the bundle IS `ADD`ed but the Procfile sets `binary:`, which extracts only that one file and drops `/etc/caution/`. | (a) `ADD .caution/quorum-bundle.json /etc/caution/bundle.json` and `ADD .caution/secrets/ /etc/caution/secrets/` in the Containerfile. (b) Remove `binary:` and deploy via `containerfile:` so the full image filesystem becomes the EIF rootfs. |
| `keyring contains no Keymaker-eligible public certificates` during `caution secret new` | Key(s) missing a signing, encryption, or authentication subkey (all three required) | For dev keys: `caution secret keygen --shoot-self-in-foot`. For GPG keys: add a signing subkey and an auth subkey via `gpg --expert --edit-key`. See Locksmith section above. |
| `no match for platform in manifest: not found` during `caution apps build` | StageX images are linux/amd64 only; on an arm64 host (e.g. Apple Silicon) the builder defaults to arm64 | Build inside an amd64 environment, or add `--platform=linux/amd64` to every `FROM` line in the Containerfile: `FROM --platform=linux/amd64 stagex/...` |
| buildx lint warning `FromPlatformFlagConstDisallowed: FROM --platform flag should not use constant value "linux/amd64"` | You pinned `--platform=linux/amd64` on `FROM` (the fix above) | **Benign — don't "fix" it.** The constant pin is deliberate for amd64-only StageX images; it prevents the arm64 default footgun. The build proceeds and stays reproducible. |
