## Stack scope prefixes

(single-stack repo — `crates/` is Rust only; no prefix needed)

## Wiring files

```
crates/headroom-proxy/src/proxy.rs
crates/headroom-proxy/src/lib.rs
crates/headroom-proxy/src/error.rs
crates/headroom-proxy/src/config.rs
crates/headroom-proxy/src/compression/mod.rs
crates/headroom-proxy/src/handlers/mod.rs
crates/headroom-proxy/src/observability/metric_names.rs
crates/headroom-core/src/lib.rs
crates/headroom-py/src/lib.rs
```

## Label probes

### auth.classify-then-store-in-extensions

label:        auth
statement:    Auth mode is classified once, at request entry, by a single pure function with a documented decision order and a safe default; the result is stashed in request extensions so every downstream stage reads the same classification instead of re-deriving it.
exemplar:     `crates/headroom-core/src/auth_mode.rs:121`
witnesses:    `crates/headroom-core/src/auth_mode.rs:121`
              `crates/headroom-proxy/src/proxy.rs:424`
guard:        `classify()` never panics on malformed headers (non-UTF-8 falls through to `AuthMode::Payg` with a `tracing::warn!`), and its exact per-mode string is asserted stable in an inline test (`auth_mode.rs:225`) because Python parity tests depend on it. `forward_http` calls it exactly once (`proxy.rs:424`) and inserts the result into `req.extensions_mut()` rather than letting each handler re-classify.
unsafe_when:  A new call site re-derives auth mode from headers independently (e.g. a new handler pattern-matching on `Authorization` itself) instead of reading `req.extensions()`, risking a different classification than the one already logged/policied for the request, or a change to the decision order in `classify()` without updating the "most-specific-signal-wins" ordering documented at `auth_mode.rs:89-113` (e.g. checking the broader `sk-` prefix before the more specific `sk-ant-oat` OAuth prefix).

### security.no-silent-fallback-on-upstream-auth

label:        security
statement:    When the proxy must attach its own credentials to an outbound upstream call (AWS SigV4 for Bedrock, GCP ADC bearer tokens for Vertex), a signing/token failure is never swallowed into an unsigned or unauthenticated forward — it surfaces as a structured error and a 5xx, because an unsigned request would otherwise get an opaque upstream 403/401 that's harder to debug.
exemplar:     `crates/headroom-proxy/src/bedrock/sigv4.rs:117`
witnesses:    `crates/headroom-proxy/src/bedrock/sigv4.rs:117`
              `crates/headroom-proxy/src/vertex/adc.rs:66`
guard:        `sign_request` returns `Result<SignedHeaders, SigV4Error>` and the caller is documented to never forward on `Err` (module doc, `sigv4.rs:7-11`); `TokenSource::bearer()` returns `Result<String, TokenSourceError>` and there is deliberately no blanket/default impl — only an explicit production (`GcpAdcTokenSource`) and an explicit test-only (`StaticTokenSource`) implementation (`adc.rs:77-87`), so a missing token source is a compile-time choice, not a runtime silent default.
unsafe_when:  A code path catches a `SigV4Error` or `TokenSourceError` and forwards the request anyway with whatever headers were already present (i.e. treats "couldn't sign/authenticate" as "forward unsigned"), or a new call site invents a third `TokenSource` impl that returns a hardcoded/default token instead of a real error.

### data-exposure.secrets-hashed-before-leaving-module

label:        data-exposure
statement:    Bearer tokens, API keys, and other credential-shaped values used to derive an internal identifier (a session key, a cache key) are SHA-256-hashed before the result is ever passed to a logging call or returned from the module; the raw secret value itself is never logged and never stored.
exemplar:     `crates/headroom-proxy/src/cache_stabilization/drift_detector.rs:504`
witnesses:    `crates/headroom-proxy/src/cache_stabilization/drift_detector.rs:595`
              `crates/headroom-core/src/auth_mode.rs:148`
