# Enclave Dev Skills

AI assistant skills for building and debugging apps on the [Caution](https://caution.co) verifiable enclave platform. Published at [codeberg.org/caution/agentic-skills](https://codeberg.org/caution/agentic-skills).

## Skills

| Skill | Audience | What it covers |
|---|---|---|
| [`stagex-reproducible-builds`](./stagex-reproducible-builds/SKILL.md) | App builders | Reproducible, verifiable container images with [StageX](https://stagex.tools) — pallet selection, digest pinning, hermetic Rust/Go/C/C++ builds, PCR reproducibility verification |
| [`caution-platform`](./caution-platform/SKILL.md) | App builders | Authoring `caution.hcl`, deploying and debugging Caution enclave apps — local QEMU, AWS Nitro, attestation testing, Locksmith secrets, STEVE encryption, PCR verification |
| [`caution-local-dev`](./caution-local-dev/SKILL.md) | Platform devs | Running the Caution **platform itself** locally — api/gateway/postgres, Docker cgroup fixes, alpha/beta codes, e2e tests, image rebuilds |
| [`webauthn-passkeys`](./webauthn-passkeys/SKILL.md) | Platform devs | Implementing, reviewing, and debugging the gateway's WebAuthn/passkey auth — webauthn-rs 0.5 ceremonies, rpId/origin config, UV policy, challenge lifecycle, credential/session storage, BE/BS flags, recovery |
| [`fj-codeberg`](./fj-codeberg/SKILL.md) | Everyone | PRs, issues, releases, and repo ops on Codeberg via the `fj` CLI — required for all caution repos since `gh` can't reach Forgejo |

`caution-platform` and `caution-local-dev` target different audiences: the former is for **deploying customer enclave apps**, the latter is for **developing the platform itself**. `webauthn-passkeys` is also platform-dev, scoped to the gateway's authentication code. `stagex-reproducible-builds` provides the reproducible image foundation that `caution-platform` deploys. `fj-codeberg` is the glue for any Codeberg repository operation across all of them.

## Install

### Claude Code

Clone the repository and copy each complete skill directory so referenced helper
scripts are installed alongside `SKILL.md`:

```bash
git clone https://codeberg.org/caution/agentic-skills.git
cd agentic-skills

for skill in stagex-reproducible-builds caution-platform caution-local-dev webauthn-passkeys fj-codeberg; do
  mkdir -p ~/.claude/skills/$skill
  cp -R $skill/. ~/.claude/skills/$skill/
done
```

### Codex

Clone this repo, then copy the skill folders into `~/.codex/skills` so Codex can discover both `SKILL.md` and `agents/openai.yaml`:

```bash
git clone https://codeberg.org/caution/agentic-skills.git
cd agentic-skills

for skill in stagex-reproducible-builds caution-platform caution-local-dev webauthn-passkeys; do
  mkdir -p ~/.codex/skills/$skill
  cp -R $skill/. ~/.codex/skills/$skill/
done
```

> `fj-codeberg` has no `agents/openai.yaml` and is skipped for Codex — it works fine via Claude Code or by running `fj` directly.

### Crush

Crush uses a local skills directory (default `~/.config/crush/skills/`):

```bash
git clone https://codeberg.org/caution/agentic-skills.git
cd agentic-skills

for skill in stagex-reproducible-builds caution-platform caution-local-dev webauthn-passkeys fj-codeberg; do
  mkdir -p ~/.config/crush/skills/$skill
  cp -R $skill/. ~/.config/crush/skills/$skill/
done
```

## Skill structure

```
skill-name/
  SKILL.md          # Frontmatter (name, description) + full procedure
  agents/
    openai.yaml     # Codex agent interface (display name, default prompt)
  scripts/          # Helper scripts referenced by the skill (caution-local-dev only)
```

`agents/openai.yaml` and `scripts/` are optional — only `SKILL.md` is required.
