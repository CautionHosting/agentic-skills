---
name: stagex-reproducible-builds
description: Use when building container images with stagex for reproducible, verifiable builds — packaging Rust, Go, or C/C++ programs, selecting the right pallet, pinning digests, vendoring sources, and choosing a minimal runtime base.
---

# stagex Reproducible Builds

## Overview

stagex provides hermetic, reproducible OCI images as build toolchains. Every input is pinned by digest — same source + same pallet + same flags = bit-for-bit identical output on any machine. Required by platforms like Caution that verify enclave measurements.

Packages: https://stagex.tools/packages/ (513 packages across Bootstrap, Core, Pallet, User categories)

---

## Pallet Selection

| Language / Need | Pallet |
|---|---|
| Rust (standard cargo project) | `stagex/pallet-rust` |
| Go (standard go build) | `stagex/pallet-go` |
| C/C++ with inline source only | `stagex/pallet-gcc` |
| C/C++ needing `./configure`, `make`, `wget`, `tar` | `stagex/pallet-gcc-gnu-busybox` |
| C/C++ with CMake | `stagex/pallet-gcc-cmake-busybox` |
| C/C++ with Meson | `stagex/pallet-gcc-meson-busybox` |

**Critical:** `pallet-gcc` has `ENTRYPOINT ["/usr/bin/gcc"]` — no shell. Any `RUN` using shell syntax (heredocs, `&&`, pipes) will fail. Use `pallet-gcc-gnu-busybox` for anything beyond a single compile invocation.

`pallet-rust` (`ENTRYPOINT ["cargo"]`) and `pallet-go` both include `core-busybox` so a shell is available for `RUN` commands, but neither has `make`. This is fine — cargo and go handle their own build orchestration.

---

## Getting the Real Digest

**Never guess or scrape a digest — always pull and inspect:**

```bash
docker pull stagex/pallet-rust --platform linux/amd64
docker inspect stagex/pallet-rust --format '{{index .RepoDigests 0}}'
# → stagex/pallet-rust@sha256:<real-digest>
```

Use the `sha256:...` part in your `FROM` line. Repeat for every image used.

---

## Rust Builds

`pallet-rust` includes Rust 1.94.0, cargo, and the `x86_64-unknown-linux-musl` target. No rustup — the musl target is pre-installed.

**Static binary (Caution-compatible):**
```dockerfile
FROM stagex/pallet-rust@sha256:<digest> AS builder

# Eliminate timestamp-based non-determinism
ENV SOURCE_DATE_EPOCH=1

WORKDIR /app
COPY . .

# --network=none enforces no network fetches at build time (required by Caution)
# --frozen ensures Cargo.lock is not modified
RUN --network=none \
    RUSTFLAGS="-C target-feature=+crt-static" \
    cargo build \
      --frozen \
      --release \
      --target x86_64-unknown-linux-musl

FROM stagex/core-filesystem@sha256:<digest>

COPY --from=builder /app/target/x86_64-unknown-linux-musl/release/myapp /usr/local/bin/myapp

ENTRYPOINT ["/usr/local/bin/myapp"]
```

**External crate dependencies:** cargo fetches from crates.io at build time by default (needs network). For fully offline reproducible builds, vendor first:

```bash
# Locally, once
cargo vendor vendor/
```

```dockerfile
ENV SOURCE_DATE_EPOCH=1

COPY . .
COPY vendor/ vendor/
RUN mkdir -p .cargo && printf '[source.crates-io]\nreplace-with = "vendored-sources"\n[source.vendored-sources]\ndirectory = "vendor"\n' > .cargo/config.toml
RUN --network=none \
    RUSTFLAGS="-C target-feature=+crt-static" \
    cargo build \
      --frozen \
      --release \
      --target x86_64-unknown-linux-musl
```

> **Multi-arch:** replace `x86_64` with `$(uname -m)` if building for multiple platforms:
> `--target "$(uname -m)-unknown-linux-musl"`

---

## Go Builds

`pallet-go` includes Go 1.26.0. CGO is disabled by convention for static builds.

**Static binary (Caution-compatible):**
```dockerfile
FROM stagex/pallet-go@sha256:<digest> AS builder

ENV SOURCE_DATE_EPOCH=1

WORKDIR /app
COPY . .

# -mod=vendor enforces offline build from vendored modules
# --network=none enforces no network fetches at build time (required by Caution)
RUN --network=none \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -mod=vendor -ldflags="-s -w" -o myapp .

FROM stagex/core-filesystem@sha256:<digest>

COPY --from=builder /app/myapp /usr/local/bin/myapp

ENTRYPOINT ["/usr/local/bin/myapp"]
```

**External module dependencies:** `go build` downloads modules at build time. For fully offline builds, vendor first:

```bash
# Locally, once
go mod vendor
```

