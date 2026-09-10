## Stack scope prefixes

## Wiring files

```
crates/headroom-proxy/src/proxy.rs
crates/headroom-proxy/src/config.rs
crates/headroom-proxy/src/error.rs
crates/headroom-core/src/transforms/pipeline/orchestrator.rs
crates/headroom-core/src/tokenizer/registry.rs
```

## Label probes

### auth.classify-once-thread-via-extensions

label:        auth
statement:    Auth mode is classified exactly once per request — either by `forward_http`'s entry-point call or the Bedrock-route middleware — and the resolved value is threaded downstream via request extensions (or an explicit parameter); handlers read the stored value and never re-classify the headers themselves.
exemplar:     `crates/headroom-proxy/src/proxy.rs:424`
witnesses:    `crates/headroom-proxy/src/bedrock/auth_mode_layer.rs:68`
              `crates/headroom-proxy/src/bedrock/invoke.rs:132`
guard:        the single `classify(...)` call per request path immediately stores its result (`req.extensions_mut().insert(auth_mode)` in `proxy.rs`, or the Bedrock middleware's own extensions insert), and every downstream call site takes `AuthMode` as a plain parameter or `Extension<AuthMode>` extractor instead of touching `req.headers()` again.
unsafe_when:  a handler or helper calls `headroom_core::auth_mode::classify` a second time on the same request deep in the call stack — if headers were read at a different point (e.g. after a header-mutating step), the two classifications could diverge and silently change which compression/security gate applies mid-request.

### security.payg-only-byte-mutation-gate

label:        security
statement:    Any pass that mutates request bytes for cache-stabilization purposes (tool-array sort, JSON-schema key sort, `cache_control` auto-placement, `prompt_cache_key` injection) is gated on `AuthMode::Payg`; OAuth and Subscription requests always pass through byte-equal.
exemplar:     `crates/headroom-proxy/src/proxy.rs:1252`
witnesses:    `crates/headroom-proxy/src/compression/live_zone_anthropic.rs:234`
              `crates/headroom-proxy/src/compression/live_zone_anthropic.rs:615`
guard:        an explicit `matches!(auth_mode, AuthMode::Payg)` (or its negation) check wraps the mutation; the non-PAYG branch always logs a structured `*_skipped` event with `reason = "auth_mode"` and returns the input untouched.
unsafe_when:  a new byte-mutating pass is added to the Phase E pipeline without its own `AuthMode::Payg` check — it would then mutate OAuth/Subscription bytes too, which can read as cache-evasion to the upstream and risk revoking the client's scoped credentials.

### security.fail-closed-on-missing-credentials

label:        security
statement:    When a required credential or signature cannot be resolved (AWS SigV4 creds, GCP ADC bearer token), the handler refuses to forward the request rather than sending it unsigned/unauthenticated — it returns a 5xx with a structured log event instead.
exemplar:     `crates/headroom-proxy/src/bedrock/invoke.rs:231`
witnesses:    `crates/headroom-proxy/src/bedrock/invoke.rs:265`
              `crates/headroom-proxy/src/vertex/raw_predict.rs:205`
guard:        the credential/signing result is matched explicitly; the `Err`/`None` arm returns an `error_response(...)` (or equivalent) immediately and logs `event = "..._missing"` / `event = "..._failed"` — there is no code path that falls through to sending the request anyway.
unsafe_when:  a future provider integration treats a missing credential as "skip signing, forward anyway" instead of failing the request — the upstream would then either silently reject with an opaque error or, worse, accept an unauthenticated call.

### data-exposure.hash-and-truncate-identifiers-in-logs

label:        data-exposure
statement:    Session identity material derived from credentials (bearer tokens, API keys, the `x-headroom-session-id` header) or from a derived cache key is never logged in full; logs carry only a short hex prefix of a SHA-256 hash of the value.
exemplar:     `crates/headroom-proxy/src/cache_stabilization/drift_detector.rs:404`
witnesses:    `crates/headroom-proxy/src/cache_stabilization/drift_detector.rs:373`
              `crates/headroom-proxy/src/cache_stabilization/beta_sticky.rs:326`
              `crates/headroom-proxy/src/cache_stabilization/openai_cache_key.rs:169`
guard:        a dedicated helper (`session_key_log_prefix`, or the inline `key[..KEY_PREFIX_LOG_LEN]` slice) hashes/truncates the value before it is ever passed to a `tracing::` macro; the raw secret variable is never itself interpolated into a log field.
unsafe_when:  a new log statement interpolates the raw `session_key`, bearer token, or full derived cache key directly (e.g. `session_key = %session_key` instead of `session_key_hash = %session_key_log_prefix(session_key)`) — that would put identifying/secret material into structured logs and log aggregators.

### data-exposure.internal-headers-stripped-before-upstream

label:        data-exposure
statement:    Internal `x-headroom-*` diagnostic headers are stripped from the outbound request before it reaches the upstream provider by default; forwarding them requires an explicit operator opt-out, never a silent default.
exemplar:     `crates/headroom-proxy/src/headers.rs:149`
witnesses:    `crates/headroom-proxy/src/headers.rs:105`
              `crates/headroom-proxy/src/proxy.rs:503`
guard:        `is_internal_header` matches the `x-headroom-` prefix case-insensitively and `build_forward_request_headers` drops every matching header when `strip_internal` is true; the flag defaults to `StripInternalHeaders::Enabled` in `Config` and every strip is logged with a count.
unsafe_when:  a new header-building path (e.g. a fresh provider integration) constructs its outbound headers without routing through `build_forward_request_headers`/`is_internal_header`, so `x-headroom-*` fingerprinting headers leak to the upstream provider.

### concurrency.mutex-guarded-shared-state-with-explicit-lock-handling

label:        concurrency
statement:    Shared mutable state accessed from multiple concurrent request handlers (per-session LRUs, a lazily-initialized token provider) is wrapped in an explicit `Mutex`, and the lock's failure/contention path is handled deliberately — poison recovery or a documented double-checked re-fetch — never a blind `.lock().unwrap()` that would panic the request on contention.
exemplar:     `crates/headroom-proxy/src/cache_stabilization/drift_detector.rs:355`
witnesses:    `crates/headroom-proxy/src/cache_stabilization/beta_sticky.rs:176`
              `crates/headroom-proxy/src/vertex/adc.rs:204`
guard:        `drift_detector.rs`/`beta_sticky.rs` match on `Mutex::lock()`'s `Err(poisoned)` arm and recover the inner guard (or fail open) with a structured warn instead of propagating the panic; `adc.rs`'s async `tokio::sync::Mutex` re-takes the lock around the network fetch and double-checks freshness inside it so concurrent callers serialize on one refresh instead of a thundering herd.
unsafe_when:  a new shared cache is added behind `Mutex::lock().unwrap()` (or `.expect(...)` on a lock a panicking task can poison) — one panicking request would then poison the mutex and take down every subsequent request that touches the same cache.

### db.sqlite-parameterized-queries-only

label:        db
statement:    All SQLite access in the CCR store binds values through `rusqlite`'s `params!` placeholders; no query string is ever built by interpolating a caller-supplied value.
exemplar:     `crates/headroom-core/src/ccr/backends/sqlite.rs:191`
witnesses:    `crates/headroom-core/src/ccr/backends/sqlite.rs:159`
              `crates/headroom-core/src/ccr/backends/sqlite.rs:236`
guard:        every `conn.execute`/`conn.query_row` call site uses a literal SQL string with `?N` placeholders and passes the actual values through the `params![...]` macro; the `hash` value (which flows in from compressed tool-call content) is always a bound parameter, never concatenated into the SQL text.
unsafe_when:  a future query builds its SQL by `format!`-ing a caller-controlled string (e.g. a hash, a table/column name derived from config) directly into the query text instead of binding it as a parameter.

### logic.cache-hot-zone-detected-via-json-accessors-not-regex

label:        logic
statement:    Detecting structure inside a request body (`cache_control` markers, canonicalizing a JSON subtree for hashing) is done by walking the parsed `serde_json::Value` tree via typed accessors, never by regex or string pattern-matching against serialized JSON.
exemplar:     `crates/headroom-core/src/cache_control.rs:109`
witnesses:    `crates/headroom-proxy/src/cache_stabilization/tool_def_normalize.rs:70`
              `crates/headroom-proxy/src/cache_stabilization/drift_detector.rs:165`
guard:        every marker/field lookup goes through `Value::get`/`Value::as_array`/`Value::as_str` accessors on an already-parsed tree; the module docs explicitly cite the "no regex for parsing" build constraint as the reason.
unsafe_when:  a new detector scans the raw request bytes (or a re-serialized string) with a regex to look for a JSON key/marker instead of parsing and walking the structure — that misses escaped/nested/reordered variants a real parser would catch.

### validation.envelope-parse-errors-are-typed-not-panics

label:        validation
statement:    Parsing a provider-specific request envelope (Bedrock InvokeModel, Vertex publisher) validates required-field shape up front and returns a specific typed error variant for each failure mode; it never panics or silently accepts a malformed shape.
exemplar:     `crates/headroom-proxy/src/bedrock/envelope.rs:85`
witnesses:    `crates/headroom-proxy/src/vertex/envelope.rs:62`
              `crates/headroom-proxy/src/cache_stabilization/openai_cache_key.rs:150`
guard:        a dedicated `#[derive(Error)]` enum (`EnvelopeError`, `VertexEnvelopeError`) enumerates every rejection reason (not JSON, not an object, missing/wrong-typed required field); the parse function returns `Result<_, ThatEnum>` and the caller converts each variant to a structured log plus an HTTP error response.
unsafe_when:  a new envelope/body-shape check uses `.unwrap()`/`.expect()` on a field lookup, or silently defaults a missing required field, instead of returning a named error variant the caller can log and respond to.

### control-flow.disabled-feature-gate-always-logs-why

label:        control-flow
statement:    Every config-gated feature that is off by default-on (Bedrock native routes, the Conversations passthrough, per-request compression) still emits a structured log line explaining why it did nothing, instead of silently no-op'ing.
exemplar:     `crates/headroom-proxy/src/proxy.rs:262`
witnesses:    `crates/headroom-proxy/src/proxy.rs:302`
              `crates/headroom-proxy/src/vertex/raw_predict.rs:194`
guard:        the `else` branch of the feature-flag `if` always calls `tracing::warn!`/`tracing::info!` with an `event = "..._disabled"`/`"..._skipped"` field before falling through to the unmodified behavior; one call site's comment explicitly says it mirrors the WARN pattern used elsewhere.
unsafe_when:  a new operator-facing toggle is added whose `false`/`Off` branch just does nothing without a log line — operators then can't distinguish "feature never fired because traffic didn't match" from "feature is misconfigured off."

### layering.core-crate-has-no-io-runtime-dependency

label:        layering
statement:    `headroom-core` is a pure compute/parsing crate — it depends on no async runtime or HTTP client (no `tokio`, `axum`, `reqwest`); every crate that needs I/O (`headroom-proxy`, `headroom-simulators`) brings its own runtime and depends on `headroom-core` only for logic.
exemplar:     `crates/headroom-core/Cargo.toml:1`
witnesses:    `crates/headroom-proxy/Cargo.toml:43`
              `crates/headroom-parity/Cargo.toml:23`
guard:        `headroom-core`'s entire `[dependencies]` block (`crates/headroom-core/Cargo.toml:10-177`) lists only compute/parsing crates (serde, tokenizers, tree-sitter, rusqlite, etc.) plus the tiny `http` types crate — no `tokio`/`axum`/`reqwest`; `headroom-proxy` and `headroom-parity` each add `headroom-core = { path = "../headroom-core" }` as a plain path dependency and supply their own runtime on top.
unsafe_when:  a change to `headroom-core` adds a `tokio`/`axum`/`reqwest` dependency (even an optional one used by only one function) — that would force an async runtime onto every consumer crate, including the PyO3 bindings (`headroom-py`) and the parity harness, which have no runtime of their own.

### contract.byte-equal-passthrough-is-actively-checked

label:        contract
statement:    When a request/response is classified as "no compression" or "passthrough," the bytes that leave the proxy must be byte-identical to the bytes that arrived; this invariant is actively verified (a SHA-256 prefix/suffix comparison in tests, a byte-length alarm metric in production) rather than trusted by construction.
exemplar:     `crates/headroom-core/tests/live_zone_dispatch.rs:346`
witnesses:    `crates/headroom-proxy/src/proxy.rs:926`
              `crates/headroom-proxy/tests/integration_chat_completions.rs:71`
guard:        `byte_fidelity_outside_compressed_block` hashes the prefix/suffix outside the rewritten block and asserts equality; the production alarm compares `body_to_send.len()` against `original_buffered_len` for every passthrough-classified outcome and increments `proxy_passthrough_bytes_modified_total` on any delta; `assert_byte_equal_sha256` repeats the same length+hash check end-to-end through a live proxy instance in three separate integration-test files.
unsafe_when:  a new compressor/normalizer path is added to the "passthrough" outcome variants without going through the existing alarm/assert helpers — a byte-length or content regression on a supposedly-untouched body would then ship undetected and silently poison the customer's prompt cache.

## Promoted non-defects

## Brief probes

```bash
UNSAFE_BLOCKS=$(added | grep -cE '\bunsafe\s*\{')
NEW_UNWRAP_EXPECT=$(added | grep -cE '\.(unwrap|expect)\(' )
NEW_MUTEX_RWLOCK=$(added | grep -cE '\b(Mutex|RwLock)::new\(')
NEW_AXUM_ROUTES=$(added | grep -cE '\.route\(\s*"')
AUTH_MODE_TOUCHED=$(added | grep -cE 'AuthMode::(Payg|OAuth|Subscription)|auth_mode::classify\(')
SQL_TOUCHED=$(added | grep -ciE 'conn\.(execute|query_row|prepare)\(|rusqlite')
NEW_CARGO_DEPS=$(git diff --name-only -- '*Cargo.toml' | wc -l | tr -d ' ')
FFI_PYO3_TOUCHED=$(added | grep -cE 'extern "C"|#\[pyfunction\]|#\[pymodule\]|unsafe impl')
TRACING_ON_ERROR_PATHS=$(added | grep -c 'tracing::\(warn\|error\)!')
```

## Dependencies

- `headroom-core`: serde, serde_json, bytes, thiserror, tracing, tiktoken-rs, tokenizers, hf-hub, md-5, sha2, dashmap, regex, icu_segmenter, flate2, fastembed (optional, `ml` feature), magika (optional, `ml` feature), ort (optional, `ml` feature), unidiff, aho-corasick, rayon, toml, blake3, rusqlite (bundled), redis (optional), http, tree-sitter + tree-sitter-python/javascript/typescript/go/rust/java/c/cpp. Dev: proptest, criterion, tempfile.
- `headroom-proxy`: axum, tokio, tower, tower-http, tracing, tracing-subscriber, reqwest, tokio-tungstenite, clap, serde, serde_json, thiserror, uuid, bytes, futures, futures-util, pin-project-lite, http, http-body-util, hyper, url, humantime, bytesize, tokio-util, headroom-core (path), aws-sigv4, aws-config, aws-credential-types, aws-smithy-runtime-api, crc32fast, prometheus, sha2, lru, gcp_auth, async-trait, md-5. Dev: wiremock, hyper-util, tokio-stream, proptest, headroom-simulators (path).
- `headroom-parity`: serde, serde_json, anyhow, clap, thiserror, headroom-core (path).
- `headroom-py`: headroom-core (path), pyo3, pyo3-log, serde_json. Build-dependency: cc (compiles a glibc-compat C shim).
- `headroom-simulators`: axum, tokio, clap, serde, serde_json, thiserror, bytes, tracing, tracing-subscriber, http, crc32fast. Dev: reqwest, tower, http-body-util.
