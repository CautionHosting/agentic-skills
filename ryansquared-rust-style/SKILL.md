---
name: ryansquared-rust-style
description: >-
  Write, refactor, or review Rust using the conventions evidenced in
  ryansquared's Keyfork contributions: ownership-revealing APIs, documented
  domain types, small capability traits, explicit control flow, operation-level
  error context, checked arithmetic, and behavior-focused tests. Use when asked
  for Ryan's Rust style or when matching these conventions in Keyfork. Complements
  dterror for error design, rather than replacing it.
license: MIT
metadata:
  version: 1.0.0
---

# Rust style from ryansquared's Keyfork work

Apply the design habits, not a mechanical imitation of every line. This is an
analysis of Git-attributed contributions, not a style guide endorsed by Ryan.

Read [the analysis](references/analysis.md) for provenance, confidence, exceptions,
and historical evolution. [The evidence map](references/evidence.json) pins each
rule to source symbols in two local Git snapshots. The newer snapshot is an
unmerged branch, not a claim about conventions already adopted on `main`.

## Precedence and workflow

1. Read the target repository's instructions, manifests, and neighboring code.
   Its security invariants, public API contracts, and error conventions win over
   this skill. Do not add dependencies or change behavior just to match a style.
2. Identify ownership, validation boundaries, failure modes, and observable
   behavior before choosing abstractions.
3. Apply the relevant rules below with the smallest coherent diff. Preserve
   serialization, protocol bytes, CLI output, and compatibility unless a change
   is requested. Do not turn a style task into a workspace-wide rewrite.
4. For Rust error work, load `dterror` when available and follow the applicable
   repository policy. For an anyhow migration, also load the appropriate
   `convert-anyhow-to-thiserror` skill. This skill does not redefine their APIs.
5. Validate behavior and lint the affected targets, including their tests and
   relevant features. Respect an explicit prohibition on running formatters.

## R1. Make ownership and cost visible in the API

**Strong evidence: an explicit author-written developer guide.** Use:

- `as_*(&self)` for a borrowed view of existing data, without allocation.
- `to_*(&self)` for a copied or converted owned value, preserving the receiver.
  A fixed-size array copy need not allocate on the heap.
- `into_*(self)` for consuming conversion. Move existing storage when possible,
  rather than cloning something the caller has already surrendered.
- A domain operation such as `seed()` for computation, rather than pretending
  every operation needs three ownership variants.
- `into_parts(self)` when several owned fields need to be extracted together.

Choose borrowed slices and paths when ownership is unnecessary. Use
`impl AsRef<T>` where accepting several representations is useful, then normalize
once near the entry point. Use `impl Into<T>` when storing an owned value. Do not
add all these variants to every type without a caller that needs them.

For example, this is an original, simplified illustration of the ownership rule:

```rust
pub struct Payload {
    bytes: Vec<u8>,
}

impl Payload {
    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        self.bytes.clone()
    }

    pub fn into_bytes(self) -> Vec<u8> {
        self.bytes
    }
}
```

Add appropriate rustdoc in real public APIs. Do not copy the historical
`DerivationPath::add` implementation's unnecessary cloning of a consumed value.

## R2. Give domain concepts types and conventional trait implementations

Represent concepts such as a derivation index, path, certificate source, or
application action as named types. Keep representation fields private or
`pub(crate)` where callers should pass through validation. Put checks in the
constructor or parser instead of distributing them across call sites.

Use `FromStr` for parsing and `Display` for human-readable formatting when those
operations fit. Supply `iter`, `len`, and `is_empty` together for collection-like
APIs. A consuming builder can return `Self` for deliberate chaining. Use enums
with variant-specific data instead of several flags and unrelated optional
fields when they represent mutually exclusive choices.

This is not a ban on booleans, public data-transfer fields, or ordinary structs.
Do not claim that deriving `Deserialize` automatically enforces a constructor's
invariants. Test and validate alternate construction paths as well.

## R3. Abstract real capabilities, not hypothetical frameworks

Keep domain logic in focused modules or crates, with small traits at actual
variation points. Keyfork's `PrivateKey` relates its public-key and error types
through associated types. Its `PromptHandler` supports different interaction
backends. These are distinct capabilities, not a general-purpose service layer.

- Use generics or `impl Trait` when the implementation is chosen statically.
- Use a trait object when the application actually selects a backend at runtime.
- Prefer an existing `Read`/`Write` interface to inventing a custom transport.
- Keep optional backends feature-gated and inherit workspace dependencies/lints
  where that is already the project convention.
- Separate event/state decisions from effects. The newer TUI returns `Action`
  values for work the outer loop performs, rather than mixing every external
  operation into key handling.

Do not split files or create a new crate solely to satisfy an arbitrary size
limit. This codebase also has substantial modules and long domain operations.

## R4. Write explicit, readable control flow

Use early returns for invalid inputs. Use `match` when it makes the alternatives
visible. Keep an `else` when it helps a reader follow two meaningful branches:
Ryan explicitly permits `clippy::redundant_else` for this reason.

Use iterator chains for straightforward transforms and fallible collection, but
ordinary loops for evolving state, streaming writes, and branch-heavy logic.
Introduce locals for meaningful intermediate results rather than compressing an
operation into a clever expression. Shadow a name when normalizing or narrowing
the same value, as in `let input = input.as_ref()`.

Follow surrounding import organization and formatting. Group related imports,
use local imports where a backend needs them, and avoid unrelated import churn.
There is no evidenced universal rule for one import order or derive order.

## R5. Model errors at the operation boundary and retain useful context

