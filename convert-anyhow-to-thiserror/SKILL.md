---
name: convert-anyhow-to-thiserror
description: >-
    Convert a function that returns anyhow::Result<T> (anyhow Result,
    .context(), bail!, with_context) into Result<T, FooError> where FooError is
    a new per-function error enum derived with thiserror and dterror's
    CtxError derive (dterror 0.3.0). Call sites wrap failures with
    .with_context(FooErrorCtx::...) instead of .map_err; variants carry
    #[location] and #[source] fields; axum handlers get an IntoResponse impl.
    Use when the user asks to convert a function from anyhow-style error
    handling to a typed Result<T, Error>, or mentions thiserror, dterror,
    typed errors, or removing anyhow from a function.
license: MIT
---

# Convert Function from anyhow to thiserror + dterror

Convert a single function from the legacy `anyhow` error pattern (`anyhow::Result<T>`, `.context("msg")?`, `bail!("msg")`) to `Result<T, FooError>` where `FooError` is a new error enum specific to that function, derived with `thiserror` (Display/Error) and `dterror::CtxError` (dterror 0.3.0). The derive generates a `{FooError}Ctx` type whose constructors turn `.with_context(Ctx::variant(...))?` call sites into self-documenting error wrapping: context is captured as typed fields instead of strings, the failing call site's location is recorded automatically, and the original error is stored in a `#[source]` field that is never interpolated into the display message.

## How dterror 0.3.0 works

- `#[derive(dterror::CtxError)]` is used alongside `thiserror::Error`. For an **enum** it generates a `{Error}Ctx<'ctx>` enum with one same-named variant per *constructible* variant, plus one associated constructor per Ctx variant named after the variant in `snake_case` (override with `#[context(constructor = "name")]`). A variant is constructible iff it has a `#[source]`/`#[from]` field; a constructible variant with no context fields gets a zero-argument constructor. Source-less variants and unit variants get no Ctx variant and no constructor — they are built by hand. An enum needs at least one source-bearing variant to derive `CtxError` at all; an error whose variants are all source-less (a leaf error) derives only `thiserror::Error`. For a **struct** it generates a `{Error}Ctx<'ctx>` struct with a `new(...)` constructor, typically used with the `{Error}Kind` split (see the `dterror` skill). The generated Ctx derives nothing by default; you opt into traits (e.g. `Clone`, `Debug`, `PartialEq`) with the container-level `#[context(derive(...))]` attribute, and everything the Ctx stores must implement the requested ones. Named fields only: tuple structs/variants and unions are rejected.
- Field markers (at most one `#[source]`/`#[from]` and at most one `#[location]` per struct or variant; `#[context(...)]` cannot be combined with them):
  - `#[source]`: stores the wrapped error. Under dterror this field must be exactly `dterror::BoxError` (an alias for `Box<dyn std::error::Error + Send + Sync + 'static>`) — the generated code moves a boxed trait object in, so typed source fields (e.g. `sqlx::Error`) are not possible. In a **struct** (see the `dterror` skill) the source may instead be `Option<dterror::BoxError>` when some failure modes are source-less; the derive wraps the captured source in `Some(...)`, optionally with the explicit `#[context(option)]` marker on the field.
  - `#[location]`: stores the caller's location as `dterror::Location` (an alias for `&'static std::panic::Location<'static>`), populated from `std::panic::Location::caller()` through `with_context`'s `#[track_caller]`. The alias cannot be used for the `::caller()` call itself — hand-built variants write `std::panic::Location::caller()` fully qualified.
  - `#[context(borrow = TargetType)]` (optional): the Ctx holds `&'ctx TargetType` instead of the owned value, so constructing the context on the Ok path allocates nothing; the reference is converted back to owned via `.into()` only if the error fires. The target must be a reference type (e.g. `Path`, `str`) and the field's owned type must be constructible from it via `Into`.
  - Every other field is a **context field**: an argument to the generated constructor (in declaration order, each as `impl Into<FieldType>`) and the only thing besides `{location:?}` that may be interpolated in `#[error()]`.
