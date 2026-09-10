## Stack scope prefixes

Single-stack repo under this scope — everything in `crates/` is Rust (2021/2024 edition, workspace-managed). No per-stack prefix split is needed; the five crate roots double as the natural scope boundaries:

- `crates/headroom-core/` — pure transform/compression library, no I/O framework deps.
- `crates/headroom-proxy/` — axum HTTP reverse proxy (binary + lib).
- `crates/headroom-parity/` — Rust-vs-Python parity harness (binary + lib).
- `crates/headroom-py/` — PyO3 bindings (`cdylib`), exposes `headroom-core` to Python.
- `crates/headroom-simulators/` — axum-based local provider simulators (binary + lib).

## Wiring files

```
crates/headroom-core/src/lib.rs
crates/headroom-core/src/transforms/mod.rs
crates/headroom-core/src/auth_mode.rs
crates/headroom-proxy/src/lib.rs
crates/headroom-proxy/src/proxy.rs
crates/headroom-proxy/src/error.rs
crates/headroom-proxy/src/handlers/mod.rs
crates/headroom-proxy/src/compression/mod.rs
crates/headroom-core/src/ccr/mod.rs
crates/headroom-core/src/ccr/backends/mod.rs
crates/headroom-py/src/lib.rs
```

## Label probes

### auth.classify-precedence

label:        auth
statement:    A request's auth tier is decided by one pure classifier function that checks signals in a fixed, documented precedence order (most-specific signal first) and always falls through to a safe, named default rather than panicking or guessing.
exemplar:     `crates/headroom-core/src/auth_mode.rs:121-210`
witnesses:    `crates/headroom-core/src/auth_mode.rs:121-210`
              `crates/headroom-core/src/auth_mode.rs:78-87`
guard:        `classify` (`crates/headroom-core/src/auth_mode.rs:121`) checks the Subscription UA-prefix list first (`crates/headroom-core/src/auth_mode.rs:140-145`) — documented as "most-specific signal wins" — before falling to the `Authorization` bearer-token shape (`crates/headroom-core/src/auth_mode.rs:164-191`), then vendor API-key headers (`crates/headroom-core/src/auth_mode.rs:196-202`), and finally an explicit default of `AuthMode::Payg` (`crates/headroom-core/src/auth_mode.rs:204-209`) rather than an unwrap/panic. Non-UTF-8 headers are caught and logged, never propagated as an error (`crates/headroom-core/src/auth_mode.rs:130-136`, `crates/headroom-core/src/auth_mode.rs:153-159`).
unsafe_when:  A new auth signal is added as an early return without documenting why it must run before or after existing checks (e.g. checking the broad `sk-` PAYG prefix before the more specific `sk-ant-oat` OAuth prefix, which the existing code explicitly orders the other way at `crates/headroom-core/src/auth_mode.rs:164-174`), or a header-parse failure is allowed to propagate as an `Err`/panic instead of falling through to the logged default.

### security.strip-internal-headers

label:        security
statement:    Internal-only signaling headers (the `x-headroom-*` namespace) and hop-by-hop headers are stripped from the outbound request via a single named prefix/list check, not scattered per-call-site string comparisons, and the strip is itself operator-toggleable and logged.
exemplar:     `crates/headroom-proxy/src/headers.rs:105-120`
witnesses:    `crates/headroom-proxy/src/headers.rs:38-51`
              `crates/headroom-proxy/src/headers.rs:132-169`
guard:        `INTERNAL_HEADER_PREFIX` is a single constant (`crates/headroom-proxy/src/headers.rs:35`), `is_internal_header` does one case-insensitive prefix check against it (`crates/headroom-proxy/src/headers.rs:55-59`), and `strip_internal_headers` (`crates/headroom-proxy/src/headers.rs:105-120`) drains every matching header and returns a count for structured logging. `build_forward_request_headers` (`crates/headroom-proxy/src/headers.rs:132-169`) is the one place that assembles the final outbound header set, applying hop-by-hop stripping (`crates/headroom-proxy/src/headers.rs:143`), `Connection:`-listed stripping (`crates/headroom-proxy/src/headers.rs:146`), and the internal-header gate (`crates/headroom-proxy/src/headers.rs:149`) in one pass.
unsafe_when:  A new internal signaling header is introduced that doesn't start with `x-headroom-` (so `is_internal_header` never catches it and it leaks upstream), or a handler builds its own outbound `HeaderMap` by hand instead of calling `build_forward_request_headers`, bypassing the strip entirely.

