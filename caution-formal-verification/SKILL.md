---
name: caution-formal-verification
description: Use when adding, migrating, simplifying, debugging, or reviewing Verus proofs in Caution Rust projects, including wardend and bootproof. Covers production-code contracts, security trust boundaries, human-readable proofs, targeted tests, and minimal reviewable PRs. Coordinates related skills without replacing repository policy.
metadata:
  version: 1.0.0
---

# Caution formal verification

Use for Caution proof implementation or review. This adapts VOSTD/Asterinas and
KVerus conventions, not upstream endorsement or an upstream command bundle.

## Scope and authority

- Read applicable repository instructions first. Identify modules/functions,
  production callers, approved base/PR, requirements, budget, and stop conditions.
- Repository policy wins: wardend forbids `cargo fmt`. Never autoexecute upstream
  skill commands or install tools. Network access and source uploads require
  applicable authorization. Do not assume upstream scripts or dependencies exist.
- Preserve useful prior work separately by reference or an approved branch,
  not giant archived diffs in the deliverable.

## Contracts and implementation

- Prove actual production bodies, not an unconnected mirror. Trace each named
  requirement to its executable body and contract, including acceptance AND
  rejection, frame conditions, overflow, panic behavior, and termination.
  Reject vacuous preconditions. At native-to-verified calls, establish required
  conditions by proof or runtime checks; an annotation does not enforce them.
- Never weaken contracts merely to pass. Introducing or strengthening assumptions,
  axioms, `external_body`, or trusted specifications requires explicit approval.
  Centralize narrow trust boundaries, check their actual source version, and
  constrain applicable types/architectures. Model external preconditions,
  results, mutations, panic and termination conditions faithfully.
- Separate parsing correctness, cryptographic correctness, security properties,
  and TEE/attestation claims. A parser proof proves neither cryptographic
  soundness nor hardware trust. State exclusions and remaining trust explicitly.
- Preserve runtime behavior, public APIs, and error semantics. Justify necessary
  executable rewrites against the baseline and exercise public callers. Inspect
  side effects, control flow, visibility, mutation, and concurrency where relevant.

## Proof style and durable documentation

- Reuse `vstd` and existing models. Keep local specifications private/closed
  unless callers need their definitions to discharge a public contract. Keep
  executable/spec/proof sections distinct, and lemmas small. Bound useful
  invariants precisely rather than accumulating redundant assertions.
- Where the pinned toolchain supports them, prefer `returns` for exact equality,
  chained bounds, `Seq` range slicing, and payload-binding forms for variants.
  Preserve logical meaning and required executable bounds checks.
- Minimize comments: explain why, not SMT narration. For public verified APIs,
  use `Verified Properties` with only nontrivial Preconditions, Postconditions,
  Safety and Functional Correctness subsections. Panic freedom belongs under
  Safety. Keep private helper summaries brief; never label an unproved caller proved.
- Centralize toolchain setup and verification/test commands. Do not add
  per-module evidence READMEs, generated dumps, coverage ledgers, or source copies.

## Validation and handoff

1. Run actual pinned Verus on the production proof target. Distinguish a fresh
   proof run from a cache hit, compilation, or an excluded target.
2. Run full affected-package tests in native and proof-feature-erased builds,
   relevant integration tests, and useful edge cases. Compare the approved
   baseline. Follow applicable repository build/lint gates; explain any omitted
   broader gate rather than claiming a package check validates the entire project.
   Prefer independent expected values or backend interoperability to a test that
   repeats the implementation's own logic.
3. Inspect executable diffs and simplify redundant proof scaffolding without
   changing contracts. Recheck after changes. Record compact named
   requirement-to-check outcomes, exact commands, toolchain, trust exceptions,
   and failures in the PR, not repeated repository reports.
4. Stop once gates pass and output is unchanged. Automation must not trigger
   infinite replay. Honor budget/stop requests. Report blocked checks honestly.
   If parallel work is authorized, use bounded implementation workers with
   explicit ownership and coordinator review. Honor independent-review requests
   without substituting self-review or pretending review is complete.

## Conditional companion skills

- `dterror` when errors are touched: obey repository error conventions, never
  introduce an error migration just for proof. Conversion skills
  `convert-anyhow-to-thiserror` and `convert-anyhow-to-thiserror-codepaths` apply
  only to requested error migrations.
- `ryansquared-rust-style` when relevant/requested, `stagex-reproducible-builds`
  for reproducible builds, `webauthn-passkeys` for auth, `caution-local-dev`
  for platform runtime, and `caution-platform` for app configuration/deployment.

## Deliberate adaptations

Unlike VOSTD's `Origin Rust` source-copy comments, Caution keeps original bodies
in the baseline Git diff and explains required rewrites in the PR. Do not copy
whole functions into comments by default. Use upstream guidance on demand, not
an imported skill suite or an unreviewed automatic rule-update pipeline.
Keep this skill versioned in the agentic-skills repository, not in application
repositories; refresh installed copies when it changes. A skill guides agents
but does not enforce policy like a CI gate.

## References

Consulted Nov 11, 2026. Summarized conventions, not copied procedures:

- `https://github.com/asterinas/vostd/blob/main/AGENTS.md`
- `https://github.com/asterinas/vostd/blob/main/docs/coding-guidelines/README.md`
- `https://github.com/asterinas/vostd/blob/main/docs/coding-guidelines/maintainability.md`
- `https://github.com/asterinas/vostd/blob/main/docs/coding-guidelines/proof-engineering.md`
- `https://github.com/asterinas/KVerus/blob/main/skills/kverus-semantic-audit/SKILL.md`
- `https://github.com/asterinas/KVerus/blob/main/skills/kverus-postprocess/SKILL.md`