guard:        `derive_session_key` (`drift_detector.rs:504-542`) only ever returns `hash_secret(token)` / `hash_secret(key)` — never the raw `Authorization` or `x-api-key` value — and `hash_secret` (`drift_detector.rs:595-600`) truncates a SHA-256 digest to a hex prefix. The module doc (`drift_detector.rs:46-59`) states the invariant explicitly: "the raw secret is never logged and never stored." `auth_mode.rs:148-150` independently states the same rule at the classifier boundary ("We must NOT log the value").
unsafe_when:  A new log statement or error message interpolates the raw `Authorization`/`x-api-key`/`x-headroom-session-id` header value (or the raw bearer token) directly, instead of routing it through a hashing helper first — e.g. `tracing::warn!(token = %raw_token, ...)`.

### data-exposure.internal-headers-never-cross-upstream-boundary

label:        data-exposure
statement:    Headers with the `x-headroom-*` internal prefix (session ids, mode flags, bypass flags) are stripped from upstream-bound requests by default so internal proxy state never leaks to the third-party LLM provider or lets a client fingerprint/steer the proxy; disabling the strip is an explicit, logged operator opt-in, never a fallback.
exemplar:     `crates/headroom-proxy/src/headers.rs:105`
witnesses:    `crates/headroom-proxy/src/headers.rs:35`
              `crates/headroom-proxy/src/config.rs:53`
guard:        `is_internal_header` (`headers.rs:55-59`) matches the `x-headroom-` prefix case-insensitively; `strip_internal_headers` (`headers.rs:105-120`) removes every matching entry and returns a count for structured logging. `Config::strip_internal_headers` (`config.rs:53-60`, `StripInternalHeaders::Enabled` by default) gates the strip in `forward_http`, and flipping it to `Disabled` still emits a `tracing::warn!` (`proxy.rs:525-535`) rather than silently changing behavior.
unsafe_when:  A new upstream-bound header-building path (e.g. a new provider handler) builds its own header map without routing through `build_forward_request_headers`/`strip_internal_headers`, so an `x-headroom-*` header added for some other purpose leaks to the upstream API by construction rather than by an explicit disabled flag.

### db.ccr-store-never-panics-loud-failure-only

label:        db
statement:    Every CCR (compressed-content-retrieval) store backend treats storage errors as recoverable: a failed read or write is logged with `tracing::warn!` and the call degrades to `None`/no-op, never a panic — because a missed cache write only means "the model can't retrieve dropped rows on demand later," not a broken request.
exemplar:     `crates/headroom-core/src/ccr/backends/sqlite.rs:231`
witnesses:    `crates/headroom-core/src/ccr/backends/sqlite.rs:231`
              `crates/headroom-core/src/ccr/backends/redis.rs:94`
guard:        `SqliteCcrStore::put` (`sqlite.rs:231-265`) logs `ccr_sqlite_put_failed` and returns on any `rusqlite` error instead of propagating a panic; `RedisCcrStore::put` (`redis.rs:94-134`) does the same for connection and `SETEX` failures. Both backends open with an explicit smoke test at construction time instead (SQLite's `PRAGMA` setup at `sqlite.rs:94-95`; Redis's `PING` round-trip at `redis.rs:65-66`) so startup failures are loud while per-call failures during steady-state traffic are soft.
unsafe_when:  A new CCR backend (or a change to an existing one) calls `.unwrap()`/`.expect()` on a fallible store operation on the request-serving path, turning a transient storage hiccup into a proxy-crashing panic instead of a degraded (but still-serving) response.

### concurrency.serialize-refresh-behind-single-lock-with-double-check