### data-exposure.session-scoped-cache-isolation

label:        data-exposure
statement:    Per-conversation cached state (sticky beta headers, structural-hash drift state) is keyed by a composite `(provider, session)` or per-conversation identity, not a coarser key, so one tenant's/session's request bytes can never leak into another session's forwarded request — and the isolation is pinned by an explicit integration test.
exemplar:     `crates/headroom-proxy/src/cache_stabilization/beta_sticky.rs:168-199`
witnesses:    `crates/headroom-proxy/src/cache_stabilization/beta_sticky.rs:132-157`
              `crates/headroom-proxy/tests/integration_beta_header_sticky.rs:434-476`
guard:        `BetaStickyState` stores sessions in a map keyed by `(BetaProvider, String)` (`crates/headroom-proxy/src/cache_stabilization/beta_sticky.rs:132-133`, `crates/headroom-proxy/src/cache_stabilization/beta_sticky.rs:141-143`), and `record_and_get_sticky_betas` builds the lookup key from `(provider, session_key.to_string())` (`crates/headroom-proxy/src/cache_stabilization/beta_sticky.rs:189`) before ever unioning tokens — two different `session_key` values can never share a token bucket. The integration test `separate_conversations_do_not_leak_tokens` (`crates/headroom-proxy/tests/integration_beta_header_sticky.rs:434-476`) posts two different `x-headroom-session-id` values and asserts conversation B's forwarded beta header never contains conversation A's token (`crates/headroom-proxy/tests/integration_beta_header_sticky.rs:469-473`).
unsafe_when:  A new session-scoped cache is keyed on something coarser than the full conversation identity — e.g. `(model, system-prompt-hash)` alone, which the beta_sticky module doc explicitly calls out as the Python behavior this port deliberately diverged from because it let parallel agentic conversations cross-inherit tokens (`crates/headroom-proxy/src/cache_stabilization/beta_sticky.rs:53-70`).

### db.parameterized-lazy-purge

label:        db
statement:    Every SQLite statement is a prepared/parameterized query (never string-formatted SQL), and time-based expiry is enforced with a lazy purge-then-read under the same lock/transaction rather than a separate background sweep that could race the read.
exemplar:     `crates/headroom-core/src/ccr/backends/sqlite.rs:177-227`
witnesses:    `crates/headroom-core/src/ccr/backends/sqlite.rs:231-265`
              `crates/headroom-core/src/ccr/backends/sqlite.rs:97-119`
guard:        `get_at` (`crates/headroom-core/src/ccr/backends/sqlite.rs:177-227`) takes the connection mutex once, runs `purge_expired` (parameterized via `params![now as i64, ...]`, `crates/headroom-core/src/ccr/backends/sqlite.rs:159-165`) and the row `SELECT` (also `params![hash, now as i64, ...]`, `crates/headroom-core/src/ccr/backends/sqlite.rs:191-199`) under that same held lock — the comment at `crates/headroom-core/src/ccr/backends/sqlite.rs:180-182` states this guarantees "the row we read is guaranteed not to have been just-deleted by another caller." `put` (`crates/headroom-core/src/ccr/backends/sqlite.rs:231-265`) upserts via `ON CONFLICT(hash) DO UPDATE` with bound params (`crates/headroom-core/src/ccr/backends/sqlite.rs:236-249`), never string concatenation.
unsafe_when:  A new query builds SQL by interpolating a caller-supplied value into the string (e.g. `format!("... WHERE hash = '{hash}'")`) instead of `params![...]`, or a purge/expiry check is added as a separate connection/transaction from the read it's supposed to protect, reopening the race the single-mutex design was built to close.

