# STEVE on Production Nitro

Use this reference when deploying or testing STEVE against real AWS Nitro.
Keep STEVE repo-specific commands aligned with that checkout's
`tests/e2e/README.md`.

## Configure one fixed suite per deployment

```hcl
http {
  domain = "secure.example.com"
  port   = 8080

  e2e_encryption {
    enabled = true
    cors_origins = [
      "http://localhost:3000",
      "http://127.0.0.1:3000",
    ]
    key_exchange = "xwing-draft10"
  }
}
```

- Omit `key_exchange` for the default `x25519`; use `"xwing-draft10"` for
  `XWING-DRAFT10`.
- The suite is fixed in the measured deployment. Use separate deployments to
  test X25519 and X-Wing; do not negotiate or silently fall back.
- Use exact CORS origins. `localhost` and `127.0.0.1` are different origins,
  and current STEVE rejects `*`.
- Remove the entire `debug` block before the release gate. Debug mode exposes
  SSH and produces zero PCRs.

## Operator preflight

1. Confirm what the platform intends to build into new enclaves:

   ```bash
   curl -fsS https://<platform>/.well-known/caution/build-inputs | jq .steve
   ```

2. If the STEVE pin or builder input changed, rebuild/restart the Platform API
   as required, then redeploy the application. Existing enclaves do not change.
3. Verify the deployed enclave and record the independently reproduced PCRs:

   ```bash
   caution verify --attestation-url https://secure.example.com/attestation
   ```

`build-inputs` is the platform's unauthenticated claim about future builds. It
is useful for drift detection, but the release decision comes from the live
Nitro evidence plus successful PCR reproduction.

## Run the real-Nitro gate

From the matching STEVE checkout:

```bash
export STEVE_REMOTE_ORIGIN=https://secure.example.com
export STEVE_KEY_EXCHANGE=XWING-DRAFT10
export STEVE_EXPECTED_PCR0=<96-hex-pcr0>
export STEVE_EXPECTED_PCR1=<96-hex-pcr1>
export STEVE_EXPECTED_PCR2=<96-hex-pcr2>

make test-e2e-nitro
```

Run it once per deployment/suite. The primary target runs browser/WASM and
Rust. Use the browser-only or Rust-only targets only for diagnosis:

```bash
make test-e2e-nitro-browser
make test-e2e-nitro-rust
```

Require all PCRs to be exact, 96 hexadecimal characters, and nonzero. The
browser gate compares verified reported PCRs; the Rust SDK enforces the policy
during connection and checks rejection with a mutated PCR.

Local synthetic or QEMU tests remain useful for protocol and packaging
coverage, but they do not prove Nitro authenticity, production VSOCK routing,
or production PCR policy.

## Diagnose health before protocol behavior

Separate these layers:

1. Public DNS/TLS and application health.
2. Caddy and host VSOCK proxy services.
3. Enclave boot and console logs.
4. STEVE `/e2p/v2/session`, `/confirm`, and `/request`.
5. The decrypted application endpoint behind STEVE.

If the plain health endpoint hangs, do not classify an SDK failure or tune the
KEM. Use the host and enclave log commands in the main skill first.

## Diagnose latency before adding CPUs

Measure cold and warm phases separately:

- attested `/session` + `/confirm`;
- first encrypted `/request`;
- repeated encrypted `/request`;
- the same application response without the protected browser path.

Inspect browser network logs for `OPTIONS` versus `POST`. Cross-origin CBOR
requests require CORS preflight, and preflight latency belongs to STEVE's
`/e2p/v2/*` endpoints, not the application fixture. A client request using
`cache: "no-store"` can defeat browser preflight reuse even while STEVE
correctly sends `Cache-Control: no-store` on protocol responses.

Only increase enclave CPU after application/STEVE telemetry, concurrency
testing, or a controlled 2-vCPU versus 4-vCPU comparison shows compute
contention. Extra CPU does not remove DNS, TLS, CORS, or network round trips.

## Evidence checklist

- The expected suite is reported only after a successful attested session.
- A protected application request succeeds and returns the expected body.
- Configuring the opposite suite fails closed.
- Evidence is non-synthetic and includes a Nitro module ID.
- PCR0/1/2 exactly match independently reproduced values.
- Browser/WASM and Rust both pass for X25519 and X-Wing.