label:        concurrency
statement:    A cached, refreshable resource shared across concurrent request handlers (a GCP bearer token, a SQLite connection) is guarded by a single mutex whose critical section covers the full check-then-maybe-refresh sequence, so concurrent callers either see the fresh cached value or serialize on one refresh rather than racing multiple redundant refreshes.
exemplar:     `crates/headroom-proxy/src/vertex/adc.rs:190`
witnesses:    `crates/headroom-proxy/src/vertex/adc.rs:190`
              `crates/headroom-core/src/ccr/backends/sqlite.rs:177`
guard:        `GcpAdcTokenSource::bearer` (`adc.rs:190-254`) takes a fast-path read under the lock, then re-acquires the same `tokio::sync::Mutex` and double-checks freshness before fetching a new token (`adc.rs:204-211`), so a thundering herd of concurrent callers collapses to one network round-trip. `SqliteCcrStore::get_at` (`sqlite.rs:177-227`) holds one `std::sync::Mutex<Connection>` lock across the lazy-purge sweep and the subsequent row read, with a comment noting this guarantees "the row we read is guaranteed not to have been just-deleted by another caller" (`sqlite.rs:180-183`).
unsafe_when:  A refresh-then-cache pattern releases the lock between the "is it stale?" check and the "write the refreshed value" step, opening a window where two callers both decide to refresh and one's result silently overwrites the other's, or a new caller reads the connection/token outside the shared mutex entirely.

### logic.guard-numeric-inputs-instead-of-propagating-nan-or-panicking

label:        logic
statement:    Functions that take externally-influenced numeric or time inputs (float rates read from telemetry, system-clock reads) clamp/guard invalid values (NaN, negative, pre-epoch) to a safe default instead of letting them propagate into a decision or panicking.
exemplar:     `crates/headroom-core/src/compression_policy.rs:296`
witnesses:    `crates/headroom-core/src/compression_policy.rs:308`
              `crates/headroom-core/src/ccr/backends/sqlite.rs:168`
guard:        `net_mutation_gain_with_write_multiplier` clamps `expected_reads` to `>= 0` via `f32::max` (`compression_policy.rs:308`) and `p_alive` to `[0,1]` with an explicit NaN check (`compression_policy.rs:309-313`), both covered by dedicated tests (`net_gain_guards_nan_inputs`, `compression_policy.rs:574-582`). `SqliteCcrStore::now_unix_seconds` (`sqlite.rs:168-175`) guards `SystemTime::now().duration_since(UNIX_EPOCH)` failing (clock before 1970) by falling through to `0` with a comment explaining it's "impossible on any sane host" but still handled rather than `.unwrap()`'d.
unsafe_when:  A new numeric formula takes an externally-influenced `f32`/`f64` and feeds it straight into arithmetic or a comparison without clamping/NaN-checking first, so a malformed upstream telemetry value or clock anomaly silently corrupts a downstream decision (e.g. always "should mutate" or always "should not") instead of falling back to a documented safe default.

### validation.fail-closed-on-oversized-or-malformed-body-before-mutating

label:        validation
statement:    Body-shape validation at a trust boundary (oversized request, wrong JSON shape) rejects or passes through unchanged as early as possible and before any byte is mutated, using a `let-else`/early-return chain rather than deep nested conditionals.
exemplar:     `crates/headroom-proxy/src/proxy.rs:606`
witnesses:    `crates/headroom-proxy/src/proxy.rs:617`
              `crates/headroom-proxy/src/compression/mod.rs:113`
guard:        `forward_http` checks the `Content-Length` header against `compression_max_body_bytes` and returns `ProxyError::PayloadTooLarge` (413) BEFORE consuming any body bytes when the header is present and oversized (`proxy.rs:606-622`), so the client never sees a partially-consumed body. `sanitize_anthropic_model_id_in_body` (`crates/headroom-proxy/src/compression/mod.rs:113-140`) uses a `let-else` chain that returns the original `body` byte-for-byte the moment any precondition fails (not JSON, no `model` field, not a string, no `[1m]` suffix), never partially applying the sanitization.
unsafe_when:  A validation step consumes/parses the body (or partially mutates a JSON value) before confirming every precondition holds, so a would-be "no-op" path on invalid input actually returns a different byte sequence than what was received — breaking the cache-safety byte-equal-passthrough invariant this codebase repeatedly documents.

