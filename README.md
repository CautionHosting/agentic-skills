# Enclave Dev Skills

Claude Code and Codex skills for building and debugging apps on the [Caution](https://caution.co) verifiable enclave platform.

## Skills

### [`stagex-reproducible-builds`](./stagex-reproducible-builds/SKILL.md)

Reproducible, verifiable container images with [StageX](https://stagex.tools).

- Rust, Go, C/C++ build patterns with full vendoring
- Pallet selection and digest pinning
- `SOURCE_DATE_EPOCH`, `RUN --network=none`, hermetic builds
- The `Containerfile`; PCR reproducibility verification checklist (`caution.hcl` authoring lives in `caution-platform`)

### [`caution-platform`](./caution-platform/SKILL.md)

Write the Caution `caution.hcl`, and deploy/debug enclave apps locally and on AWS Nitro.

- `caution.hcl` authoring — unit command, container input, ports, resources, features
- Local QEMU debugging on a Linux host, or a Linux amd64 VM on macOS
- Nitro bzImage vs standard x86_64 kernel — when and how to get each
- Attestation endpoint testing (`/attestation` request format, expected errors)
- Production health check failures, SSH debug mode, vsock and service logs

## Install For Claude Code

```bash
for skill in stagex-reproducible-builds caution-platform; do
  mkdir -p ~/.claude/skills/$skill
  curl -sL https://codeberg.org/caution/agentic-skills/raw/branch/main/$skill/SKILL.md \
    -o ~/.claude/skills/$skill/SKILL.md
done
```

## Install For Codex

Clone this repo, then copy the skill folders into `~/.codex/skills` so Codex can discover both `SKILL.md` and `agents/openai.yaml`:

```bash
git clone https://codeberg.org/caution/agentic-skills.git
cd agentic-skills

for skill in stagex-reproducible-builds caution-platform; do
  mkdir -p ~/.codex/skills/$skill
  cp -R $skill/. ~/.codex/skills/$skill/
done
```
