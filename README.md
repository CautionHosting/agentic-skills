# Caution Agentic Skill

AI assistant skills for building, operating, and maintaining Caution software and verifiable enclave applications. Published at [codeberg.org/caution/agentic-skills](https://codeberg.org/caution/agentic-skills).

## Skills

| Skill | Audience | What it covers |
|---|---|---|
| [`stagex-reproducible-builds`](./stagex-reproducible-builds/SKILL.md) | App builders | Reproducible, verifiable container images with [StageX](https://stagex.tools) — pallet selection, digest pinning, hermetic Rust/Go/C/C++ builds, PCR reproducibility verification |
| [`caution-platform`](./caution-platform/SKILL.md) | App builders | Authoring `caution.hcl`, deploying and debugging Caution enclave apps — local QEMU, AWS Nitro, attestation testing, Locksmith secrets, STEVE encryption, PCR verification |
| [`caution-local-dev`](./caution-local-dev/SKILL.md) | Platform devs | Running the Caution **platform itself** locally — api/gateway/postgres, Docker cgroup fixes, alpha/beta codes, e2e tests, image rebuilds |
| [`dterror`](./dterror/SKILL.md) | Rust devs | Designing function-specific typed errors with thiserror and dterror 0.3 |
| [`convert-anyhow-to-thiserror`](./convert-anyhow-to-thiserror/SKILL.md) | Rust devs | Converting one anyhow-returning function to a typed dterror error |
| [`convert-anyhow-to-thiserror-codepaths`](./convert-anyhow-to-thiserror-codepaths/SKILL.md) | Rust devs | Migrating an entry function's repo-local anyhow call graph one function at a time |
| [`fj-codeberg`](./fj-codeberg/SKILL.md) | Everyone | PRs, issues, releases, and repo ops on Codeberg via the `fj` CLI — required for all caution repos since `gh` can't reach Forgejo |

`caution-platform` and `caution-local-dev` target different audiences: the former is for **deploying customer enclave apps**, the latter is for **developing the platform itself**. `stagex-reproducible-builds` provides the reproducible image foundation that `caution-platform` deploys. The three error-handling skills cover typed-error design, single-function conversion, and call-graph migration. `fj-codeberg` is the glue for any Codeberg repository operation across all of them.

## Install

### Claude Code

Clone the repository and copy each complete skill directory so referenced helper
scripts are installed alongside `SKILL.md`:

```bash
git clone https://codeberg.org/caution/agentic-skills.git
cd agentic-skills

for skill_dir in */; do
  [ -f "${skill_dir}SKILL.md" ] || continue
  skill=${skill_dir%/}
  mkdir -p ~/.claude/skills/$skill
  cp -R $skill/. ~/.claude/skills/$skill/
done
```

### Codex

Clone this repo, then copy every complete skill folder into `~/.codex/skills`:

```bash
git clone https://codeberg.org/caution/agentic-skills.git
cd agentic-skills

for skill_dir in */; do
  [ -f "${skill_dir}SKILL.md" ] || continue
  skill=${skill_dir%/}
  mkdir -p ~/.codex/skills/$skill
  cp -R $skill/. ~/.codex/skills/$skill/
done
```

### Crush

Crush uses a local skills directory (default `~/.config/crush/skills/`):

```bash
git clone https://codeberg.org/caution/agentic-skills.git
cd agentic-skills

for skill_dir in */; do
  [ -f "${skill_dir}SKILL.md" ] || continue
  skill=${skill_dir%/}
  mkdir -p ~/.config/crush/skills/$skill
  cp -R $skill/. ~/.config/crush/skills/$skill/
done
```

## Skill structure

```
skill-name/
  SKILL.md          # Frontmatter (name, description) + full procedure
  agents/           # Optional agent metadata
    openai.yaml
  references/       # Optional reference material
  scripts/          # Optional helper scripts
```

`agents/`, `references/`, and `scripts/` are optional — only `SKILL.md` is required.