### control-flow.explicit-none-arm-never-guess-the-provider

label:        control-flow
statement:    Path/endpoint-to-behavior dispatch is a single exhaustive `match` returning `Option`/an explicit "none of the above" variant, and every call site that needs the classification re-uses that one function rather than re-implementing the mapping or guessing from partial signals.
exemplar:     `crates/headroom-proxy/src/compression/mod.rs:79`
witnesses:    `crates/headroom-proxy/src/compression/mod.rs:79`
              `crates/headroom-proxy/src/proxy.rs:1196`
guard:        `classify_compressible_path` (`crates/headroom-proxy/src/compression/mod.rs:79-86`) is the single source of truth for "which provider does this path belong to," and `is_compressible_path` (`crates/headroom-proxy/src/compression/mod.rs:72-74`) is defined in terms of it rather than duplicating the match. `SseStreamKind::for_request_path` (`proxy.rs:1195-1206`) mirrors the same shape: an exhaustive match with an explicit `_ => Self::None` arm and a comment stating bytes still pass through unchanged when no telemetry parser is registered, rather than guessing a provider from the response content-type.
unsafe_when:  A new handler infers provider/endpoint identity from a heuristic (content-type sniffing, substring match on the body) instead of routing through the shared classifier, so the gate's decision and the dispatcher's decision can disagree for the same request.

### state.bounded-lru-keyed-per-session-not-per-credential

label:        state
statement:    Cross-request state that must persist between turns of the same conversation (cache-drift fingerprints, sticky beta-header tokens) is held in a capacity-bounded LRU keyed by a derived per-conversation session key, never an unbounded map and never keyed on the raw credential alone (which would conflate unrelated concurrent conversations sharing one API key).
exemplar:     `crates/headroom-proxy/src/cache_stabilization/beta_sticky.rs:141`
witnesses:    `crates/headroom-proxy/src/cache_stabilization/beta_sticky.rs:87`
              `crates/headroom-proxy/src/proxy.rs:96`
guard:        `BETA_TRACKER_CAPACITY = 1000` (`beta_sticky.rs:87`) bounds `BetaStickyState`'s `Arc<Mutex<LruCache<...>>>` (`beta_sticky.rs:141-155`); `DRIFT_DETECTOR_CAPACITY = 1000` (`proxy.rs:96`) bounds the sibling `DriftState` held in `AppState` (`proxy.rs:69`). Both document the eviction cost as "telemetry degrades, no request is lost" (`proxy.rs:90-95`), and both are keyed by the same per-conversation `derive_session_key` output (`proxy.rs:724`, reused per `beta_sticky.rs`'s module doc at line 46-51) rather than by credential alone, specifically to avoid cross-conversation state leakage (documented divergence from the Python predecessor at `beta_sticky.rs:53-70`).
unsafe_when:  A new piece of cross-request state is added as an unbounded `HashMap` (unbounded memory growth under a flood of unique sessions) or is keyed on the raw credential/IP alone instead of the derived conversation-aware session key, letting two unrelated concurrent conversations sharing one API key silently share or leak each other's cached state.

### contract.tool-call-and-its-result-must-be-co-treated

label:        contract
statement:    An `assistant` message's tool-call block and the paired `tool_result`/`tool` response are treated as one atomic unit by any code that decides what to compress or drop — compressing or dropping one without the other would desynchronize the conversation and produce a 400 on replay.
exemplar:     `crates/headroom-core/src/transforms/safety.rs:40`
witnesses:    `crates/headroom-core/src/transforms/safety.rs:40`
              `crates/headroom-core/src/transforms/safety.rs:102`