- `.with_context(...)` comes from `dterror::ResultExt` and works on any `Result<T, Old>` whose error converts into a `BoxError` (`Old: Into<BoxError>`). Every `std::error::Error + Send + Sync` value qualifies via std's `From<E>` blanket, and so does `anyhow::Error` — which does **not** implement `std::error::Error` but converts into exactly a `Box<dyn Error + Send + Sync + 'static>` via `anyhow::Error::into_boxed_dyn_error`. So the very function you are converting (which returns `anyhow::Result`) can be a source wrapped directly with `.with_context(...)`, as can `sqlx::Error` and other converted functions' typed errors. The target error type must also be `std::error::Error + Send + Sync + 'static`; the error itself never borrows (borrowing lives only in the Ctx).
- Call sites alias the generated type for brevity: `use FooErrorCtx as Ctx;`.

### Method-name collision with anyhow (mixed files)

`anyhow::Context` also defines a `with_context` method. In a file where `anyhow::Context` is in scope — directly or via glob, which is normal mid-migration while other functions are unconverted — a bare `.with_context(...)` call is ambiguous and fails to compile (E0034). There, write the dterror call fully qualified:

```rust
dterror::ResultExt::with_context(expr, Ctx::variant(args...))?;
```

In a file whose last anyhow use has been converted (no `anyhow::Context` import), bare `.with_context(Ctx::variant(...))?` works and is preferred. `use dterror::ResultExt;` is only needed for the bare-method form; the UFCS form does not need it.

## Reference

- **Struct/Kind and optional-source design decisions live in the `dterror` skill.** This skill covers the enum-per-function conversion (one variant per failure mode, `#[location]` + boxed `#[source]`). When the function's failures are one shape parameterized by a category — or some modes are source-less and you want to keep a shared `path`/key on the whole error — see the `dterror` skill for the `{Error}Kind` split and `Option<BoxError>` / `#[context(option)]` source handling.
- `dterror` 0.3.0 (git `main`, repo `git.distrust.co/public/dterror`; pinned in the workspace root `Cargo.toml`) — its lib.rs docs and `examples/full.rs` are the canonical examples: struct context with borrowed fields, enum context with per-variant constructors, zero-argument constructors for context-less variants, source-less variants built by hand, and a leaf error that is not derived from `CtxError` at all. When in doubt about generated names or validation rules, read the crate sources from the cargo git checkout (e.g. `~/.cargo/git/checkouts/dterror-*/<rev>/crates/dterror`; run `cargo vendor` if necessary - this is non-destructive). Note: a vendored `vendor/dterror` copy may be an older release without `CtxError`.
- Pre-existing repo conversions (`src/api/src/fully_managed_capacity.rs`, `src/api/src/eif_download.rs`, `src/api/src/organizations.rs`) use the older thiserror-only pattern (typed `#[source]` fields, `.map_err(...)` call sites). They remain valid; do not rewrite them when adapting callers. New conversions use dterror.
- Repo convention (AGENTS.md): one error enum per function; never include source errors in the display representation of new error types; `IntoResponse` for axum handlers with proper status codes.

## Dependency wiring

Before writing code, make sure the target crate can name `dterror`:

1. dterror is a workspace dependency pinned to git `main` (0.3.0) in the root `Cargo.toml`. Crates that already use it (`api`, `cli`, `gateway`) have `dterror = { workspace = true }` — nothing to do.
2. Otherwise add `dterror = { workspace = true }` to the crate's `[dependencies]`. Do not pin a crates.io version; only the workspace pin has the `CtxError` derive, `BoxError`, and `Location`.
3. `thiserror` is already a workspace dependency (`"1"`); dterror 0.3.0 works with it unchanged.

## Target pattern

