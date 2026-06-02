---
name: stagex-reproducible-builds
description: Use when creating or reviewing StageX-based Containerfiles, Dockerfiles, Procfiles, or build workflows for reproducible builds, Caution deployments, confidential compute enclaves, verifiable compute, Nitro/TEE attestation, or enclave image PCR verification. Covers choosing StageX pallets, digest pinning, offline dependency vendoring, deterministic Rust/Go/C/C++ builds, minimal runtime images, and Caution-compatible reproducibility checks.
---

# StageX Reproducible Builds

Use this skill to produce container builds whose outputs can be independently reproduced and verified for confidential compute enclaves, especially Caution deployments.

## Source Of Truth

Prefer current primary sources over memory:

- StageX source: `https://codeberg.org/stagex/stagex`
- StageX packages: `https://stagex.tools/packages/`
- Caution docs: `https://docs.caution.co/`
- Caution reference: `https://docs.caution.co/reference`
- Caution containerizing guide: `https://docs.caution.co/reference/containerizing/`

Do not hardcode "latest" digests or versions from memory. StageX images are updated by release. Confirm the current digest before writing a production `FROM`.

## Security Model

StageX packages are OCI images built for full-source bootstrapping, hermetic inputs, deterministic output, and multi-party verification. Caution uses this property with EnclaveOS so enclave deployments can be verified from application source down to the kernel.

For Caution, reproducibility is required for verifiability:

- A fixed set of inputs must produce bit-for-bit identical outputs.
- Build inputs must be pinned: source commits, image digests, lockfiles, vendored dependencies, compiler flags, and build platform.
- Build steps must not fetch mutable inputs during the build.
- `caution verify` reproduces the build from attestation manifest data and compares PCR values: PCR0 for enclave image, PCR1 for kernel/bootstrap, PCR2 for application.

## Required Output For A Caution App

When helping containerize an app for Caution, produce or review both:

- `Containerfile` or `Dockerfile` that builds a reproducible image.
- `Procfile` that tells Caution how to run it.

Keep the final image minimal. Copy only runtime artifacts from the builder stage.

## Digest Pinning

Always pin StageX images by digest in production examples:

```bash
docker pull stagex/pallet-rust --platform linux/amd64
docker inspect stagex/pallet-rust --format '{{index .RepoDigests 0}}'
```

Then use:

```dockerfile
FROM stagex/pallet-rust@sha256:<verified-digest> AS build
```

Repeat for every `FROM` and every `COPY --from=stagex/...` dependency that must be part of the reproducible input set. For examples, placeholders are acceptable only when the surrounding text explicitly says to replace them with verified digests.

## Pallet Selection

Use the smallest pallet that contains the build tools needed:

| Need | Typical StageX image |
| --- | --- |
| Rust application | `stagex/pallet-rust` |
| Go application | `stagex/pallet-go` |
| Node.js application | `stagex/pallet-nodejs` |
| Python application | `stagex/pallet-python` |
| C/C++ single compiler invocation | `stagex/pallet-gcc` or `stagex/pallet-clang` |
| C/C++ with `configure`, `make`, `tar`, shell tooling | `stagex/pallet-gcc-gnu-busybox` or `stagex/pallet-clang-gnu-busybox` |
| C/C++ with CMake | `stagex/pallet-gcc-cmake-busybox` or `stagex/pallet-clang-cmake-busybox` |
| C/C++ with Meson | `stagex/pallet-gcc-meson-busybox` |

Inspect the current package page or Containerfile before assuming a tool exists. StageX package composition is explicit: missing build dependencies are added with OCI-native `COPY --from=stagex/core-... . /`, not with an in-container package manager.

## Determinism Rules

Apply these rules before language-specific details:

- Set `SOURCE_DATE_EPOCH` (fixed `1`, or the commit timestamp). Setting it as `ENV` only normalizes compiler timestamps — for a deterministic OCI tarball also pass it at the buildx invocation with `rewrite-timestamp=true` (see OCI Tarball Determinism below).
- Pin the build platform, normally `--platform linux/amd64` for Caution examples unless the user requests another target.
- Run dependency resolution before the container build; do not fetch dependencies inside the reproducible build stage.
- Use `RUN --network=none` for compile steps that should be hermetic.
- Avoid build scripts that read wall-clock time, hostnames, absolute host paths, usernames, random data, locale-specific ordering, or CPU-specific flags.
- Use stable archive extraction and verify vendored tarballs with SHA256 before unpacking.
- Do not use `curl | sh`, unpinned `git clone`, floating tags, or package manager installs inside the build.
- Prefer JSON-form `RUN` when an image entrypoint/shell is uncertain; otherwise inspect the pallet and choose a busybox/gnu variant.

## Rust Pattern