**Evolving convention.** Older Keyfork code mixes module-local `Error` enums,
`Result` aliases, `#[from]`, boxed errors, and some anyhow. The newer TUI explicitly
uses operation-level errors such as `SourceError`, `TerminalError`, and
`CertEditError`, with a top-level error that preserves the source chain.

For new code under the current dterror policy:

- Use an error type appropriate to the operation, with distinct failure modes
  where they matter to callers. Do not infer that every tiny helper needs a
  different type: the TUI shares operation-level types among related helpers.
- Retain the relevant non-secret path, identifier, or action as context.
- Use generated context constructors, commonly imported as `{Error}Ctx as Ctx`,
  with `.with_context(...)` at the failure site.
- Preserve the source and caller location. Use borrowed context when the error
  skill calls for it, rather than eagerly cloning on success.
- Follow `dterror` for struct-versus-enum, source-less failures, and exact syntax.

Do not reintroduce historical `#[from]`, string erasure, or anyhow merely to
imitate older files when the target project's current error policy forbids them.
Do not duplicate the source in an error's display text when the chain reports it.

## R6. Choose arithmetic behavior intentionally

Use checked arithmetic and fallible narrowing conversions where overflow means
invalid data or a protocol limit. Use saturation where clamping is the desired
behavior, such as terminal-space calculations. Do not saturate a frame length
or other security-sensitive bound to disguise invalid input.

A lint exception should be scoped to the justified operation or helper, with a
reason that states the invariant. Curve arithmetic and deliberately bounded test
math are not the same as unchecked external lengths. The historical reason text
is not always exemplary: state the actual proof rather than copying jokes.

These rules are supported by deliberate arithmetic-fix commits, not just by the
presence of Clippy annotations. Do not claim the workspace enables every lint
mentioned in a local allowance.

## R7. Document contracts and why the code looks this way

Use module rustdoc for purpose and boundaries. Document public types, variants,
and functions. Add `# Errors`, relevant `# Panics`, and short runnable examples
where they help a caller use the API correctly. Link named types and variants
with rustdoc references.

Explain constraints that are not evident from syntax: protocol limits, why a
buffer must be initialized, why an operation is refused, or why a fallback is
allowed only for one failure category. Do not replace useful reasoning with
comments that merely repeat the next line.

A documented panic is not permission to add one. Follow the target repository's
panic policy, and keep unexpected external input on a recoverable error path.

## R8. Make resource ownership and sensitive behavior explicit

The newer TUI uses an owning terminal-session guard with `Drop` cleanup and
explicit fallible suspend/resume operations. Use this pattern when a resource
must be restored even after an early return. Best-effort cleanup may deliberately
ignore failures in `Drop`; ordinary fallible operations should still report them.

Redact secret-bearing debug fields instead of deriving an indiscriminate
`Debug`. The historical extended-private-key formatter obscures the private key,
not every field: classify each field rather than treating the example as a
complete secret-handling policy.

Keep externally driven work bounded when applicable. The newer network helper
has an explicit timeout and read cap. Preserve refusal semantics: an unsupported
source is a typed error, not an undocumented fallback to different behavior.
These are observed design choices, not a security certification of Keyfork.

## R9. Test contracts with small, discriminating cases

Match the behavior under change with appropriate checks:

- Parse/format and encode/decode round trips.
- Invalid prefixes, boundary indices, incomplete input, and bad checksums.
- Known-answer vectors for algorithms, not just self-consistency.
- Sync/async equivalence where both implement the same protocol.
- A snapshot when exact serialized output is an intentional compatibility contract.
- For an interactive workflow, drive the real binary and inspect its output
  artifacts. The newer TUI also tests exports with independent consumers.

Keep unit tests close to their implementation or in a focused test module.
Tests may return `Result` and use `?`; fixture setup often uses `unwrap` or
`expect`. Do not extend that test-only convenience to untrusted runtime input.
Prefer asserting a returned error directly when testing refusal, rather than
copying the legacy habit of unwrapping it inside a `#[should_panic]` test.

Use bounded fixtures. Do not copy the historical multi-gigabyte allocation in
the frame overflow test. Choose a smaller test seam when one can exercise the
same limit without excessive memory or time.

## R10. Treat linting as feedback, not a reason to obscure intent

The sampled workspace denies `clippy::all`, warns on `pedantic` and missing
public documentation, and explicitly relaxes selected stylistic lints. Follow
the target repository's settings and commands rather than installing these
settings everywhere. Explain narrowly necessary suppressions.

After a Rust change, run the project's test and Clippy commands for affected
crates, with relevant features and test targets. Where no command is specified,
start with `cargo test -p <crate> --features <features>` and
`cargo clippy -p <crate> --all-targets --features <features> -- -D warnings`,
adapting omitted features appropriately. Put `$HOME/.cargo/bin` on `PATH` where
required. Run doctests for changed public examples. Do not run a formatter when
repository instructions forbid it. Report exactly what was and was not checked.

## Review checklist

- Do names and signatures reveal borrowing, copying, and consumption?
- Are domain invariants and validation boundaries clear, including deserialization?
- Does each abstraction correspond to a real capability or implementation choice?
- Is control flow easier to follow than a compact alternative?
- Are operation, cause, location, and safe context retained in errors?
- Do overflow, narrowing, and clamping have intentional semantics?
- Do docs explain the caller-visible contract and non-obvious constraints?
- Are cleanup, secrets, refusal, and resource limits handled deliberately?
- Do tests distinguish correct behavior from plausible but incorrect behavior?
- Is the diff scoped, compatible, and validated under the target repo's rules?
