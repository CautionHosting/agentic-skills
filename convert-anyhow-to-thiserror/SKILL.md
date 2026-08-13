---
name: convert-anyhow-to-thiserror
description: >-
    Convert a function that returns anyhow::Result<T> (anyhow Result,
    .context(), bail!, with_context) into Result<T, FooError> where FooError is
    a new per-function error enum built with thiserror, including #[source]
    fields and an IntoResponse impl for axum handlers. Use when the user asks
    to convert a function from anyhow-style error handling to a typed
    Result<T, Error>, or mentions thiserror, typed errors, or removing anyhow
    from a function.
license: MIT
---

# Convert Function from anyhow to thiserror

Convert a single function from the legacy `anyhow` error pattern (`anyhow::Result<T>`, `.context("msg")?`, `bail!("msg")`) to `Result<T, FooError>` where `FooError` is a new error enum specific to that function, derived with `thiserror`. Each external error becomes a `#[source]` field; the source is never interpolated into the `#[error()]` message.

## Reference

Model the result on the canonical typed-error code already in the repo:

- `src/api/src/fully_managed_capacity.rs` — `CapacityError`, `CandidateRegionsError` (per-function enums, `#[source]` fields, `#[from]` where a single error type maps to a single variant)
- `src/api/src/eif_download.rs` — `DownloadEifError`, `EnsureCachedError` (per-function enums, unit variants for domain errors, `#[source] Box<dyn Error + Send + Sync>` for opaque errors, `IntoResponse` with fixed status + static body)
- `src/api/src/organizations.rs` — `InvitationError` (pure unit variants, `IntoResponse`)
- Repo convention (AGENTS.md): one `thiserror` enum per function; `#[source]` for external errors; never include source errors in the display representation of new error types; `IntoResponse` for axum handlers with proper status codes.

## Target pattern

```rust
#[derive(Debug, thiserror::Error)]
pub(crate) enum FooError {
    #[error("static message describing the failure")]
    VariantName(#[source] sqlx::Error), // external error, source NOT used in the message

    #[error("static message referencing {resource_id}")]
    WithPayload {
        resource_id: Uuid, // non-source payload, may be interpolated
        #[source]
        source: sqlx::Error,
    },

    #[error("static message for a domain failure")]
    DomainFailure, // unit variant: no source, no payload
}

impl IntoResponse for FooError { // only when the function is an axum handler
    fn into_response(self) -> Response<Body> {
        let (status, body) = match &self {
            FooError::DomainFailure => (StatusCode::BAD_REQUEST, "user-facing message"),
            FooError::VariantName(_) => (StatusCode::INTERNAL_SERVER_ERROR, "internal error"),
        };
        (status, body).into_response()
    }
}
```

## Transformation steps

1. **Read the function** and identify its signature. `anyhow::Result<T>` is `Result<T, anyhow::Error>` — if the file does `use anyhow::Result;`, the return type will read `Result<T>` or `Result<T, ...>`.
2. **Inventory every fallible call site** in the function body: `?`, `.context(...)?`, `.with_context(...)?`, `bail!`, `return Err(...)`, `Err(e).context(...)`. Each is a candidate variant.
3. **Name the error enum `{FunctionName}Error`** (PascalCase of the function name, matching `DownloadEifError`, `InitializeUserAccountError` style). Match the function's visibility: `pub` if the function is `pub`, otherwise `pub(crate)`.
4. **Enumerate one variant per failure mode.**
   - Each distinct `.context("msg")` becomes its own variant carrying `#[source]`; reuse the context wording as the static `#[error()]` message (that is how the diagnostic value of the anyhow context is preserved).
   - **Prefer adding payload fields when practical.** If the call site has cheaply available identifiers, names, paths, or other facts that would help diagnose or respond to the failure (e.g. `org_id`, `resource_id`, a file path), carry them as named fields on the variant. Fields are cheap and prevent the headache of missing information later. Non-`#[source]` payload fields may be interpolated in `#[error()]`; the `#[source]` field itself is never interpolated.
   - `bail!("msg")` with no captured error becomes a unit variant only when there is genuinely nothing useful to capture.
   - `bail!("msg: {}", e)` with a captured external error becomes a variant with `#[source]` (e.g. `#[source] Box<dyn std::error::Error + Send + Sync>` when the type is dynamic); keep any other available facts as payload fields.
   - Domain/control-flow failures (not found, forbidden, conflict, timeout) carry no `#[source]`; they become unit variants unless an identifier is worth capturing (e.g. `NotFound { resource_id: Uuid }`), in which case add payload fields.