> **Validation scope:** the Rust-specific flags, arch handling, and the OCI-export
> and verification sections below have been confirmed byte-for-byte reproducible
> only for `pallet-rust` (linux/amd64, two no-cache rebuilds compared with `cmp`).
> The Go and C/C++ patterns have **not** been put through the same proof. Treat
> the techniques below as Rust-validated; re-verify before claiming them for
> other toolchains.

Use `pallet-rust` for normal Cargo builds. It includes Cargo and a shell via its current pallet composition. StageX's Rust toolchain currently patches musl target defaults during toolchain build, so explicitly set static linking when the final image should contain only the binary.

```dockerfile
FROM stagex/pallet-rust@sha256:<verified-pallet-rust-digest> AS build
ARG TARGETARCH

WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates

ENV CARGO_TARGET_DIR=/target
ENV CARGO_INCREMENTAL=0
ENV RUSTFLAGS="-C codegen-units=1 -C target-feature=+crt-static -C strip=symbols --remap-path-prefix=/app=. --remap-path-prefix=/target=target"

# Resolve + download deps in a layer that is allowed network access.
RUN triple="$([ "$TARGETARCH" = arm64 ] && echo aarch64 || echo x86_64)-unknown-linux-musl" && \
	cargo fetch --locked --target "$triple"

# Compile hermetically: no network, only the fetched/locked deps.
RUN --network=none <<-'EOF'
	set -eux
	triple="$([ "${TARGETARCH}" = arm64 ] && echo aarch64 || echo x86_64)-unknown-linux-musl"
	cargo build --frozen --release --target "${triple}" --bin myapp
	install -Dm755 "/target/${triple}/release/myapp" /myapp
EOF

FROM scratch AS run
COPY --from=build /myapp /myapp
ENTRYPOINT ["/myapp"]
```

Why these specifics matter for Rust determinism:

- **`ARG TARGETARCH`, not `uname -m`.** `TARGETARCH` is the target BuildKit injects from `--platform`; it is correct even when the build runs under emulation, and it matches StageX's own `core/rust/Containerfile`. `uname -m` couples the target triple to runtime introspection of a possibly-emulated host.
- **`CARGO_INCREMENTAL=0`.** Incremental compilation caches are a known source of non-reproducible output.
- **`-C codegen-units=1`.** Multi-unit codegen parallelism can reorder output.
- **`--remap-path-prefix`.** Removes absolute build paths embedded in the binary (the "absolute host paths" hazard in the determinism rules).
- **`-C strip=symbols`.** Drops symbol tables that can carry build-host detail.
- **`cargo fetch --locked` then `cargo build --frozen --network=none`.** A network-allowed fetch layer followed by a hermetic compile layer. `Cargo.lock` pins versions and checksums, so the fetch is reproducible without committing a `vendor/` dir.

Stricter offline alternative — commit a vendored tree instead of fetching:

```bash
cargo vendor vendor/   # then commit Cargo.lock, vendor/, .cargo/config.toml
```

```toml
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"
```

For Rust reproducibility issues, check for `build.rs` scripts embedding timestamps, host paths, `git describe`, or CPU-specific codegen. Keep `codegen-units`, target, and feature flags stable across reproductions.

## OCI Tarball Determinism (buildx, Rust-validated)

Setting `SOURCE_DATE_EPOCH` in the Containerfile normalizes timestamps the
*compiler* writes, but it does **not** normalize the layer timestamps in an
exported OCI tarball. To get a bit-identical tarball, pass the epoch at the
buildx invocation and let buildx rewrite layer timestamps:

```bash
SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct) docker buildx build \
	--platform linux/amd64 \
	--target run \
	--output type=oci,dest=dist/myapp.oci.tar,rewrite-timestamp=true \
	-f Containerfile .
```

Timestamp policy — two valid choices:

- **Fixed epoch (`SOURCE_DATE_EPOCH=1`):** simplest; every build of unchanged
  inputs is identical regardless of commit. Good default.
- **Commit-timestamp epoch (`git log -1 --pretty=%ct`):** ties each artifact to
  its source commit, so every commit yields a distinct but deterministic
  artifact. Record the expected hashes per commit
  (`checksums/sha256sums-<gitrev>.txt`). Reproduce by checking out the **exact
  source commit** named in the checksum file — a later commit that only records
  checksums gets a new timestamp and therefore a different artifact, so verify
  from the source commit, not the repository tip. Tag published commits so
  releases have a stable pointer.

## Verifying Reproducibility (Rust-validated)

A reproducibility claim needs evidence, not assertion. The strong check is two
independent no-cache builds compared byte-for-byte:

```bash
EPOCH=$(git log -1 --pretty=%ct)
for d in a b; do
	SOURCE_DATE_EPOCH=$EPOCH docker buildx build --no-cache \
		--platform linux/amd64 --target run \
		--output type=oci,dest=/tmp/repro-$d/myapp.oci.tar,rewrite-timestamp=true \
		-f Containerfile .
done
cmp /tmp/repro-a/myapp.oci.tar /tmp/repro-b/myapp.oci.tar \
	&& echo REPRODUCIBLE
```