guard:        `tool_pair_indices` (`safety.rs:40-95`) walks both the OpenAI (`tool_calls[].id` / `tool_call_id`) and Anthropic (`tool_use.id` / `tool_result.tool_use_id`) shapes and returns every `(assistant_index, response_index)` pair a caller must co-treat; `collect_assistant_tool_call_ids` (`safety.rs:102-124`) is the single shape-aware id extractor both branches share. Four inline tests (`safety.rs:132-214`) pin both wire shapes plus the "orphaned response is dropped, not paired" edge case.
unsafe_when:  A new compression/drop decision iterates messages independently per-index without first consulting `tool_pair_indices`, so it can compress an `assistant.tool_use` block while leaving its `tool_result` untouched (or vice versa) and produce a request the provider rejects.

### contract.ffi-binding-mirrors-python-dataclass-field-for-field

label:        contract
statement:    Every PyO3 type exposed to Python mirrors the corresponding Python dataclass's field names, types, and constructor keyword-argument order exactly, and every method that does real compute releases the GIL (`py.detach`) around the pure-Rust portion so the binding is a transparent, non-blocking swap-in for the Python implementation it replaces.
exemplar:     `crates/headroom-py/src/lib.rs:421`
witnesses:    `crates/headroom-py/src/lib.rs:421`
              `crates/headroom-py/src/lib.rs:764`
guard:        `PyDiffCompressor::compress` (`crates/headroom-py/src/lib.rs:412-426`) and `PySmartCrusher::crush` (`lib.rs:755-769`) both copy `&str` inputs to owned `String`s, then call `py.detach(|| ...)` around the actual Rust compute — documented at each site as freeing concurrent Python threads during the parse/compress work. Getter names and constructor `#[pyo3(signature = ...)]` defaults (e.g. `PyDiffCompressorConfig::new`, `lib.rs:112-146`) are written to match the Python dataclass field-for-field so `RustBackedDiffCompressor` swaps in without call-site changes.
unsafe_when:  A new PyO3 binding renames a field, reorders constructor kwargs, or changes a default relative to the Python dataclass it mirrors (breaking the drop-in-swap contract), or a compute-heavy method omits `py.detach`, holding the GIL across a multi-millisecond parse/compress and blocking every other Python thread in the process.

### duplication.endpoint-classification-has-one-call-site-of-truth

label:        duplication
statement:    Where the same classification decision (which provider/endpoint a request belongs to) gates both an early cheap check and a later expensive dispatch, both call sites go through the same function rather than each re-deriving or re-matching the same logic.
exemplar:     `crates/headroom-proxy/src/compression/mod.rs:72`
witnesses:    `crates/headroom-proxy/src/compression/mod.rs:72`
              `crates/headroom-proxy/src/proxy.rs:654`
guard:        `is_compressible_path` (`crates/headroom-proxy/src/compression/mod.rs:72-74`) is a one-line wrapper around `classify_compressible_path`; `forward_http`'s gate calls `is_compressible_path` first (`proxy.rs:573`) and then, inside the buffered branch, re-calls `classify_compressible_path` directly (`proxy.rs:654-655`) rather than a hand-rolled second match — the comment at `proxy.rs:640-646` states this explicitly: "a single-source `match` decides which dispatcher runs and what skip rules apply."
unsafe_when:  A new provider is added by pattern-matching on `uri.path()` again at a new call site instead of adding a variant to `CompressibleEndpoint`/`classify_compressible_path`, so the path string has to be kept in sync by hand across two or more match arms.

### duplication.session-identity-derived-once-shared-by-both-subsystems

label:        duplication
statement:    Where two independent cache-stability subsystems both need "which conversation is this," they share one session-key derivation function rather than each deriving their own notion of session identity (which could disagree and desync).
exemplar:     `crates/headroom-proxy/src/cache_stabilization/drift_detector.rs:504`
witnesses:    `crates/headroom-proxy/src/cache_stabilization/drift_detector.rs:504`
              `crates/headroom-proxy/src/proxy.rs:739`