### concurrency.sharded-map-with-serialized-eviction

label:        concurrency
statement:    A hot concurrent map (`DashMap`) is used for the high-traffic key lookup so distinct keys never contend, while the one genuinely serial operation (capacity-bound FIFO eviction) is isolated behind its own small `Mutex` rather than locking the whole map.
exemplar:     `crates/headroom-core/src/ccr/backends/in_memory.rs:34-44`
witnesses:    `crates/headroom-core/src/ccr/backends/in_memory.rs:90-144`
              `crates/headroom-proxy/src/cache_stabilization/beta_sticky.rs:176-187`
guard:        `InMemoryCcrStore` holds the entries in a `DashMap<String, Entry>` (`crates/headroom-core/src/ccr/backends/in_memory.rs:35`) and the eviction-order queue in a *separate* `Mutex<VecDeque<String>>` (`crates/headroom-core/src/ccr/backends/in_memory.rs:40`) — the module doc states "gets and puts on distinct keys do not contend. The only serialization point is the insertion-order queue" (`crates/headroom-core/src/ccr/backends/in_memory.rs:30-33`). `evict_until_under_capacity` (`crates/headroom-core/src/ccr/backends/in_memory.rs:90-100`) only ever locks the order queue, never the whole map. Separately, `record_and_get_sticky_betas` treats a poisoned `Mutex` as a fail-open condition (log + return the client value verbatim) rather than propagating a panic (`crates/headroom-proxy/src/cache_stabilization/beta_sticky.rs:176-187`).
unsafe_when:  A new eviction or bookkeeping path takes a lock on the `DashMap` itself (e.g. iterating the whole map to find the oldest entry) instead of using the dedicated order structure, reintroducing map-wide contention on the hot get/put path; or a new `Mutex::lock()` call site uses `.unwrap()` instead of matching on the poisoned case and failing open.

### logic.centralized-mode-policy-struct

label:        logic
statement:    Per-mode (per-auth-tier) behavioral decisions are resolved once into a plain data struct by a single `for_mode`-style function, and every downstream call site reads a struct field — rather than each call site independently `match`-ing on the mode and duplicating the mapping.
exemplar:     `crates/headroom-core/src/compression_policy.rs:203-239`
witnesses:    `crates/headroom-core/src/compression_policy.rs:162-196`
              `crates/headroom-core/src/compression_policy.rs:1-19`
guard:        The module doc states the rationale directly: "Without a policy struct, the per-mode decision is duplicated at every gate... The struct is the one place to edit; call sites just read `policy.field`" (`crates/headroom-core/src/compression_policy.rs:13-19`). `CompressionPolicy` (`crates/headroom-core/src/compression_policy.rs:162-196`) holds every per-mode-tunable field, and `CompressionPolicy::for_mode` (`crates/headroom-core/src/compression_policy.rs:206-239`) is the single `match AuthMode { ... }` that produces it.
unsafe_when:  A new call site adds its own `match auth_mode { AuthMode::Payg => ..., AuthMode::OAuth => ... }` to make a mode-dependent decision instead of calling `CompressionPolicy::for_mode` and reading a field — the values then have two places to update and can silently drift apart.

### validation.precheck-before-consume

label:        validation
statement:    A size/length limit is checked against a cheap, already-available signal (`Content-Length` header) *before* any expensive or irreversible consumption of the body, and the exhaustive fallback check (buffering with a hard cap) is a separate, later guard for when the cheap signal is absent (chunked transfer).
exemplar:     `crates/headroom-proxy/src/proxy.rs:599-621`
witnesses:    `crates/headroom-proxy/src/proxy.rs:623-638`
              `crates/headroom-proxy/src/error.rs:28-29`