Confirm both passes actually recompiled (grep the build log for the compile
step, not `CACHED`) — otherwise the second build proved nothing. Once proven,
record the hash and gate future rebuilds against it (`shasum -a 256 -c`),
failing non-zero on any mismatch.

## Go Pattern

Use `pallet-go`; StageX configures Go with deterministic defaults such as `SOURCE_DATE_EPOCH=1`, `GOTOOLCHAIN=local`, and `LDFLAGS="-w -s -buildid="`, but keep explicit flags in application builds.

Vendor modules first:

```bash
go mod vendor
```

Build without network:

```dockerfile
FROM stagex/pallet-go@sha256:<verified-pallet-go-digest> AS build

ENV SOURCE_DATE_EPOCH=1
ENV CGO_ENABLED=0
ENV GOOS=linux
ENV GOARCH=amd64

WORKDIR /app
COPY . .

RUN --network=none \
	go build -mod=vendor -trimpath -buildvcs=false -ldflags="-s -w -buildid=" -o /myapp .

FROM stagex/core-filesystem@sha256:<verified-core-filesystem-digest> AS run
COPY --from=build /myapp /app/myapp
ENTRYPOINT ["/app/myapp"]
```

If CGO is required, use StageX C/C++ dependencies explicitly and pin them by digest. Otherwise keep `CGO_ENABLED=0` for a static, smaller runtime.

## C/C++ Pattern

Choose a busybox/gnu pallet when the build needs shell scripts, `configure`, `make`, `tar`, or similar tooling. Vendor source archives outside the build and verify them inside the build.

```dockerfile
FROM stagex/pallet-gcc-gnu-busybox@sha256:<verified-digest> AS build

ENV SOURCE_DATE_EPOCH=1

WORKDIR /build
COPY project-1.2.3.tar.gz .

RUN --network=none <<-EOF
	set -eux
	echo "<sha256>  project-1.2.3.tar.gz" | sha256sum -c
	tar xzf project-1.2.3.tar.gz
	cd project-1.2.3
	./configure --disable-shared --enable-static
	make -j"$(nproc)"
	strip ./mybin
	cp ./mybin /mybin
EOF
```

StageX has no runtime package manager inside pallets. If a library is missing, either disable that feature or add/build the dependency explicitly with pinned StageX `core-*` images or vendored source.

## Runtime Base

Use one of these patterns:

- `FROM scratch`: only for a pure static binary with no runtime filesystem needs.
- `stagex/core-filesystem`: for `/etc/passwd`, `/tmp`, `HOME`, locale/timezone defaults, or a basic filesystem layout.

`stagex/core-filesystem` sets `USER 1000:1000` and `ENTRYPOINT ["/bin/sh"]`; always override `ENTRYPOINT` for app images:

```dockerfile
FROM stagex/core-filesystem@sha256:<verified-digest>
COPY --from=build /myapp /app/myapp
ENTRYPOINT ["/app/myapp"]
```

## Procfile

For Caution, add a `Procfile` matching the final image entrypoint/command. Example:

```procfile
web: /app/myapp
```

If the final image uses `ENTRYPOINT ["/app/myapp"]`, keep the Procfile consistent with how Caution expects to start the process for the selected deployment model.

## Verification Checklist

Before calling a build Caution/verifiable-compute ready, check:

- All StageX images are pinned by digest, including `COPY --from=stagex/...` dependencies.
- Source is tied to immutable commits or committed local files.
- Rust `Cargo.lock`, Go `vendor/`, C/C++ tarballs, and checksums are committed.
- Compile steps use `RUN --network=none`.
- No step downloads mutable dependencies at build time.
- `SOURCE_DATE_EPOCH` is set.
- Target architecture is explicit and matches the deployment.
- Final image overrides inherited shell entrypoints.
- `Procfile` exists for Caution.
- A clean rebuild on another machine or builder produces the same application artifact hash.

## Review Red Flags

Flag these as correctness issues:

- Floating `FROM stagex/...` in production snippets.
- Hardcoded digest copied from stale docs without verification.
- `cargo build` without `--frozen` or vendored dependencies.
- `cargo`/Rust build selecting the target triple from `uname -m` instead of `ARG TARGETARCH`.
- Rust build missing `CARGO_INCREMENTAL=0` or `-C codegen-units=1` when reproducibility is required.
- `go build` without `-mod=vendor`, `-trimpath`, or `-buildid=`.
- Network access during compile.
- `COPY . .` before generating or checking lockfiles.
- OCI tarball export without `rewrite-timestamp=true` (or `SOURCE_DATE_EPOCH` not passed at the buildx invocation) — the binary may be deterministic while the tarball is not.
- A "reproducible" claim with no two-build `cmp` (or equivalent) evidence.
- Runtime images that inherit `stagex/core-filesystem` shell entrypoint.
- Claims that attestation proves source provenance without reproducible rebuild and PCR comparison.