guard:        `derive_session_key` (`drift_detector.rs:504-542`) is called once per request (`proxy.rs:724`) and its output, `session_key`, is threaded into both `observe_drift` (drift detector) and `apply_sticky_betas` (beta-header tracker) at `proxy.rs:726` and `proxy.rs:754-761`; the comment at `proxy.rs:739-741` states the two subsystems deliberately "agree on conversation identity" via the shared key rather than each computing their own.
unsafe_when:  A new cache-stability subsystem computes its own session/conversation key from headers instead of reusing `derive_session_key`'s output, risking two subsystems disagreeing about which requests belong to the same conversation.

### dead-code.unused-variant-kept-with-doc-explaining-why

label:        dead-code
statement:    An enum variant that exists for a not-yet-wired future code path (or a rare error path with no current producer) is annotated `#[allow(dead_code)]` together with a doc comment naming what will consume it, rather than being deleted or left with a bare, unexplained `allow`.
exemplar:     `crates/headroom-proxy/src/compression/live_zone_anthropic.rs:78`
witnesses:    `crates/headroom-proxy/src/compression/live_zone_anthropic.rs:84`
              `crates/headroom-core/src/transforms/live_zone.rs:1312`
guard:        `Outcome::Compressed` (`live_zone_anthropic.rs:84-98`) carries `#[allow(dead_code)]` plus a doc comment stating it's "Reserved for PR-B3+: live-zone compression actually ran"; `DispatchResult::Error` (`live_zone.rs:1302-1317`) carries the same annotation with a doc comment explaining the error string "is surfaced via the manifest; the proxy logs it." Neither is a bare `#[allow(dead_code)]`.
unsafe_when:  A new unused variant/function gets `#[allow(dead_code)]` with no accompanying comment saying why it's kept or what future work wires it up, making it indistinguishable from accidental dead code a later cleanup pass should delete.

### layering.core-crate-has-no-dependents-among-its-siblings

label:        layering
statement:    `headroom-core` is a pure foundation crate: every other crate in the workspace depends on it by path, but it never depends back on any of them — the dependency edge is one-directional.
exemplar:     `crates/headroom-proxy/Cargo.toml:43`
witnesses:    `crates/headroom-proxy/Cargo.toml:43`
              `crates/headroom-py/Cargo.toml:35`
guard:        `crates/headroom-proxy/Cargo.toml:43`, `crates/headroom-py/Cargo.toml:35`, and `crates/headroom-parity/Cargo.toml:23` each declare `headroom-core = { path = "../headroom-core" }`; `crates/headroom-core/Cargo.toml`'s own `[dependencies]` table (lines 10-177) lists only third-party crates — no path dependency on `headroom-proxy`, `headroom-py`, `headroom-parity`, or `headroom-simulators` appears anywhere in it.
unsafe_when:  `headroom-core`'s `Cargo.toml` gains a path dependency on any sibling crate (even a dev-dependency for a "shared test fixture"), which would make the foundation crate depend on one of its own consumers and turn the workspace's dependency graph circular.

## Promoted non-defects

## Brief probes

