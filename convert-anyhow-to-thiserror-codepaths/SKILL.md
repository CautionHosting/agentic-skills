---
name: convert-anyhow-to-thiserror-codepaths
description: >-
    Walk the full call graph of a given Rust function and convert every
    reachable repo function (all codepaths, excluding vendored dependencies)
    from anyhow error handling to typed thiserror errors, spawning one
    rust-code-writer subagent per function, strictly sequentially. Use when
    the user asks to convert a function AND everything it calls from anyhow
    to thiserror, or wants a whole call tree migrated to typed errors (e.g.
    "convert this function and its codepaths", "convert the call graph of X",
    "migrate X's call tree off anyhow").
license: MIT
---

# Convert Function and All Codepaths from anyhow to thiserror

Convert a function AND every function it transitively calls (its codepaths) from the legacy `anyhow` error pattern to typed `thiserror` errors. The conversion itself is always delegated to `rust-code-writer` subagents — one per function, spawned strictly sequentially — and each subagent loads and follows the `convert-anyhow-to-thiserror` skill. This skill only orchestrates: discover the codepaths, order them, spawn subagents, and summarize. It never converts code itself.

## Out of scope

- **Vendored dependencies** — anything under a `vendor/` path segment is never walked, resolved to, or converted.
- **`target/`, std, and external crates** — call targets that resolve there are treated as leaves.
- **Unresolvable call targets** — trait methods, `dyn` receivers, closures, and macro-generated calls are treated as leaves and skipped; do not spend time on them.

## Phase 1 — Discover codepaths (no subagents)

1. **Determine what to surveil.** If the user gave a function name, use it. If not → ask the user, then continue.
2. **Locate the entry function.** If the user gave a file, use it. Otherwise grep the workspace `src/` directories (excluding `vendor/`) for `fn <name>`. Exactly one match → use it. Multiple matches → ask the user which one. No match → stop and report.
3. **Depth-first walk from the entry.** Maintain two pieces of state:
   - `visited`: set of `(file, function name)` — guarantees termination on recursion and shared callees; never re-visit a function.
   - `order`: post-order list — a function is appended only after all its resolved callees have been visited, so conversions happen callees-first, callers-last. Cycle ordering is best-effort (both members still get converted).
4. **Extract call targets from each function body:**
   - Candidates: bare calls `ident(`, qualified calls `path::ident(`, method calls `receiver.ident(` (resolve only when the receiver's type and an inherent repo impl are both obvious — otherwise skip).
   - Ignore macros (`name!(...)`), closures, and `.await`.
5. **Resolve each candidate to a repo definition:**
   - Resolve paths through the file's `use` imports first (`use crate::deployment;` → `deployment::x`), then `crate::`, `super::`, `self::`, then workspace crate names.
   - Search for `fn <name>` within the same crate first, then the rest of the workspace `src/` — always excluding `vendor/`.
   - Exactly one non-vendor definition → recurse into it. Ambiguous (same name in several modules, no import to disambiguate) or outside the workspace → treat the call as a leaf.
6. **Filter:** keep only functions that still use anyhow patterns (`anyhow::Result`, `.context(`, `.with_context(`, `bail!`, `anyhow::Error`). Functions that are already typed (including an already-typed entry) are noted but not scheduled for conversion — their codepaths are still walked.

The result is an ordered list of `(file, function, crate)` entries to convert.

## Phase 2 — Convert sequentially (subagents)

For each function in the ordered list:

1. Spawn exactly ONE `rust-code-writer` subagent via the Task tool, using the prompt template below. Wait for its final message before starting the next. **Never put two Task invocations in the same message** — that runs them in parallel, which is forbidden here.
2. When the subagent reports `SKIPPED <file>:<function> — <reason>`, record the reason and continue to the next function. Do NOT invent a workaround or convert the function yourself.
3. Spot-check each conversion: grep the converted function's body for anyhow patterns. If anyhow remains inside that function's body, note it in the final summary (one line); do not re-spawn.

## Subagent prompt template

Use this prompt, filling in the three placeholders (`<file>`, `<function>`, `<crate>`):

```
Convert one Rust function from anyhow-style error handling to a typed
thiserror error, as part of a larger codepath migration.

1. Load the `convert-anyhow-to-thiserror` skill and follow it exactly.
2. Convert ONLY the function <function> in <file>.
3. Callees of this function may already have been converted to typed errors.
   Adapt their call sites with `.map_err(...)` per the skill. Do NOT modify
   any other function — neither callees nor callers — even if they still use
   anyhow.
4. Verify with `cargo check -p <crate>` (and `cargo clippy -p <crate>` when it
   is quick). If the crate has pre-existing errors unrelated to this function,
   note that rather than trying to fix it.
5. Be brief. End your final message with exactly one of:
   CONVERTED <file>:<function>
   SKIPPED <file>:<function> — <one-line reason>
   plus at most one additional line for anything unusual (e.g. anyhow remains
   in the body, pre-existing build errors). No further prose.
```

## Final summary (brief)

Report to the user in compact form:

- One line per converted function: `CONVERTED <file>:<function>`
- One line per skipped function with its reason
- One line for each function with anyhow still present in its converted body
- Optionally, one line for the count of unresolvable calls treated as leaves

Do not restate the subagent reports verbatim beyond these lines.

## Constraints

1. **Sequential subagents only.** One Task invocation at a time; wait for completion before the next. Never parallel.
2. **One function per subagent.** Each subagent converts exactly one function and nothing else.
3. **Vendored code is out of scope.** Never walk, resolve to, or convert anything under a `vendor/` path segment.
4. **Orchestrate, don't convert.** All conversions happen in the subagents. If a subagent reports a conflict, surface it and move on.
5. **Terminate.** `visited` guarantees the walk terminates on recursion and shared callees; never re-visit a function.
6. **Resolve pragmatically.** Aim for complete coverage with reasonable effort; ambiguous or external targets are leaves, not blockers.
7. **Stop on total failure.** If the entry function cannot be located, or no codepaths can be resolved, stop and report rather than guessing.