guard:        The comment at `crates/headroom-proxy/src/proxy.rs:599-604` explains the ordering: "pre-check `Content-Length` against the cap BEFORE consuming any body bytes... clients never see a partially-consumed body." The `Content-Length` check (`crates/headroom-proxy/src/proxy.rs:607-621`) returns `ProxyError::PayloadTooLarge` immediately; only if that passes does the code fall into the buffered `to_bytes(..., max)` call with its own cap-triggered error path (`crates/headroom-proxy/src/proxy.rs:623-638`). `PayloadTooLarge` maps to HTTP 413 specifically because RFC 7231 requires it, per the doc comment on the error variant (`crates/headroom-proxy/src/error.rs:24-29`).
unsafe_when:  A new size-limited body path calls `to_bytes`/buffers the request first and only checks `Content-Length` afterward (or not at all), so an oversized body is partially or fully consumed before the request is rejected — wasting the buffer and, per the existing comment, making the body unresumable as a stream.

### control-flow.explicit-path-classification-enum

label:        control-flow
statement:    Dispatch across provider-specific code paths is driven by a single classification function returning a closed enum (one match arm per known path, explicit `None`/`_` for unknown), rather than a chain of independent boolean path-string comparisons scattered across call sites.
exemplar:     `crates/headroom-proxy/src/compression/mod.rs:79-86`
witnesses:    `crates/headroom-proxy/src/compression/mod.rs:60-68`
              `crates/headroom-proxy/src/compression/mod.rs:72-74`
guard:        `CompressibleEndpoint` (`crates/headroom-proxy/src/compression/mod.rs:60-68`) is a closed enum with one variant per known provider path. `classify_compressible_path` (`crates/headroom-proxy/src/compression/mod.rs:79-86`) is the single `match path { ... _ => None }` that produces it, documented as keeping "the cache scope explicit" (`crates/headroom-proxy/src/compression/mod.rs:77-78`). `is_compressible_path` (`crates/headroom-proxy/src/compression/mod.rs:72-74`) is defined purely in terms of it (`.is_some()`), so there is exactly one source of truth for "is this path compressible."
unsafe_when:  A new provider route is wired into `build_app` (`crates/headroom-proxy/src/proxy.rs`) that checks `path == "/v1/whatever"` directly at the call site to decide whether to compress, instead of adding a variant to `CompressibleEndpoint` and a match arm in `classify_compressible_path` — the path-to-provider mapping then exists in two places that can disagree.

### state.bounded-lru-shared-via-arc-clone

label:        state
statement:    Session-scoped mutable state that must be visible from every handler is wrapped once in `Arc<Mutex<...>>` (or an equivalent internally-shared type) behind a small `Clone` wrapper struct, constructed once in `AppState::new`, and cloned cheaply into every request path rather than re-created or passed by unshared reference.
exemplar:     `crates/headroom-proxy/src/cache_stabilization/beta_sticky.rs:132-157`
witnesses:    `crates/headroom-proxy/src/proxy.rs:69-76`
              `crates/headroom-proxy/src/proxy.rs:121-124`
guard:        `BetaStickyState` derives `Clone` and holds only `Arc<Mutex<SessionTokenCache>>` (`crates/headroom-proxy/src/cache_stabilization/beta_sticky.rs:140-143`), with the doc noting "Cloning shares the underlying map (`Arc`)... so one instance lives in `AppState` and clones freely into every handler path" (`crates/headroom-proxy/src/cache_stabilization/beta_sticky.rs:137-139`). `AppState` documents the equivalent `drift_state: DriftState` field the same way (`crates/headroom-proxy/src/proxy.rs:69-76`) and both are constructed exactly once in `AppState::new` (`crates/headroom-proxy/src/proxy.rs:121-124`).
unsafe_when:  A new piece of per-session state is added as a bare `Mutex<...>` field directly on `AppState` (not wrapped in its own `Arc`-backed `Clone` type) — cloning `AppState` per request (as axum does) would then either fail to compile or silently give each clone its own independent lock instead of sharing state across requests.

### contract.no-silent-fallback-init