```bash
# New/changed axum route registrations — every route added to build_app
# should be reviewed for whether it needs the same auth-mode + compression
# gate as the existing catch-all, and whether it's behind a Config flag.
git diff -U0 -- 'crates/headroom-proxy/src/proxy.rs' | grep -n '\.route('

# Newly added tracing::warn!/error! calls that don't carry a structured
# `event = "..."` field — this repo's convention keys every log line for
# dashboards; an un-keyed warn/error breaks that.
git diff -U0 --diff-filter=AM -- 'crates/**/*.rs' | grep -E '^\+' | grep -E 'tracing::(warn|error)!\(' | grep -v 'event ='

# Any added .unwrap()/.expect() outside #[cfg(test)] modules — this repo's
# convention is "loud structured error, never a request-path panic".
git diff -U0 -- 'crates/**/*.rs' | grep -E '^\+' | grep -E '\.(unwrap|expect)\(' 

# Newly introduced `unsafe` Rust — crates/ has zero `unsafe {}` / `unsafe fn`
# / `unsafe impl` blocks today; any addition is a first-of-its-kind and
# deserves scrutiny disproportionate to its size.
git diff -U0 -- 'crates/**/*.rs' | grep -E '^\+' | grep -E '\bunsafe\b'

# Changes touching Authorization / x-api-key / x-goog-api-key / bearer
# token handling — verify any new log/format call routes the value through
# a hashing helper (see data-exposure probes) instead of interpolating raw.
git diff -- 'crates/headroom-proxy/src/**/*.rs' 'crates/headroom-core/src/**/*.rs' | grep -niE 'authorization|x-api-key|x-goog-api-key|bearer'

# Changes to the CCR store backends (sqlite/redis/in_memory) — check every
# new fallible call is logged-and-degraded, not propagated as a panic, and
# that a schema change ships a migrate-in-place path like `sqlite.rs`'s.
git diff --stat -- 'crates/headroom-core/src/ccr/'

# Cargo.toml dependency version changes — this repo pins several crates
# exactly (`=x.y.z`) with a documented reason (tree-sitter grammar parity,
# prometheus v0.13 gather() semantics); a version bump on a pinned dep
# needs the same re-validation the pinning comment calls for.
git diff -- '**/Cargo.toml' | grep -E '^[+-].*= *"?=?[0-9]'

# New/changed build.rs or *.c files — the only native/FFI-adjacent build
# surface in crates/ (headroom-py's glibc shim); changes here are
# platform-specific linker behavior and easy to get subtly wrong.
git diff --stat -- 'crates/headroom-py/build.rs' 'crates/headroom-py/*.c'

# Changes to the byte-equal passthrough path (buffered body handling in
# proxy.rs) — confirm any new mutation is still gated so the
# NoCompression/Passthrough arms stay byte-length-identical to the input.
git diff -U5 -- 'crates/headroom-proxy/src/proxy.rs' | grep -n -B2 -A2 'body_to_send\|original_buffered_len'
```

## Dependencies

**headroom-core** (`crates/headroom-core/Cargo.toml`): serde, serde_json, bytes, thiserror, tracing, tiktoken-rs, tokenizers, hf-hub, md-5, sha2, dashmap, regex, icu_segmenter, flate2, fastembed (optional, `ml` feature), magika (optional, `ml` feature), unidiff, aho-corasick, rayon, toml, blake3, rusqlite, redis (optional, `redis` feature), http, tree-sitter + tree-sitter-{python,javascript,typescript,go,rust,java,c,cpp}, ort (optional, `ml` feature).

**headroom-proxy** (`crates/headroom-proxy/Cargo.toml`): axum, tokio, tower, tower-http, tracing, tracing-subscriber, reqwest, tokio-tungstenite, clap, serde, serde_json, thiserror, uuid, bytes, futures, futures-util, pin-project-lite, http, http-body-util, hyper, url, humantime, bytesize, tokio-util, headroom-core (path), aws-sigv4, aws-config, aws-credential-types, aws-smithy-runtime-api, crc32fast, prometheus (pinned `=0.14.0`), sha2, lru, gcp_auth, async-trait, md-5.

**headroom-parity** (`crates/headroom-parity/Cargo.toml`): serde, serde_json, anyhow, clap, thiserror, headroom-core (path).

**headroom-py** (`crates/headroom-py/Cargo.toml`): headroom-core (path), pyo3, pyo3-log, serde_json; build-dependency: cc.

**headroom-simulators** (`crates/headroom-simulators/Cargo.toml`): axum, tokio, clap, serde, serde_json, thiserror, bytes, tracing, tracing-subscriber, http, crc32fast.