```rust
use dterror::{BoxError, CtxError, Location}; // plus ResultExt when using bare .with_context(...)

#[derive(Debug, thiserror::Error, CtxError)]
pub(crate) enum FooError {
    #[error("failed to load {path} [{location:?}]")]
    LoadFile {
        path: std::path::PathBuf, // context field: constructor arg, interpolatable

        #[location]
        location: Location,

        #[source]
        source: BoxError,
    },

    #[error("resource {resource_id:?} not found [{location:?}]")]
    NotFound {
        resource_id: Uuid, // context field on a source-less variant

        #[location]
        location: Location,
    },
}

impl IntoResponse for FooError { // only when the function is an axum handler
    fn into_response(self) -> Response<Body> {
        let (status, body) = match &self {
            FooError::NotFound { .. } => (StatusCode::NOT_FOUND, "resource not found"),
            FooError::LoadFile { .. } => (StatusCode::INTERNAL_SERVER_ERROR, "internal error"),
        };
        (status, body).into_response()
    }
}
```

Call sites:

```rust
use FooErrorCtx as Ctx;

// Constructible variant (has a source): with_context does the wrapping.
// A constructible variant with no context fields takes no arguments: Ctx::commit().
let data = std::fs::read(path).with_context(Ctx::load_file(path))?;

// Source-less variant: built by hand, location supplied explicitly.
// Fully qualified: the dterror::Location alias cannot be used for ::caller().
return Err(FooError::NotFound { resource_id, location: std::panic::Location::caller() });
```

## Transformation steps

