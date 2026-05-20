# stagex-reproducible-builds

A [Claude Code skill](https://agentskills.io) for building reproducible, verifiable container images with [stagex](https://stagex.tools).

## What it covers

- **Rust** — `pallet-rust`, static musl target, cargo vendoring
- **Go** — `pallet-go`, CGO_ENABLED=0, go mod vendoring
- **C/C++** — `pallet-gcc-gnu-busybox`, source tarball vendoring with SHA256 verification
- Pallet selection guide
- Getting real digests (never guess)
- Choosing between `FROM scratch` and `stagex/core-filesystem`
- The `core-filesystem` ENTRYPOINT trap
- GCC 15 strictness fixes

## Install

```bash
# Claude Code
mkdir -p ~/.claude/skills/stagex-reproducible-builds
curl -sL https://raw.githubusercontent.com/vkobel/stagex-reproducible-builds/main/SKILL.md \
  -o ~/.claude/skills/stagex-reproducible-builds/SKILL.md
```

Once installed, Claude Code will automatically load it when you work on stagex-based Containerfiles.

## Context

Built from hands-on experience packaging apps for the [Caution](https://caution.co) verifiable enclave platform, where reproducible builds are required for attestation.