label:        contract
statement:    A pluggable-backend factory surfaces every initialization failure to the caller as a typed `Result` error rather than silently downgrading to a weaker default backend; the trait the backends implement is a minimal, storage-agnostic contract (put/get/len) with no backend-specific leakage.
exemplar:     `crates/headroom-core/src/ccr/backends/mod.rs:93-97`
witnesses:    `crates/headroom-core/src/ccr/backends/mod.rs:62-84`
              `crates/headroom-core/src/ccr/mod.rs:38-57`
guard:        `from_config` (`crates/headroom-core/src/ccr/backends/mod.rs:97`) is documented as guaranteeing "a successful return... has already cleared its readiness check" (`crates/headroom-core/src/ccr/backends/mod.rs:93-96`), and its module doc states plainly "there is no silent fallback to the in-memory backend" (`crates/headroom-core/src/ccr/backends/mod.rs:5-7`). `CcrBackendInitError` (`crates/headroom-core/src/ccr/backends/mod.rs:65-84`) has one variant per real failure mode, including `UnsupportedBackend` for a feature-gated backend that wasn't compiled in. The `CcrStore` trait itself (`crates/headroom-core/src/ccr/mod.rs:40-57`) exposes only `put`/`get`/`len`/`is_empty` — no backend-specific methods leak through it.
unsafe_when:  A new backend variant is added to `from_config` that, on an init error, falls back to constructing `InMemoryCcrStore` instead of propagating `CcrBackendInitError` — an operator who configured SQLite or Redis would then silently get an ephemeral, non-persistent store with no error surfaced.

### duplication.shared-tool-sort-across-providers

label:        duplication
statement:    A byte-shape-affecting transform needed by multiple provider-specific request walkers (Anthropic, OpenAI Chat, OpenAI Responses) is implemented exactly once in a shared module and imported by all three walkers, rather than each walker reimplementing its own version of the same sort/normalize logic.
exemplar:     `crates/headroom-proxy/src/cache_stabilization/tool_def_normalize.rs:45-79`
witnesses:    `crates/headroom-proxy/src/compression/live_zone_anthropic.rs:672`
              `crates/headroom-proxy/src/compression/live_zone_openai.rs:395`
              `crates/headroom-proxy/src/compression/live_zone_responses.rs:403`
guard:        `sort_tools_deterministically` is defined once (`crates/headroom-proxy/src/cache_stabilization/tool_def_normalize.rs:70-79`) and imported identically by all three provider modules (`crates/headroom-proxy/src/compression/live_zone_anthropic.rs:52-53`, `crates/headroom-proxy/src/compression/live_zone_openai.rs:39-40`, `crates/headroom-proxy/src/compression/live_zone_responses.rs:43-44`), each calling the exact same function at their respective E1 tool-sort call sites (`crates/headroom-proxy/src/compression/live_zone_anthropic.rs:672`, `crates/headroom-proxy/src/compression/live_zone_openai.rs:395`, `crates/headroom-proxy/src/compression/live_zone_responses.rs:403`). The sort-key fallback logic (MD5 of canonical JSON for unnamed tools) lives in one private helper (`crates/headroom-proxy/src/cache_stabilization/tool_def_normalize.rs:81-90`), not copy-pasted per provider.
unsafe_when:  A new provider walker (e.g. a future Gemini module) reimplements its own tool-array sort instead of importing `sort_tools_deterministically` — the sort-key rule (name vs `function.name` vs MD5 fallback) then has to be kept in sync by hand across N copies instead of one.

### dead-code.documented-plumbed-unconsumed-field

label:        dead-code
statement:    A struct field that is written but not yet read by any consumer is only acceptable when it is explicitly documented as "plumbed but unconsumed," named after the follow-up work item that will consume it, and still covered by tests/serialization — an undocumented unused field or unreachable branch is not the same thing and should be flagged.
exemplar:     `crates/headroom-core/src/compression_policy.rs:171-178`
witnesses:    `crates/headroom-core/src/compression_policy.rs:180-189`
              `crates/headroom-core/src/compression_policy.rs:56-60`