1. **Wire the dependency** (see Dependency wiring).
2. **Read the function** and identify its signature. `anyhow::Result<T>` is `Result<T, anyhow::Error>` — if the file does `use anyhow::Result;`, the return type will read `Result<T>`.
3. **Inventory every fallible call site** in the function body: `?`, `.context(...)?`, `.with_context(|| ...)?` (anyhow's closure form), `bail!`, `return Err(...)`, `Err(e).context(...)`. Each is a candidate variant.
4. **Name the error enum `{FunctionName}Error`** (PascalCase of the function name, matching `DownloadEifError`, `InitializeUserAccountError` style). Match the function's visibility: `pub` if the function is `pub`, otherwise `pub(crate)`; the generated `{FunctionName}ErrorCtx` gets the same visibility.
5. **Enumerate one variant per failure mode.**
   - Each distinct `.context("msg")` becomes its own variant: reuse the context wording as the static `#[error()]` message (that is how the diagnostic value of the anyhow context is preserved), append `[{location:?}]`, and carry a `#[location]` field plus `#[source] source: BoxError`.
    - **Prefer adding payload (context) fields when practical.** If the call site has cheaply available identifiers, names, paths, or other facts that would help diagnose or respond to the failure (e.g. `org_id`, `resource_id`, a file path), carry them as named context fields on the variant. Context fields become the arguments of the variant's `Ctx::variant(...)` constructor (the `#[source]` field is what makes it constructible) and prevent the headache of missing information later.
   - A variant with **no context field** (only `#[location]`/`#[source]`) gets a zero-argument Ctx constructor: `expr.with_context(Ctx::variant())?`.
   - `bail!("msg")` with no captured error becomes a **source-less variant**, constructed by hand. Source-less variants never get a Ctx constructor.
   - `bail!("msg: {}", e)` with a captured external error becomes a variant with `#[source]`; keep any other available facts as context fields.
   - Domain/control-flow failures (not found, forbidden, conflict, timeout) carry no `#[source]`; add context fields (e.g. `NotFound { resource_id: Uuid }`) when an identifier is worth capturing.
   - Use `#[context(borrow = TargetType)]` on a context field only when the call site already holds a reference (`&Path`, `&str`) and the Ok path is hot.
6. **Write the enum** before the function, deriving `Debug, thiserror::Error, CtxError`.
7. **Rewrite each call site** using the replacement table below. Add `use FooErrorCtx as Ctx;` where used (top of file or function), plus `use dterror::{BoxError, CtxError, Location};` at the derive site. Hand-built source-less variants use fully-qualified `std::panic::Location::caller()` (no import — it would collide with the dterror `Location`). In a file where `anyhow::Context` is in scope, use the UFCS form for every dterror wrap.
8. **Update the function's callers.**
   - Legacy anyhow callers: usually **no change** — anyhow's `.context("...")?` works on any error that is `std::error::Error + Send + Sync + 'static`, which the new enum satisfies. Only touch the call site if its message or payload must change, and never convert the caller itself.
    - Typed (dterror) callers: wrap with their own context, `foo().with_context(CallerErrorCtx::variant(...))?` (UFCS form in mixed files). Only source-less variants are not constructible; build those by hand (`return Err(CallerError::Variant { ..., location: std::panic::Location::caller() });`). A source-less variant cannot carry the callee's error — if preserving it matters, give the variant a `#[source]` field instead, which makes it constructible.
9. **Implement `IntoResponse`** if the function is an axum handler, using fixed `(StatusCode, &'static str)` pairs — never `self.to_string()`, never the source. (If the function is a plain `fn`/helper, skip this.)
10. **Clean up imports.** Remove `use anyhow::{bail, Context, Result};` only if no other function in the file still uses anyhow. If other functions still do, keep the import and write the converted function's return type as `Result<T, FooError>` anyway (be explicit; `anyhow::Result` has a default error param). Remove any now-unused imports.
11. **Verify** (see Verification).

## Replacement table

| anyhow construct | dterror replacement |
|---|---|
| `anyhow::Result<T>` / `Result<T>` via `use anyhow::Result` | `Result<T, FooError>` |
| `expr.context("msg")?` (external error) | `expr.with_context(Ctx::variant(args...))?` — variant: static `#[error("msg [{location:?}]")]`, context fields for the dynamic facts, `#[location]`, `#[source]`. No context field available → zero-argument constructor: `expr.with_context(Ctx::variant())?` |
| `expr.with_context(\|\| format!("msg {}", x))?` (anyhow closure form) | `expr.with_context(Ctx::variant(x))?` — the dynamic part becomes a context field interpolated in `#[error()]` |
| `bail!("msg")` | `return Err(FooError::Variant { location: std::panic::Location::caller() });` — source-less variant; add context fields (still built by hand) when facts are worth capturing |
| `bail!("msg: {}", e)` (external error captured) | `return Err(FooError::Variant { <fields>, location: std::panic::Location::caller(), source: Box::new(e) });` — message becomes static in `#[error()]`, error becomes `#[source]`; if the site is a fallible expression, prefer `expr.with_context(Ctx::variant(fields...))?` |
| `Err(e).context("msg")` | `expr.with_context(Ctx::variant(fields...))?` — the variant carries `#[source]`; build by hand only when the variant is source-less |
| `anyhow::Error` / `Box<dyn Error>` values flowing through | `#[source] dterror::BoxError` field |
| Callee returns a typed error (e.g. `Result<T, deployment::EnclaveSizingError>`) | `.with_context(Ctx::variant(...))?` — any callee error that converts into `BoxError` works, including `anyhow::Error` and `std::error::Error + Send + Sync` types; the boxed source is built for you |
| Callee returns `Result<T, StatusCode>` (legacy pattern) | `StatusCode` does not convert into a `BoxError` (it is not `Send + Sync + 'static`), so `.with_context` does not apply: `.map_err(\|status\| match status { StatusCode::NOT_FOUND => FooError::NotFound { resource_id, location: std::panic::Location::caller() }, _ => ... })` (see `download_eif`) |
| Caller of the converted function does `.context("...")?` (legacy anyhow caller) | Usually no change — anyhow's `Context` bound is satisfied by the new enum. Typed callers use `.with_context(CallerErrorCtx::variant(...))?` |

## Before / After example

Legacy `src/api/src/db.rs`, `initialize_user_account`:

```rust
use anyhow::{Context, Result};

pub async fn initialize_user_account(pool: &PgPool, user_id: Uuid) -> Result<Uuid> {
    let mut tx = pool.begin().await
        .context("Failed to begin transaction")?;
    let org_id: Uuid = sqlx::query_scalar(
        "INSERT INTO organizations (name) VALUES ($1) RETURNING id"
    )
    .bind(DEFAULT_ORGANIZATION_NAME)
    .fetch_one(&mut *tx)
    .await
    .context("Failed to create organization")?;
    sqlx::query(
        "INSERT INTO organization_members (organization_id, user_id, role)
         VALUES ($1, $2, 'owner')"
    )
    .bind(org_id)
    .bind(user_id)
    .execute(&mut *tx)
    .await
    .context("Failed to add user as organization owner")?;
    // ... provider account insert with .context("Failed to create provider account")? ...
    tx.commit().await
        .context("Failed to commit transaction")?;
    Ok(org_id)
}
```

Converted — one enum per function, one variant per failure mode, `#[location]` + boxed `#[source]` on every external error, static `#[error()]` messages, context fields where practical:

```rust
use dterror::{BoxError, CtxError, Location, ResultExt};

#[derive(Debug, thiserror::Error, CtxError)]
pub enum InitializeUserAccountError {
    #[error("failed to begin transaction [{location:?}]")]
    BeginTransaction {
        #[location]
        location: Location,

        #[source]
        source: BoxError,
    },

    #[error("failed to create organization [{location:?}]")]
    CreateOrganization {
        #[location]
        location: Location,

        #[source]
        source: BoxError,
    },

    #[error("failed to add {user_id:?} as owner of {org_id:?} [{location:?}]")]
    AddOwner {
        org_id: Uuid,

        user_id: Uuid,

        #[location]
        location: Location,

        #[source]
        source: BoxError,
    },

    #[error("failed to create provider account [{location:?}]")]
    CreateProviderAccount {
        #[location]
        location: Location,

        #[source]
        source: BoxError,
    },

    #[error("failed to commit transaction [{location:?}]")]
    Commit {
        #[location]
        location: Location,

        #[source]
        source: BoxError,
    },
}

pub async fn initialize_user_account(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<Uuid, InitializeUserAccountError> {
    use InitializeUserAccountErrorCtx as Ctx;

    // Zero-argument constructor: BeginTransaction has a #[source] but no context fields.
    let mut tx = pool.begin().await.with_context(Ctx::begin_transaction())?;
    let org_id: Uuid = sqlx::query_scalar(
        "INSERT INTO organizations (name) VALUES ($1) RETURNING id"
    )
    .bind(DEFAULT_ORGANIZATION_NAME)
    .fetch_one(&mut *tx)
    .await
    .with_context(Ctx::create_organization())?;
    sqlx::query(
        "INSERT INTO organization_members (organization_id, user_id, role)
         VALUES ($1, $2, 'owner')"
    )
    .bind(&org_id)
    .bind(&user_id)
    .execute(&mut *tx)
    .await
    // The only variant with context fields: org_id and user_id ride along in the error.
    .with_context(Ctx::add_owner(org_id, user_id))?;
    // ... provider account insert wrapped the same way: Ctx::create_provider_account() ...
    tx.commit().await.with_context(Ctx::commit())?;
    Ok(org_id)
}
```

Notes:

- `BeginTransaction`, `CreateOrganization`, `CreateProviderAccount`, and `Commit` have no context field, so the derive gives them zero-argument Ctx constructors; their call sites use `.with_context(Ctx::begin_transaction())?` and the like. Only source-less variants are built by hand.
- This example is written for a file that no longer imports `anyhow::Context`. In a mixed file (like `db.rs` mid-migration, which keeps `use anyhow::{Context, Result};`), replace the bare call with the UFCS form — `dterror::ResultExt::with_context(<expr>, Ctx::add_owner(org_id, user_id))?` — and drop `ResultExt` from the import.
- `AddOwner` carries context fields on purpose: `org_id` and `user_id` were cheaply available at the call site, and carrying them on the error makes the failure diagnosable without hunting through logs. Prefer such context fields when practical; keep variants payload-less for failures with nothing useful to capture (they still get a zero-argument constructor).
- Every `#[error()]` message is static text interpolating context fields and `{location:?}` only — never the source. With workspace `thiserror = "1"` this is convention (enforced by AGENTS.md), not a compiler error — check every variant yourself. (`hcl-patcher` uses `thiserror = "2"`, where the compiler rejects it.)

## Constraints

1. **Never use the source in `#[error()]`.** Messages are static strings interpolating context fields and `{location:?}` only. Never write `#[error("failed to X: {source}")]`; the source stays chained via `std::error::Error::source()`.
2. **One enum per function.** Do not add variants to a shared/global error, and do not reuse another function's error enum or its Ctx.
3. **The `#[source]` field is always `dterror::BoxError`** (an alias for `Box<dyn std::error::Error + Send + Sync + 'static>`). dterror's generated code moves a boxed trait object into it; typed source fields (e.g. `#[source] sqlx::Error`) are not possible under the dterror pattern. A **struct** (see the `dterror` skill) may instead use `Option<dterror::BoxError>` to support source-less failure modes, with the captured source auto-wrapped in `Some(...)` and source-less variants hand-built with `source: None`.
4. **Every variant carries `#[location] location: dterror::Location`** (imported as `Location`), and its `#[error()]` message ends with `[{location:?}]`. Variants built by hand supply `std::panic::Location::caller()` — fully qualified, since the alias cannot be used for the `::caller()` call.
5. **Constructibility rule.** A variant gets a Ctx constructor iff it has a `#[source]`/`#[from]` field — zero-argument when it has no context fields. Only source-less variants (domain failures) are constructed by hand; do not invent a context field just to force a constructor.
6. **Named fields only.** dterror rejects tuple structs/variants and unions; the repo convention already uses named fields.
7. **Mixed files need UFCS.** When `anyhow::Context` is in scope in the same file (directly or via glob), bare `.with_context(...)` is ambiguous (E0034); write `dterror::ResultExt::with_context(expr, Ctx::...)?`. The collision clears on its own once the last anyhow use in the file is converted.
8. **Do not swallow errors silently.** Every fallible call site must map to a variant. When converting a site that previously logged before propagating (e.g. `tracing::warn!(... "{:#}", e);`), keep the log in place — above the `.with_context(...)` wrap, or inside a `.map_err(...)` closure if one is used.
9. **Preserve semantics.** Keep the same messages (as static text, now able to interpolate context fields and location), the same payloads, and the same success path. Status codes for handlers must reflect the domain meaning: 4xx for client errors, 5xx for internal failures.
10. **Scope: one function.** Convert the function in scope only. Do not convert legacy files wholesale (most of `src/api/src/main.rs` stays anyhow), do not refactor the function's body beyond the error handling, and do not add `.context()` to new code.
11. **Handler responses use fixed bodies.** `IntoResponse` returns `(StatusCode, &'static str)` pairs — avoid `(StatusCode, String)` tuples and `self.to_string()` in the response body; the source must never reach the client.
12. **Stop on conflicts.** If a call site does not fit these patterns (e.g. errors flowing through generic code, an error type that is not `Send + Sync + 'static`, error values stored in structs), STOP and report it instead of inventing a strategy.

## Verification

- The crate names dterror via the workspace pin (`dterror = { workspace = true }`, git main / 0.3.0) — not a crates.io version.
- `cargo check -p <crate>` (e.g. `cargo check -p api`) — the enum, the generated Ctx, and every call site must compile; bare `.with_context` requires `use dterror::ResultExt` in scope, and the function must no longer return `anyhow::Error`.
- `cargo clippy -p <crate>` — no new lints.
- Grep the converted function for leftover anyhow: `.context(`, `bail!`, `anyhow::`, `use anyhow`. (`.with_context(...)` is now expected; only flag anyhow's closure form `.with_context(|| ...)`.)
- Check the function's callers still compile and that their `?`/`.map_err`/`.with_context` adapters are unambiguous.