5. **Write the enum** next to the function (before it, like the reference files).
6. **Rewrite each call site** using the replacement table below.
7. **Update the function's callers.** Callers that did `foo().context("...")?` on the now-typed error must map it: `foo().map_err(|e| CallerError::Variant(Box::new(e)))?` or `.map_err(|_| CallerError::Variant)?` when the caller only needs to know the step failed. Per repo convention, callers that are legacy anyhow code keep their own style — you only adapt the call site, you do not convert the caller.
8. **Implement `IntoResponse`** if the function is an axum handler, using fixed `(StatusCode, &'static str)` pairs — never `self.to_string()`, never the source. (If the function is a plain `fn`/helper, skip this.)
9. **Clean up imports.** Remove `use anyhow::{bail, Context, Result};` only if no other function in the file still uses anyhow. If other functions still do, keep the import and write the converted function's return type as `Result<T, FooError>` anyway (`anyhow::Result` has a default error param, so be explicit and verify with the compiler). Remove any now-unused imports.
10. **Verify** (see Verification).

## Replacement table

| anyhow construct | thiserror replacement |
|---|---|
| `anyhow::Result<T>` / `Result<T>` via `use anyhow::Result` | `Result<T, FooError>` |
| `expr.context("msg")?` (external error) | `expr.map_err(FooError::Variant)?` — variant: `#[error("msg")] Variant(#[source] TheError)` |
| `expr.with_context(\|\| format!("msg {}", x))?` | `expr.map_err(FooError::Variant)?` — if the message's dynamic part matters (e.g. a path), keep it as a payload field: `#[error("failed to read {0}")] ReadFile(PathBuf, #[source] std::io::Error)` |
| `bail!("msg")` | `return Err(FooError::Variant);` — unit variant only when nothing is worth capturing; otherwise add payload fields (e.g. `return Err(FooError::Variant { resource_id })`) |
| `bail!("msg: {}", e)` (external error captured) | `return Err(FooError::Variant(Box::new(e)));` — message becomes static, error becomes `#[source]` |
| `Err(e).context("msg")` | `Err(FooError::Variant(e))` |
| `anyhow::Error` / `Box<dyn Error>` values flowing through | `#[source] Box<dyn std::error::Error + Send + Sync>` field (see `EnsureCachedError::S3Download`) |
| Callee returns a typed error (e.g. `Result<T, deployment::EnclaveSizingError>`) | `.map_err(FooError::Variant)?` — do not `#[from]` it into the new enum; map explicitly |
| Callee returns `Result<T, StatusCode>` (legacy pattern) | `.map_err(\|status\| match status { StatusCode::NOT_FOUND => FooError::NotFound, _ => FooError::Internal })` (see `download_eif`) |
| Caller of the converted function does `.context("...")?` | `.map_err(\|e\| CallerError::Variant(Box::new(e)))?` — the `anyhow::Error` is `Send + Sync` so it fits `Box<dyn Error + Send + Sync>` |

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

Converted — one enum per function, one variant per failure mode, `#[source]` on every external error, static `#[error()]` messages, payload fields where practical:

