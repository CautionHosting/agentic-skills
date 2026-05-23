# Enclave Dev Skills

Claude Code skills for building and debugging apps on the [Caution](https://caution.co) verifiable enclave platform.

## Skills

### [`stagex-reproducible-builds`](./stagex-reproducible-builds/SKILL.md)

Reproducible, verifiable container images with [StageX](https://stagex.tools).

- Rust, Go, C/C++ build patterns with full vendoring
- Pallet selection and digest pinning
- `SOURCE_DATE_EPOCH`, `RUN --network=none`, hermetic builds
- Caution `Procfile` and PCR verification checklist

### [`caution-platform`](./caution-platform/SKILL.md)

Deploy and debug Caution enclave apps locally and on AWS Nitro.

- Local QEMU debugging on OrbStack (Mac Silicon + ARM64 aware)
- Nitro bzImage vs standard x86_64 kernel — when and how to get each
- Attestation endpoint testing (`/attestation` request format, expected errors)
- Production health check failures, SSH debug mode, vsock and service logs

## Install

```bash
for skill in stagex-reproducible-builds caution-platform; do
  mkdir -p ~/.claude/skills/$skill
  curl -sL https://raw.githubusercontent.com/vkobel/enclave-dev-skills/main/$skill/SKILL.md \
    -o ~/.claude/skills/$skill/SKILL.md
done
```