guard:        `volatile_token_threshold` is explicitly annotated "NOT consumed by any detector in F2.2 — plumbed through the struct so the volatile detector refactor in a follow-up PR has a stable hook to read from" (`crates/headroom-core/src/compression_policy.rs:175-177`), and `max_lossy_ratio` carries the identical style of disclosure naming its own follow-up (`crates/headroom-core/src/compression_policy.rs:185-188`). Both fields are still part of the public, tested `CompressionPolicy` struct and populated by every arm of `for_mode` (`crates/headroom-core/src/compression_policy.rs:206-239`) — they are reachable, serializable, parity-tested data, not dead branches.
unsafe_when:  A field or function is left unused with no comment explaining why, or is marked `#[allow(dead_code)]` to silence the compiler instead of either wiring it up or documenting the specific future consumer the way `compression_policy.rs` does — the difference between "intentionally staged" and "actually dead" is exactly that documentation.

### layering.thin-binding-delegates-to-core

label:        layering
statement:    The Python-binding crate contains no compression/business logic of its own — every `#[pyfunction]`/`#[pymethods]` implementation is a thin type-conversion wrapper around a `headroom_core::` call, keeping all algorithmic logic in the core crate so Rust and Python share exactly one implementation.
exemplar:     `crates/headroom-py/src/lib.rs:1-48`
witnesses:    `crates/headroom-py/src/lib.rs:52-56`
              `crates/headroom-core/src/ccr/mod.rs:1-31`
guard:        The module doc states the binding exists so "the Python `ContentRouter` can route to the Rust implementation in-process via PyO3 instead of running the Python port" (`crates/headroom-py/src/lib.rs:5-7`), and every import at the top of the file aliases a `headroom_core::transforms::*` type with a `Rust*` prefix (`crates/headroom-py/src/lib.rs:18-48`) rather than redefining it. Even the trivial `hello()` binding delegates instead of hardcoding the string: `headroom_core::hello()` (`crates/headroom-py/src/lib.rs:55`). Separately, `crates/headroom-core/src/ccr/mod.rs:1-31` documents the inverse layering boundary — the CCR crate deliberately excludes "BM25 search," "retrieval-event feedback," and "per-tool metadata," stating "those live in the runtime layer; this crate only needs put/get" (`crates/headroom-core/src/ccr/mod.rs:13-14`).
unsafe_when:  New logic (a new heuristic, a new validation rule, a new default) is added directly inside `crates/headroom-py/src/lib.rs` rather than in `headroom-core` and then exposed via a thin wrapper — Rust callers of `headroom-core` and Python callers of `headroom._core` would then silently diverge in behavior.

### ownership.trait-object-swap-for-tests

label:        ownership
statement:    A resource that must never be faked silently in tests (a live external-credential source) is owned behind a `dyn Trait` object (`Arc<dyn Trait>`) on shared state, with exactly two named implementations — one real, one explicitly test-only — swapped via a dedicated constructor rather than a feature flag or conditional compilation inside the real implementation.
exemplar:     `crates/headroom-proxy/src/vertex/adc.rs:77-87`
witnesses:    `crates/headroom-proxy/src/proxy.rs:82`
              `crates/headroom-proxy/src/proxy.rs:142-149`
              `crates/headroom-proxy/src/vertex/adc.rs:261-274`
