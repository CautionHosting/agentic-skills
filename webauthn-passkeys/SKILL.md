---
name: webauthn-passkeys
description: Use when implementing, reviewing, or debugging WebAuthn/passkey handling in the Caution gateway — registration or login ceremonies, rpId or origin config, challenge lifecycle, user verification (UV) policy, discoverable/resident credentials, excludeCredentials, credential or session storage, sign-counter or backup-eligibility (BE/BS) flags, account recovery, or the webauthn-rs 0.5 SecurityKey/discoverable ceremonies in src/gateway. For running the platform locally use caution-local-dev; for authoring app configs use caution-platform.
---

# WebAuthn / Passkeys (Caution gateway)

Authentication for the **platform itself** is WebAuthn/passkeys, implemented entirely in the
Rust `gateway` service. This skill is for devs working on that code. For running the stack use
`caution-local-dev`; for the e2e harness see the testing section below.

## Source of truth

Prefer current primary sources over memory:

- Tour of WebAuthn (Adam Langley): `https://www.imperialviolet.org/tourofwebauthn/tourofwebauthn.html`
- webauthn-rs docs: `https://docs.rs/webauthn-rs/0.5` and repo `https://github.com/kanidm/webauthn-rs`
- WebAuthn L3 spec: `https://www.w3.org/TR/webauthn-3/`
- Platform source: `https://codeberg.org/caution/platform` (gateway at `src/gateway/`)

## How it works here

| Concern | Where | Notes |
|---|---|---|
| Library | `webauthn-rs = "0.5"` | Features `conditional-ui`, `danger-allow-state-serialisation`. Built via `WebauthnBuilder` in `src/gateway/src/main.rs`. |
| RP config | `src/gateway/src/config.rs` | Env `RP_ID`, `RP_ORIGINS` (comma-sep, multi-origin), `RP_DISPLAY_NAME`. Non-localhost origins must be `https` in production. |
| Register | `handlers.rs` `begin_register_handler` / `begin_invite_register_handler` → `finish_register_handler`; extra key via `begin/finish_add_passkey_handler` | Uses `start_securitykey_registration` (not `start_passkey_registration`), then overrides UV/resident-key manually. |
| Login | `handlers.rs` `begin_login_handler` → `finish_login_handler` | Discoverable-first (`start_discoverable_authentication` + `identify`/`finish_discoverable_authentication`); username-scoped path uses `start_securitykey_authentication`. |
| Challenge state | `AppState` in `types.rs` | In-memory `HashMap` keyed by a random session id, 2-min TTL, single-use (removed on finish), capped, swept periodically. **Assumes a single gateway replica.** |
| Credential store | `fido2_credentials` (`src/api/migrations/`) | `public_key` column holds the whole serialized `SecurityKey` JSON (cred id, COSE key, counter, transports, BE/BS, policy). Separate `sign_count`/`transport`/`flags` columns are partial legacy duplicates. |
| Session | `auth_sessions` table | Opaque 32-byte session id + derived CSRF token; cookies `caution_session` (HttpOnly) + `caution_csrf` (JS-readable). Header auth via `X-Session-ID` skips CSRF. |

## Review checklist (Tour of WebAuthn invariants)

When touching any of the above, verify these hold. Each maps to a specific Tour-of-WebAuthn point.

- **rpId is permanent — set it once, as broad as you'll ever need.** Credentials are scoped to
  `RP_ID`; you cannot broaden it later without re-registering everyone. Never share an rpId with an
  untrusted subdomain (user content) — it can overwrite legitimate credentials.
- **Origin, not rpId, stops phishing.** webauthn-rs checks the client-data `origin` against the
  allowed-origins list; ensure every legitimate sign-in origin is in `RP_ORIGINS` and nothing more.
- **Challenges: random, server-generated, single-use, time-boxed.** The library generates them;
  the gateway's job is to store, expire, and consume exactly once. Don't add a path that resolves a
  challenge twice or reuses one across ceremonies.
- **UV is advisory unless you request `Required` AND check the flag server-side.** `Preferred`
  gives no guarantee. If a factor count depends on UV, request `Required` and verify
  `auth_result.user_verified()` at finish — requesting isn't checking. Beware: a credential
  registered without UV can never satisfy a later `Required` policy.
- **Discoverable login needs discoverable registration.** If login uses
  `start_discoverable_authentication`, registration must actually produce resident credentials —
  prefer `ResidentKeyRequirement::Required`, and read `credProps.rk` to confirm, or non-resident
  credentials become silently unfindable.
- **excludeCredentials should be scoped to the target account.** Sending the whole DB's credential
  IDs to an unauthenticated client leaks credential IDs and grows unbounded (large lists degrade
  some authenticators). Enforce cross-account uniqueness server-side at finish instead.
- **User handle must be random and non-PII.** A `Uuid::new_v4()` (opaque ≤64 bytes) is correct —
  never derive it from email/username; it is exposed as `userHandle` in assertions.
- **Signature counters are near-useless with synced passkeys.** Synced passkeys report counter 0
  forever. webauthn-rs defaults to hard-failing on a regression (`CredentialPossibleCompromise`) —
  decide whether that's desired vs. logging, and don't rely on the counter for clone detection.
- **Use BE/BS to drive recovery UX.** `backup_eligible`/`backup_state` are stored in the serialized
  `SecurityKey`. A user whose only credential is device-bound (`!backup_eligible`) can be locked out
  on device loss — prompt for a second credential or recovery when that's the case.
- **Account recovery is a first-class requirement.** Ensure there is *some* path back in after
  losing the only passkey (second credential, recovery codes, admin/org reset). Losing a device
  must not mean losing the account.
- **Attestation: `None` is correct for non-enterprise.** Only request attestation if you intend to
  restrict to specific hardware. COSE algs: support ES256 (`-7`) always and RS256 (`-257`) for older
  Windows TPMs — webauthn-rs's `secure_algs()` covers both.

## Common mistakes

- **Editing UV/resident-key on the `ccr` after `start_*` without re-reading the finish-side check.**
  The request flag and the server-side `user_verified()` assertion must agree, or orgs that require
  PIN silently break.
- **Assuming challenge/rate-limit state is shared.** It's per-process. Any horizontal scaling of the
  gateway breaks challenge resolution and makes per-IP/per-username limits bypassable. Move state to
  Redis/DB before scaling out.
- **Trusting the `sign_count`/`transport`/`flags` SQL columns.** The source of truth is the
  serialized `SecurityKey` in `public_key`; those columns are partial/legacy.
- **Regex-parsing clientDataJSON.** Always parse it as JSON — browsers add fields.

## Testing

WebAuthn e2e is **three** make targets (StageX images are amd64-only; run each via
`orb -m ubuntu-amd64` on macOS, and each self-manages `up-test`/`down-test`):

- `make test-e2e-webauthn` — core flow
- `make test-e2e-webauthn-roundtrip` — Rust soft authenticator, non-resident
- `make test-e2e-webauthn-browser` — Chrome CDP, resident/discoverable

To test authed endpoints without a passkey touch: `make up-test` + `/auth/e2e-login` +
`X-Session-ID` header (no CSRF needed on header auth). The soft authenticator lives at
`tests/e2e/soft-authenticator/`.
