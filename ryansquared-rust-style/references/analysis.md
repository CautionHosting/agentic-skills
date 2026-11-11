# Analysis and provenance

## Scope

This skill was derived from the local `~/git/keyfork` repository. No remote
refresh, checkout change, or Keyfork source modification was needed. The two
snapshots are pinned in `evidence.json`:

| Snapshot | Commit | Meaning at analysis time |
|---|---|---|
| `main` | `b2bc327fdfa4c55729161a28548c9aa5df9a9756` | Checked-out `main`, Keyfork v0.3.7 |
| `tui` | `c9d8eaa8f75679abc21a4e240eed4723c37eb7eb` | Local remote-tracking `origin/ryansquared/openpgp-tui`, newer unmerged work |

Git history identifies `ryan <ryan@distrust.co>` and
`ryan <ryan@caution.co>`. Branch names and merge messages reference `ryansquared`.
On checked-out `main`, `git shortlog -sne HEAD` attributes 447 commits to the
former address. Commit counts are not counts of independent style decisions.
Attribution does not establish who personally typed every line, whether tools
were used, or the author's endorsement of this analysis.

Both established mainline code and recent work were considered. The October
2026 TUI branch is relevant to error-design evolution, but its patterns must not
be described as already adopted throughout the repository.

## Method

1. Inspect workspace policy, author history, and the explicit developer guide.
2. Read representative domain types, ownership APIs, traits, I/O helpers,
   arithmetic repairs, docs, error types, and tests across several crates.
3. Check `git blame --line-porcelain` for attribution rather than treating every
   file in the repository as the requested author's work.
4. Compare the historical implementation with the newer TUI branch.
5. Record supporting source anchors and meaningful counterexamples. Each `R`
   heading in the skill maps to entries in `evidence.json`.
6. Separate descriptive observations from recommendations that reconcile those
   observations with current project policy and safe engineering practice.

The `PromptHandler` and terminal modules contain contributions from Danny Grove.
Only the Ryan-attributed trait and arithmetic regions are used as author
examples. In particular, the added column-selection UI is not attributed to Ryan.
The newer `keyfork-openpgp-card-sequoia` crate is an imported fork with upstream
copyright notices. An import committed by Ryan does not make its inherited style
his own, so that code is excluded from the personal-style evidence.

## Findings and confidence

| Rule | Confidence and basis | Representative evidence |
|---|---|---|
| R1 ownership/cost naming | Very strong: explicit developer guide, exercised by mnemonic APIs | E01, E02, E04, E09, E20 |
| R2 domain types | Strong recurring pattern, not an absolute ban on booleans/public fields | E03, E04, E18, E19 |
| R3 capability boundaries | Strong examples across algorithm, interaction, I/O, and TUI boundaries | E05-E08, E11, E18 |
| R4 readable control flow | Explicit preference for meaningful `else`, with both loops and iterator chains | E03, E04, E09, E10, E19 |
| R5 error design | Strong but evolving: explicit new TUI contract, clear older counterexamples | E15-E17, E19, E22 |
| R6 arithmetic semantics | Strong intentional history: multiple dedicated arithmetic-fix commits | E05, E07, E09, E12 |
| R7 contract documentation | Strong: workspace configuration and extensive public/module rustdoc | E02, E03, E05, E07, E08, E10, E16, E18-E20 |
| R8 resource/sensitive behavior | Concrete examples, not evidence of a universal or audited security policy | E13, E17, E19 |
| R9 behavioral tests | Strong: vectors, round trips, snapshots, parity, and newer real-binary tests | E03, E04, E07, E08, E14, E21 |
| R10 pragmatic lint policy | Explicit workspace choices, targeted allowances, and cleanup history | E10, E11 |

## Deliberate limits on imitation

- **Not a universal no-panic codebase.** Older code deliberately uses
  `keyfork_bug::bug!`, `expect`, and assertions. Some calls occur in
  deserialization. The transferable habit is explaining an invariant, not
  declaring all those panic sites safe or copying them into external-input paths.
- **Not uniformly dterror.** The new TUI explicitly adopts it, while the shared
  OpenPGP helper still has `#[from]` and anyhow-wrapping variants. Current project
  error policy determines what new work should use. The skill's dterror guidance
  complements the existing error skills rather than inventing a new convention.
- **Not a guarantee of allocation-free conversions.** The naming guide expresses
  intent. Older path addition clones despite consuming its receiver. Preserve
  useful ownership semantics, not that incidental inefficiency.
- **Not every Debug is redacted.** Extended private keys hide their key field,
  but mnemonic types derive Debug and the extended-key formatter prints other
  fields. Do not claim comprehensive secret-redaction or zeroization coverage.
- **Not proof that parsers are safe on all inputs.** The frame checksum helper
  slices before a conversion. Studying its public contracts and encoder does not
  certify its malformed-input behavior. This task did not change or audit it.
- **Not every existing test is a good fixture.** The async overflow test allocates
  approximately 4 GiB. The skill keeps the intent of boundary testing but rejects
  the unnecessary resource cost as a reusable default.
- **Not a blanket arithmetic-lint configuration.** Local arithmetic lint
  exceptions and fixes are evidence of attention to the issue, not proof that
  `arithmetic_side_effects` is enabled workspace-wide.
- **Not a claim of two independent crypto implementations.** The TUI uses GnuPG
  and Sequoia's `sq` as external consumers. `sq` shares the Sequoia ecosystem with
  the code under test, so describe independent front ends, not two wholly
  independent implementations.
- **Not a mandate for tiny functions, all-generics, all-iterators, all-early-returns,
  zero dependencies, or one exact import order.** The sampled code has meaningful
  counterexamples to those stereotypes.

Recommendations to preserve compatibility, use bounded tests, validate alternate
construction paths, and honor local security rules are adaptations for applying
this style responsibly. They are not represented as quotes or absolute personal
rules from the author.

## Reproducing the evidence

The JSON map contains exact source anchors, snapshot commits, rule IDs, and
historical commits. Use the pinned commit, not a moving branch name. For example:

```bash
git -C ~/git/keyfork show \
  b2bc327fdfa4c55729161a28548c9aa5df9a9756:docs/src/dev-guide/handling-data.md

git -C ~/git/keyfork blame --line-porcelain \
  c9d8eaa8f75679abc21a4e240eed4723c37eb7eb -- \
  crates/openpgp/keyfork-openpgp-tui/src/error.rs

git -C ~/git/keyfork show 8d3a512 -- \
  crates/util/keyfork-prompt/src/terminal.rs
```

If the local clone is absent, the installed skill remains usable as a standalone
style guide. Its source claims remain pinned to these snapshots, not whatever a
future checkout contains. Updating evidence should be an explicit review, not a
silent rewrite of provenance.