```dockerfile
COPY . .
RUN --network=none \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -mod=vendor -ldflags="-s -w" -o myapp .
```

---

## C/C++ Builds

**Vendoring external source:** busybox `wget` has no TLS — download source locally first:

```bash
curl -sL https://example.com/project-1.2.3.tar.gz -o project-1.2.3.tar.gz
shasum -a 256 project-1.2.3.tar.gz   # macOS / sha256sum on Linux
```

```dockerfile
FROM stagex/pallet-gcc-gnu-busybox@sha256:<digest> AS builder

ENV SOURCE_DATE_EPOCH=1

WORKDIR /build
COPY myproject-1.2.3.tar.gz .

RUN --network=none \
    echo "<sha256>  myproject-1.2.3.tar.gz" | sha256sum -c \
    && tar xzf myproject-1.2.3.tar.gz \
    && cd myproject-1.2.3 \
    && CFLAGS="-Wno-error=incompatible-pointer-types" ./configure --enable-static-bin \
    && make -j$(nproc) \
    && strip src/mybin
```

**GCC 15 strictness:** stagex ships GCC 15.2.0, which promotes `-Wincompatible-pointer-types` to an error. Fix:
```bash
CFLAGS="-Wno-error=incompatible-pointer-types" ./configure ...
```

**Missing libraries:** stagex has no package manager inside pallets. If a library (e.g. `openssl`) is absent, either disable that feature (`--without-openssl`) or vendor and build the library source in the same `RUN` step.

---

## Choosing the Runtime Base

| Base | When to use | Gotcha |
|---|---|---|
| `FROM scratch` | Pure static binary, no runtime file lookups | OrbStack requires `/bin/sh` even for exec-form CMD — copy busybox: `COPY --from=builder /bin/busybox /bin/sh` |
| `stagex/core-filesystem` | Binary needs `/etc/hosts`, `/etc/resolv.conf`, `/etc/passwd`, `/tmp` at runtime | **Has `ENTRYPOINT ["/bin/sh"]`** — must override or binary runs as a shell script |

**core-filesystem ENTRYPOINT trap:**
```dockerfile
FROM stagex/core-filesystem@sha256:<digest>

COPY --from=builder /bin/busybox /bin/sh        # only if shell also needed at runtime
COPY --from=builder /path/to/binary /usr/local/bin/mybin

ENTRYPOINT ["/usr/local/bin/mybin"]             # REQUIRED — overrides inherited /bin/sh
CMD ["--flag", "value"]
```

---

## Inspecting Pallet Contents

```bash
docker run --rm --platform linux/amd64 --entrypoint sh stagex/pallet-gcc-gnu-busybox \
  -c 'which gcc make tar wget; ls /usr/lib/libssl* 2>/dev/null || echo "no openssl"'
```

---

## Quick Reference

```bash
# Get digest for any pallet
docker pull stagex/<pallet-name> --platform linux/amd64
docker inspect stagex/<pallet-name> --format '{{index .RepoDigests 0}}'

# Common pallets
stagex/pallet-rust          # Rust 1.94.0 + cargo + musl target (ENTRYPOINT = cargo)
stagex/pallet-go            # Go 1.26.0
stagex/pallet-gcc           # GCC 15.2.0, no shell (ENTRYPOINT = gcc)
stagex/pallet-gcc-gnu-busybox   # GCC + make + busybox shell
stagex/core-filesystem      # Minimal runtime: /etc/hosts, passwd, tmp (ENTRYPOINT = /bin/sh)

# Build
docker build -f Containerfile -t myapp . --platform linux/amd64
```

---

## Common Mistakes

| Mistake | Fix |
|---|---|
| Using `pallet-gcc` with `RUN` shell commands | Switch to `pallet-gcc-gnu-busybox` |
| Guessing or scraping a digest | Always `docker pull` + `docker inspect` |
| `wget https://...` in RUN | No TLS in busybox wget — vendor the file |
| C build fails on pointer type errors with GCC 15 | Add `CFLAGS="-Wno-error=incompatible-pointer-types"` |
| Binary runs as shell script in core-filesystem | Add `ENTRYPOINT ["/usr/local/bin/yourbinary"]` |
| `FROM scratch` container won't start (OrbStack) | `COPY --from=builder /bin/busybox /bin/sh` |
| Rust crates or Go modules missing at build time | Vendor deps: `cargo vendor` / `go mod vendor` |
| Rust not targeting musl | Add `--target x86_64-unknown-linux-musl` + `RUSTFLAGS="-C target-feature=+crt-static"` |
| Go binary has libc dependency | Set `CGO_ENABLED=0` |
| Network access during build (Caution) | Wrap `RUN` with `--network=none` |
| Cargo.lock mutated during build | Add `--frozen` to `cargo build` |
| Timestamps causing non-determinism | Set `ENV SOURCE_DATE_EPOCH=1` |
