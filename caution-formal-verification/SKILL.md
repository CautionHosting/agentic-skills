---
name: caution-formal-verification
description: Use for Verus implementation, migration, cleanup, or review in Caution Rust projects. Follow pinned VOSTD conventions and invoke upstream KVerus skills directly, with only Caution-specific commands, trust boundaries, and repository-policy exceptions.
metadata:
  version: 2.0.0
---

# Caution formal verification

This is an integration wrapper, not a replacement rulebook. Upstream VOSTD
conventions govern proof style; upstream KVerus skills provide the workflows.
Keep this wrapper in agentic-skills, never in application repositories.

## Required loading

1. Read the target repository's instructions and agree on scope, base, and budget.
2. Follow `references/upstream.md` to locate and validate the pinned installations.
   If unavailable, stop and report the missing dependency rather than substituting
   remembered rules. Setup requires authorization; merely loading this skill does
   not authorize downloads, installs, or running an end-to-end migration.
3. Read `$VOSTD_ROOT/AGENTS.md`, `docs/coding-guidelines/README.md`, and the linked
   guidelines relevant to the change. Those files, not a local paraphrase, are
   the normative style source. Follow `preserve-exec-code`, including adjacent,
   reason-first `Origin Rust:` comments. Git history is not a substitute.
4. Load `kverus-common` and the appropriate upstream skill: `kverus-migrate`,
   `kverus-spec`, `kverus-fix`, `kverus-eval`, `kverus-semantic-audit`,
   `kverus-postprocess`, `kverus-strip`, or `kverus-review`. Read their actual
   instructions and references before using their scripts. Use individual stages
   for bounded work; use `kverus-run` only for an authorized full migration.

## Caution integration and necessary exceptions

- Discover the real target verification command and toolchain from its docs.
  Wardend's parser pilot uses `bash tools/verify-wardenctl.sh` with `VERUS_ROOT`
  configured as in `docs/verification.md`; do not substitute VOSTD's build commands.
  Keep native-to-verified, cryptographic, and attestation trust boundaries explicit.
- Use the target's build/test gates in addition to Verus. Exercise public callers
  in native and proof-feature-erased builds where supported. Record named outcomes,
  proof scope, trust exceptions, and blocked gates in the PR. A cache hit, audit
  report, or skill quality score is not fresh solver evidence or a security proof.
- Respect repository instructions: Wardend forbids `cargo fmt`. Omit upstream
  formatter execution there and report that exception, not a successful format
  check. Follow upstream source-preservation comments and other style rules.
- VOSTD requires approval for new trusted assumptions or skipped bodies. That
  restriction also applies when `kverus-migrate` suggests `external_body`.
- Keep upstream files unchanged. Use pinned static guidance by default. Automatic
  rule refresh or `kverus-common-sync` must not silently change the adopted rules.
  Update revisions explicitly after reviewing upstream changes and compatibility.
- Agent-runtime policies still apply: do not spawn review/research workers where
  forbidden. Perform those steps in the coordinator instead; do not claim this
  satisfies an independent-model review request. Honor stop/budget limits.
- Put upstream reports and original-source snapshots in an external scratch
  directory, not the application PR. Do not commit dependencies or generated logs.
  Review any destructive restore/cleanup step before executing it.

These are integration constraints, not permission to silently depart from upstream
style. Report any additional conflict by guideline name and seek a decision.
Do not declare existing code upstream-compliant just because this wrapper is loaded.

## Companion skills

Use installed `dterror` for error changes, the `convert-anyhow-to-thiserror` skills
only for requested migrations, and `ryansquared-rust-style` when applicable.
Use `stagex-reproducible-builds`, `webauthn-passkeys`, `caution-local-dev`, or
`caution-platform` only for their corresponding build/auth/runtime/deployment work.
They supplement, rather than replace, the upstream verification rules.