guard:        `TokenSource` (`crates/headroom-proxy/src/vertex/adc.rs:82-87`) is documented as deliberately an abstraction because "Tests must NOT hit real GCP... we need a mock implementation that is explicit and distinct from production" (`crates/headroom-proxy/src/vertex/adc.rs:12-14`), giving "exactly two impls: production (`GcpAdcTokenSource`) and tests (`StaticTokenSource`)" (`crates/headroom-proxy/src/vertex/adc.rs:15-17`, impls at `crates/headroom-proxy/src/vertex/adc.rs:189` and `crates/headroom-proxy/src/vertex/adc.rs:274`). `AppState` owns it as `Arc<dyn crate::vertex::TokenSource>` (`crates/headroom-proxy/src/proxy.rs:82`), and `AppState::with_token_source` (`crates/headroom-proxy/src/proxy.rs:142-149`) is the one explicit constructor tests use to substitute the static source — production code always goes through `AppState::new`.
unsafe_when:  A test reaches for a `#[cfg(test)]` branch *inside* `GcpAdcTokenSource` itself (short-circuiting the real ADC chain when some test-only env var is set) instead of constructing `AppState::with_token_source(config, Arc::new(StaticTokenSource::...))` — that reintroduces exactly the "silent fallback" risk the trait split was built to avoid, and means a misconfigured production deploy could accidentally trip the test branch.

## Promoted non-defects

(none — no ledger history exists yet for this repo)

## Brief probes

```bash
# Router registration touch: new/changed axum route wiring in the proxy's
# central router-assembly function.
grep -nE '\.route\(|Router::new\(|route_layer\(|DefaultBodyLimit::' -- "$@" 2>/dev/null

# "Money"-analog for this repo: there's no literal currency handling under
# crates/, but token-budget / byte-cap / compression-ratio constants are the
# closest cost-bearing surface (misconfiguring these directly costs the
# customer money via over/under compression or oversized payload rejection).
grep -nE 'max_lossy_ratio|max_body_bytes|compression_max_body_bytes|ttl_seconds|DEFAULT_CAPACITY|token_savings' -- "$@" 2>/dev/null

# Migration path: SQLite schema evolution / legacy-schema backfill touch.
grep -nE 'migrate_legacy_schema|ALTER TABLE|CREATE TABLE|PRAGMA|pragma_update' -- "$@" 2>/dev/null

# Lockfile/deps touch: dependency manifest changes.
grep -nE '^\[dependencies\]|^\[dev-dependencies\]|^\[build-dependencies\]|^\[features\]' -- "$@" 2>/dev/null
find . -maxdepth 3 -name 'Cargo.toml' -newer /dev/null 2>/dev/null | grep -E 'crates/'
```

## Dependencies

### headroom-core

serde, serde_json, bytes, thiserror, tracing, tiktoken-rs, tokenizers, hf-hub, md-5, sha2, dashmap, regex, icu_segmenter, flate2, fastembed (optional, `ml` feature), ort (optional, `ml` feature), unidiff, aho-corasick, rayon, toml, blake3, rusqlite (bundled), redis (optional, `redis` feature), http, tree-sitter, tree-sitter-python, tree-sitter-javascript, tree-sitter-typescript, tree-sitter-go, tree-sitter-rust, tree-sitter-java, tree-sitter-c, tree-sitter-cpp, magika (optional, `ml` feature).
Dev-dependencies: proptest, criterion, tempfile.

### headroom-proxy

axum, tokio, tower, tower-http, tracing, tracing-subscriber, reqwest, tokio-tungstenite, clap, serde, serde_json, thiserror, uuid, bytes, futures, futures-util, pin-project-lite, http, http-body-util, hyper, url, humantime, bytesize, tokio-util, headroom-core (path dep), aws-sigv4, aws-config, aws-credential-types, aws-smithy-runtime-api, crc32fast, prometheus (pinned `=0.14.0`), sha2, lru, gcp_auth, async-trait, md-5.
Dev-dependencies: tower (util), wiremock, reqwest (+json), tokio-tungstenite, futures-util, tokio (+test-util, process), hyper (+server), hyper-util, http-body-util, tokio-stream, sha2, proptest, headroom-simulators (path dep).

### headroom-parity

serde, serde_json, anyhow, clap, thiserror, headroom-core (path dep).

### headroom-py

headroom-core (path dep), pyo3, pyo3-log, serde_json.
Build-dependencies: cc.

### headroom-simulators

axum, tokio, clap, serde, serde_json, thiserror, bytes, tracing, tracing-subscriber, http, crc32fast.
Dev-dependencies: reqwest, tower (util), http-body-util.