```rust
#[derive(Debug, thiserror::Error)]
pub enum InitializeUserAccountError {
    #[error("failed to begin transaction")]
    BeginTransaction(#[source] sqlx::Error),
    #[error("failed to create organization")]
    CreateOrganization(#[source] sqlx::Error),
    #[error("failed to add {user_id:?} as owner of {org_id:?}")]
    AddOwner {
        org_id: Uuid,
        user_id: Uuid,
        #[source]
        source: sqlx::Error,
    },
    #[error("failed to create provider account")]
    CreateProviderAccount(#[source] sqlx::Error),
    #[error("failed to commit transaction")]
    Commit(#[source] sqlx::Error),
}

pub async fn initialize_user_account(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<Uuid, InitializeUserAccountError> {
    let mut tx = pool
        .begin()
        .await
        .map_err(InitializeUserAccountError::BeginTransaction)?;
    let org_id: Uuid = sqlx::query_scalar(
        "INSERT INTO organizations (name) VALUES ($1) RETURNING id"
    )
    .bind(DEFAULT_ORGANIZATION_NAME)
    .fetch_one(&mut *tx)
    .await
    .map_err(InitializeUserAccountError::CreateOrganization)?;
    sqlx::query(
        "INSERT INTO organization_members (organization_id, user_id, role)
         VALUES ($1, $2, 'owner')"
    )
    .bind(&org_id)
    .bind(&user_id)
    .execute(&mut *tx)
    .await
    .map_err(|source| InitializeUserAccountError::AddOwner {
        org_id,
        user_id,
        source,
    })?;
    // ... provider account insert with .map_err(InitializeUserAccountError::CreateProviderAccount)? ...
    tx.commit()
        .await
        .map_err(InitializeUserAccountError::Commit)?;
    Ok(org_id)
}
```

Note why `#[from]` is absent here: every call site produces `sqlx::Error`, but each maps to a different variant, so `#[from]` cannot be used — explicit `.map_err(...)` at each site is required.

`AddOwner` is a struct variant on purpose: `org_id` and `user_id` were cheaply available at the call site, and carrying them on the error (rather than a bare static message) makes the failure diagnosable without hunting through logs. Prefer such payload fields when practical. Struct-variant fields must be named, `#[error()]` interpolates fields by their actual names, and the `#[source]` field must be populated at the construction site (here via the `source` closure parameter).

## Constraints

1. **Never use the source in `#[error()]`.** `#[error()]` messages are static strings (or interpolate non-source payload fields only, e.g. the `PathBuf` in `EvictLruError::RemoveFile`). Never write `#[error("failed to X: {0}")]` over a `#[source]` field. With workspace `thiserror = "1"` this is convention (enforced by AGENTS.md), not a compiler error — check every variant yourself. (`hcl-patcher` uses `thiserror = "2"`, where the compiler rejects it.)
2. **One enum per function.** Do not add variants to a shared/global error, and do not reuse another function's error enum.
3. **`#[source]` for every external error field.** Unit variants carry no source.
4. **`#[from]` sparingly.** Use `#[from]` only when the variant wraps exactly the source error AND every call site in the function that produces that error type maps to the same variant (canonical: `CapacityError::Database(#[from] sqlx::Error)`). If call sites of the same error type map to different variants, or the variant carries extra payload, write `.map_err(FooError::Variant)` at each site.
5. **Do not swallow errors silently.** Every fallible call site must map to a variant. When converting a site that previously logged before propagating (e.g. `tracing::warn!(... "{:#}", e);`), keep the log inside the `.map_err(...)` closure (see `reserve_capacity` mapping `candidate_regions` failures).
6. **Preserve semantics.** Keep the same messages (as static text), the same payloads, and the same success path. Status codes for handlers must reflect the domain meaning: 4xx for client errors, 5xx for internal failures.
7. **Scope: one function.** Convert the function in scope only. Do not convert legacy files wholesale (most of `src/api/src/main.rs` stays anyhow), do not refactor the function's body beyond the error handling, and do not add `.context()` to new code.
8. **Handler responses use fixed bodies.** `IntoResponse` returns `(StatusCode, &'static str)` pairs — avoid `(StatusCode, String)` tuples and `self.to_string()` in the response body; the source must never reach the client.
9. **Stop on conflicts.** If a call site does not fit these patterns (e.g. errors flowing through generic code, `Box<dyn Error>` shared across functions, error values stored in structs), STOP and report it instead of inventing a strategy.
10. **Prefer payload fields when practical.** Add named fields to variants when the call site has information worth keeping (identifiers, names, paths) — fields are cheap and prevent missing-information headaches later. Interpolate non-`#[source]` payload fields in `#[error()]` freely; keep unit variants only for failures with nothing useful to capture.

## Verification

- `cargo check -p <crate>` (e.g. `cargo check -p api`) — the enum must compile and the function must no longer return `anyhow::Error`.
- `cargo clippy -p <crate>` — no new lints; in particular no `thiserror`-related warnings.
- Grep the converted function for leftover `context(`, `bail!`, and `anyhow` references.
- Check the function's callers still compile and that their `?`/`.map_err` adapters compile.
