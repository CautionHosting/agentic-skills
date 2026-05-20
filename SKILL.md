---
name: stagex-reproducible-builds
description: Use when building container images with stagex for reproducible, verifiable builds — packaging C/C++ programs, selecting the right pallet, pinning digests, vendoring sources, and choosing a minimal runtime base.
---

# stagex Reproducible Builds

## Overview

stagex provides hermetic, reproducible OCI images as build toolchains. Every input is pinned by digest — same source + same pallet + same flags = bit-for-bit identical output on any machine. Required by platforms like Caution that verify enclave measurements.

Packages: https://stagex.tools/packages/ (513 packages across Bootstrap, Core, Pallet, User categories)

---

## Pallet Selection

| Need | Pallet |
|------|--------|
| Rust project | `stagex/pallet-rust` |
| C/C++ with inline source only | `stagex/pallet-gcc` |
| C/C++ needing `./configure`, `make`, `wget`, `tar` | `stagex/pallet-gcc-gnu-busybox` |
| C/C++ with CMake | `stagex/pallet-gcc-cmake-busybox` |
| C/C++ with Meson | `stagex/pallet-gcc-meson-busybox` |
| Go project | `stagex/pallet-go` |

**Critical:** `pallet-gcc` has `ENTRYPOINT ["/usr/bin/gcc"]` — no shell. Any `RUN` command that uses shell syntax (heredocs, `&&`, pipes) will fail. Use `pallet-gcc-gnu-busybox` for anything beyond a single compile invocation.

---

## Getting the Real Digest

**Never guess or scrape a digest — always pull and inspect:**

```bash
docker pull stagex/pallet-gcc-gnu-busybox --platform linux/amd64
docker inspect stagex/pallet-gcc-gnu-busybox --format '{{index .RepoDigests 0}}'
# → stagex/pallet-gcc-gnu-busybox@sha256:<real-digest>
```

Use the `sha256:...` part in your `FROM` line.

---

## Vendoring External Sources

**busybox `wget` has no TLS support** — it cannot download from `https://` URLs. Any source code your build needs must be vendored (committed to the repo) and verified with SHA256 at build time.

```bash
# Locally: download and verify
curl -sL https://example.com/project-1.2.3.tar.gz -o project-1.2.3.tar.gz
shasum -a 256 project-1.2.3.tar.gz   # macOS
sha256sum project-1.2.3.tar.gz        # Linux
```

```dockerfile
# In Containerfile: copy and verify before using
COPY project-1.2.3.tar.gz .
RUN echo "<sha256hash>  project-1.2.3.tar.gz" | sha256sum -c \
    && tar xzf project-1.2.3.tar.gz \
    && ...
```

This removes all network dependencies from the build and provides supply-chain verification.

---

## Inspecting Pallet Contents

Before writing the build stage, verify a pallet has the tools you need:

```bash
docker run --rm --platform linux/amd64 --entrypoint sh \
  stagex/pallet-gcc-gnu-busybox \
  -c 'which gcc make tar wget; ls /usr/lib/libssl* /usr/include/openssl 2>/dev/null || echo "no openssl"'
```

If a required library (e.g. `openssl-dev`) is missing from the pallet, you have two options:
1. Use `--without-openssl` (or equivalent configure flag) to disable that feature
2. Vendor the library source and build it in the same `RUN` step before your project

stagex does not have a package manager inside pallets — everything must come from the pallet image or be vendored.

---

## GCC 15 Strictness

stagex ships GCC 15.2.0, which promotes several previously-warning conditions to errors. The most common when building older C projects:

```
error: assignment to 'void (*)(struct foo *)' from incompatible pointer type 'void (*)(void)' [-Wincompatible-pointer-types]
```

Fix by passing CFLAGS at configure time:

```bash
CFLAGS="-Wno-error=incompatible-pointer-types" ./configure ...
```

Or when invoking gcc directly:

```bash
gcc -Wno-error=incompatible-pointer-types ...
```

---

## Choosing the Runtime Base

| Base | When to use | Gotcha |
|------|-------------|--------|
| `FROM scratch` | Fully static binary with no runtime file lookups | OrbStack requires `/bin/sh` even for exec-form CMD; may need `COPY --from=builder /bin/busybox /bin/sh` |
| `stagex/core-filesystem` | Binary needs `/etc/hosts`, `/etc/resolv.conf`, `/etc/passwd`, `/tmp` at runtime | **Has `ENTRYPOINT ["/bin/sh"]`** — must override or your binary runs as a shell script argument |

**core-filesystem ENTRYPOINT trap** — always override explicitly:

```dockerfile
FROM stagex/core-filesystem@sha256:<digest>

COPY --from=builder /bin/busybox /bin/sh        # if shell needed for runtime
COPY --from=builder /path/to/binary /usr/local/bin/mybinary

ENTRYPOINT ["/usr/local/bin/mybinary"]           # REQUIRED — clears inherited /bin/sh entrypoint
CMD ["--flag", "value"]
```

Without the `ENTRYPOINT` override, Docker passes your CMD args to `/bin/sh`, which tries to execute your binary as a shell script.

---

## Complete Example

```dockerfile
FROM stagex/pallet-gcc-gnu-busybox@sha256:<builder-digest> AS builder

WORKDIR /build

COPY myproject-1.0.tar.gz .

RUN echo "<sha256>  myproject-1.0.tar.gz" | sha256sum -c \
    && tar xzf myproject-1.0.tar.gz \
    && cd myproject-1.0 \
    && CFLAGS="-Wno-error=incompatible-pointer-types" ./configure --enable-static-bin \
    && make -j$(nproc) \
    && strip src/mybin

FROM stagex/core-filesystem@sha256:<runtime-digest>

COPY --from=builder /bin/busybox /bin/sh
COPY --from=builder /build/myproject-1.0/src/mybin /usr/local/bin/mybin

EXPOSE 5201

ENTRYPOINT ["/usr/local/bin/mybin"]
CMD ["--server"]
```

---

## Quick Reference

```bash
# 1. Find available pallets
open https://stagex.tools/packages/

# 2. Get digest for chosen pallet
docker pull stagex/pallet-gcc-gnu-busybox --platform linux/amd64
docker inspect stagex/pallet-gcc-gnu-busybox --format '{{index .RepoDigests 0}}'

# 3. Get digest for core-filesystem
docker pull stagex/core-filesystem --platform linux/amd64
docker inspect stagex/core-filesystem --format '{{index .RepoDigests 0}}'

# 4. Vendor source tarball
curl -sL <source-url> -o project-x.y.z.tar.gz
shasum -a 256 project-x.y.z.tar.gz

# 5. Build for verification
docker build -f Containerfile -t myapp . --platform linux/amd64
```

---

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Using `pallet-gcc` with `RUN` shell commands | Switch to `pallet-gcc-gnu-busybox` |
| Guessing or scraping a digest | Always `docker pull` + `docker inspect` |
| `wget https://...` in RUN | No TLS in busybox wget — vendor the file |
| Build fails on pointer type errors | Add `CFLAGS="-Wno-error=incompatible-pointer-types"` |
| Binary runs as shell script in core-filesystem | Add `ENTRYPOINT ["/usr/local/bin/yourbinary"]` |
| `FROM scratch` container won't start (OrbStack) | Copy busybox: `COPY --from=builder /bin/busybox /bin/sh` |
