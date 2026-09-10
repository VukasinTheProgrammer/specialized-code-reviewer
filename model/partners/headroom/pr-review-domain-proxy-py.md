## Stack scope prefixes

Single-stack scope — `headroom/proxy/` is Python. No per-stack prefix split needed.

## Wiring files

```
headroom/proxy/server.py
headroom/proxy/helpers.py
headroom/proxy/model_router.py
headroom/proxy/models.py
```

## Label probes

### security.loopback-dns-rebind-guard

label:        security
statement:    A loopback-only debug endpoint is gated behind a dependency that checks both the socket peer IP and the inbound `Host:` header before answering, so DNS-rebinding cannot reach it even though the raw peer IP is loopback.
exemplar:     `headroom/proxy/loopback_guard.py:173-216`
witnesses:    `headroom/proxy/server.py:3810`
              `headroom/proxy/server.py:3825`
guard:        `require_loopback` (`headroom/proxy/loopback_guard.py:199-216`) checks `request.client.host` via `is_loopback_host` AND separately checks the `Host:` header via `is_loopback_host_header` — either failing returns 404, not 403, so the endpoint is invisible rather than merely forbidden.
unsafe_when:  A route only checks `request.client.host` (or only checks CORS) without also validating the `Host:` header — a DNS-rebinding page can then get a browser sitting on loopback to send a request whose `Host:` still names the attacker's origin.

### security.same-origin-on-mutating-admin-route

label:        security
statement:    A mutating admin route rejects a cross-origin browser request even when the socket and `Host:` header both look local, by validating that the `Origin` header (when present) itself names a loopback host.
exemplar:     `headroom/proxy/loopback_guard.py:219-248`
witnesses:    `headroom/proxy/server.py:3845-3847`
guard:        `require_same_origin` (`headroom/proxy/loopback_guard.py:244-248`) rejects when `Origin` is the opaque literal `"null"` or does not itself resolve to a loopback host via `is_loopback_host_header`; requests with no `Origin` (curl, CLI) pass through since a real cross-origin browser fetch always sets one.
unsafe_when:  A mutating endpoint is guarded only by `require_loopback` (Host-header check) without `require_same_origin` — a remote page's JS can still POST directly to `http://127.0.0.1:<port>` with a simple (non-preflighted) request; the `Host:` header still reads loopback so that gate alone doesn't stop it.
human_approved: true

### security.trust-forwarded-headers-only-from-allowlisted-gateway

label:        security
statement:    Trusting a caller's `X-Forwarded-For` value requires first proving the direct TCP peer is an operator-allowlisted gateway CIDR; an untrusted peer's forwarded headers are dropped rather than believed.
exemplar:     `headroom/proxy/forwarded_policy.py:60-77`
witnesses:    `headroom/proxy/server.py:2564`
              `headroom/proxy/forwarded_headers.py:230`
guard:        `resolve_forwarded_headers` (`headroom/proxy/forwarded_policy.py:88-112`) only reads `forwarded_for`/`forwarded_proto`/`forwarded_host` when `peer_is_trusted_gateway(inputs.peer_host, cidrs)` is true; otherwise it returns the raw peer IP and flags `rejected=True` if forwarded headers were present anyway.
unsafe_when:  Code reads `X-Forwarded-For` (for rate limiting, audit logs, or IP allowlisting) directly off any request without first checking the immediate peer against a trusted-proxy CIDR list — any client can then spoof its own IP.

### security.bounded-incremental-decompression

label:        security
statement:    Decompressing a client-supplied request body happens incrementally, checking cumulative output size against a cap after every chunk, so a high-ratio compression bomb is aborted before it can exhaust memory.
exemplar:     `headroom/proxy/helpers.py:2588-2646`
witnesses:    `headroom/proxy/helpers.py:2649-2666`
guard:        Each codec-specific function feeds input through an incremental/streaming decompressor (`zlib.decompressobj`, `zstandard.stream_reader`) in bounded chunks and raises `RequestBodyTooLarge` the moment accumulated output exceeds `MAX_DECOMPRESSED_BODY_SIZE`, rather than calling the one-shot `decompress()` that must fully materialize output first.
unsafe_when:  A new codec is added using the library's one-shot `decompress(raw)` call instead of the incremental/streaming API — the cap check then runs only after the full (potentially gigabytes) output already exists in memory, defeating the guard entirely.
human_approved: true

### auth.case-fold-scheme-not-credential

label:        auth
statement:    Classifying a request's auth mode from its `Authorization` header case-folds only the RFC-7235 scheme token (`Bearer`) before comparing, while leaving the credential itself case-sensitive.
exemplar:     `headroom/proxy/auth_policy.py:66-96`
witnesses:    `headroom/proxy/handlers/anthropic.py:917`
              `headroom/proxy/handlers/openai.py:3289`
guard:        `scheme, sep, credentials = auth.partition(" ")` then `if sep and scheme.lower() == "bearer":` — only `scheme` is lowercased before comparison; `credentials` (the actual key/token) is passed through untouched to the `startswith("sk-ant-oat")` etc. checks.
unsafe_when:  The whole `Authorization` value (or the token) is lowercased before matching — `Bearer sk-ant-OAT...`-style credentials would then fail the `sk-ant-oat` prefix check, or a case-sensitive secret comparison elsewhere would silently accept a differently-cased forgery.

### concurrency.lock-guards-every-touch-of-shared-state

label:        concurrency
statement:    Mutable shared state (per-key rate-limit buckets, an LRU cache dict) is only ever read or written while holding the object's own `asyncio.Lock`, across every method that touches it.
exemplar:     `headroom/proxy/rate_limiter.py:24-97`
witnesses:    `headroom/proxy/semantic_cache.py:25-92`
guard:        `TokenBucketRateLimiter.__init__` creates `self._lock = asyncio.Lock()`; `check_request`, `check_tokens`, and `stats` each wrap their entire dict read-refill-write sequence in `async with self._lock:` so a concurrent request awaiting the same coroutine cannot interleave a stale refill calculation.
unsafe_when:  A new method reads or mutates `self._request_buckets`/`self._token_buckets` (or adds a new bucket dict) without acquiring `self._lock` first — under `asyncio`, an `await` inside the unlocked section lets another coroutine interleave and corrupt the refill/consume arithmetic or double-count tokens.
human_approved: true

### concurrency.lazy-singleton-check-and-create-under-one-lock

label:        concurrency
statement:    A process-wide lazily-constructed singleton (worker pool, session tracker) is created inside a lock, with the null-check and the assignment both happening under the same lock acquisition.
exemplar:     `headroom/proxy/image_isolation.py:100-108`
witnesses:    `headroom/proxy/helpers.py:2072-2083`
guard:        `with _IMAGE_POOL_LOCK: if _IMAGE_POOL is None: _IMAGE_POOL = ProcessPoolExecutor(...)` — the check-then-create is atomic under the lock, so two threads racing to first-use the pool cannot both construct (and leak) a `ProcessPoolExecutor`.
unsafe_when:  The `is None` check and the construction happen outside the lock (or in separate `with` blocks) — two threads can both observe `None`, both construct a pool/tracker, and the second assignment silently discards (and leaks the resources of) the first.
human_approved: true

### validation.reject-unknown-config-keys

label:        validation
statement:    Parsing an operator-supplied JSON config object rejects any key it doesn't recognize, rather than silently ignoring it, so a typo'd field name can't widen a rule beyond what the operator intended.
exemplar:     `headroom/proxy/model_router.py:230-247`
witnesses:    `headroom/proxy/model_router.py:230-247`
guard:        `unknown_keys = set(entry) - _ALLOWED_ROUTE_KEYS`; `if unknown_keys: ... skip route` — a misspelled condition like `max_input_token` (missing the `s`) is treated as an unrecognized key and the whole rule is dropped with a warning, rather than the misspelled cap being silently absent (which would leave the rule unbounded).
unsafe_when:  Unknown/extra keys on a config object are ignored (`entry.get(key, default)` for every known key, with no check on the full key set) — a typo'd or renamed field then silently reverts to its default instead of erroring, changing behavior without any signal.
human_approved: true

### validation.reject-bool-as-int

label:        validation
statement:    Parsing an integer field from untrusted JSON explicitly rejects a `bool` value even though `bool` is a subclass of `int` in Python, so `true`/`false` can't silently pass as `1`/`0`.
exemplar:     `headroom/proxy/model_router.py:290-313`
witnesses:    `headroom/proxy/model_router.py:290-313`
guard:        `if isinstance(value, bool): logger.warning(...); return _INVALID` runs before the `isinstance(value, int)` branch — since `isinstance(True, int)` is `True` in Python, this explicit bool check must come first or a JSON `true` for `max_input_tokens` would silently become `1`.
unsafe_when:  The bool check is omitted (or placed after the generic `isinstance(value, int)` check) — a config value of `true`/`false` for a numeric field then parses as `1`/`0` instead of being rejected, which for `max_input_tokens` would drastically (and silently) narrow or misconfigure the rule's match range.
human_approved: true

### validation.invariant-checked-in-post-init

label:        validation
statement:    A config dataclass validates its own invariants in `__post_init__` and raises immediately at construction time, so a bad value fails at startup/config-load rather than crashing (or misbehaving) later on the request path.
exemplar:     `headroom/proxy/models.py:548-568`
witnesses:    `headroom/proxy/route_advice.py:58-60`
guard:        `if self.rate_limit_enabled and self.rate_limit_requests_per_minute < 1: raise ValueError(...)` — guards a real downstream divide-by-zero in `rate_limit_policy.consume_from_bucket`; failing here means every construction path (CLI, JSON config, programmatic) gets the same protection instead of only the CLI's separate `IntRange(min=1)`.
unsafe_when:  The invariant is only checked in one construction path (e.g. the CLI arg parser) and not in the dataclass itself — a programmatic or JSON-file config bypasses that check and reaches the request path with an invalid value, crashing (or worse, misbehaving) on the first real request instead of at startup.
human_approved: true


### contract.case-insensitive-dedup-preserving-original-casing

label:        contract
statement:    Merging Headroom-required protocol tokens into a client-supplied beta-feature header preserves the client's original tokens and casing, de-duplicates case-insensitively, and always appends whichever required tokens aren't already present — so the outgoing header always satisfies both the client's request and Headroom's own upstream feature requirements.
exemplar:     `headroom/proxy/beta_header_merge.py:19-41`
witnesses:    `headroom/proxy/handlers/anthropic.py:2776`
              `headroom/proxy/handlers/openai.py:6967`
guard:        `seen_lower` (a case-folded set) is built from the client's tokens first, in order, preserving their original casing in `out`; the required-tokens loop then only appends a required token if its lowercase form isn't already in `seen_lower`, so appending never duplicates and never overwrites the client's original casing.
unsafe_when:  The merge does a naive string concatenation (`f"{client_value},{required}"`) or a case-sensitive dedup — a client that already sent the required token in different casing (or reordered) then gets a duplicated/conflicting header sent upstream, which for some providers changes behavior or is rejected.

### state.idempotent-deregister

label:        state
statement:    Deregistering a session from an in-memory registry is idempotent (a no-op returning `None`/`(None, 0)` for an unknown id), and the handle pop and its released-task count are read together in one internal method so they can never drift.
exemplar:     `headroom/proxy/ws_session_registry.py:139-181`
witnesses:    `headroom/proxy/handlers/openai.py:9279-9287`
guard:        `_deregister_internal` does `handle = self._sessions.pop(session_id, None); if handle is None: return None, 0` as a single atomic step, and both public methods (`deregister`, `deregister_and_count`) delegate to it — a caller that needs the released-task count can't observe a state where the pop happened but the count reflects a different (already-mutated) handle.
unsafe_when:  A caller captures `len(handle.relay_tasks)` in one step and then calls `deregister(session_id)` in a separate step — if the registry's task-tracking bookkeeping changes in the future, the two reads can drift and the caller decrements a Prometheus gauge by the wrong amount, or a not-yet-registered/already-deregistered session raises instead of no-op'ing.
human_approved: true

### control-flow.normalize-to-closed-set-never-raise

label:        control-flow
statement:    Normalizing a user-provided config enum value never raises and never returns an unrecognized value — an empty, unknown, or aliased input all resolve to one of a small closed set of canonical values, with an unknown input logged rather than silently accepted.
exemplar:     `headroom/proxy/proxy_mode_policy.py:33-55`
witnesses:    `headroom/proxy/server.py:840`
              `headroom/proxy/handlers/anthropic.py:1601`
guard:        Every branch of `normalize_proxy_mode_decision` (empty key, unknown key, known alias, canonical key) returns a `ProxyModeDecision` with `normalized` set to either the resolved canonical mode or `default` — there is no branch that returns the raw, unvalidated input or raises, so every caller downstream can trust `mode` is always one of exactly the closed set.
unsafe_when:  A new mode value is added to the alias table on only one side (e.g. the string constant but not wired into `is_token_mode`/`is_cache_mode`'s exhaustive checks) — since callers gate behavior with parallel booleans rather than an exhaustive match, a third mode value would silently fail both checks instead of erroring.

### control-flow.buffer-drain-leaves-partial-event-intact

label:        control-flow
statement:    Draining complete Server-Sent-Events out of a byte buffer mutates the buffer in place, consuming only complete events and leaving any trailing partial event intact for the next network chunk to complete.
exemplar:     `headroom/proxy/sse_byte_buffer_policy.py:25-60`
witnesses:    `headroom/proxy/handlers/streaming.py:188-192`
              `headroom/proxy/handlers/streaming.py:278-288`
guard:        The drain loop only proceeds when a complete `\n\n`/`\r\n\r\n` terminator is found; `del buf[: idx + terminator_len]` removes exactly the consumed complete event, so bytes after the last terminator (a partial event still arriving) are never touched and remain for the next call.
unsafe_when:  The buffer is split on a fixed-size chunk boundary (or decoded as UTF-8 before a terminator is found) instead of buffering until a complete terminator appears — a multi-byte UTF-8 character or an `event:`/`data:` line split across two TCP reads then corrupts or drops that event.

### duplication.header-strip-list-lives-in-one-function

label:        duplication
statement:    Header-stripping logic that must stay in sync with a specific list of wire-framing headers lives in exactly one function, and a second module that could plausibly reimplement a subset of it instead documents why it defers to the existing one.
exemplar:     `headroom/proxy/helpers.py:338-351`
witnesses:    `headroom/proxy/handlers/anthropic.py:296`
              `headroom/proxy/handlers/openai.py:3617`
              `headroom/proxy/handlers/openai.py:5340`
guard:        `nonstream_sse_policy.py` explicitly documents the non-duplication decision: header correction deliberately lives in `helpers.sanitize_forwarded_response_headers` rather than being reimplemented — a real prior incident (a stale `transfer-encoding` header producing an empty HTTP 200) is cited as the cost of drift.
unsafe_when:  A new response-handling module reimplements its own header-stripping list instead of calling `sanitize_forwarded_response_headers` — the two lists can silently diverge, and a header that matters (like `transfer-encoding`) can be missed in the copy.

### logic.single-factory-for-a-shared-gate

label:        logic
statement:    A yes/no gate that several handlers must compute identically (e.g. "should this request be compressed?") is a single named factory method producing an immutable, fully-observable decision value, called by every handler that needs the gate — not an inline boolean expression repeated at each call site.
exemplar:     `headroom/proxy/compression_decision.py:71-147`
witnesses:    `headroom/proxy/handlers/gemini.py:528`
              `headroom/proxy/handlers/anthropic.py:1703`
              `headroom/proxy/handlers/openai.py:3773`
guard:        The module docstring documents the actual bug this fixed: before the factory existed, four handler files computed the same conjunction inline at five different sites with subtle drift — three Gemini call sites were missing a bypass check entirely, silently ignoring the user's explicit bypass header. `decide()` now computes the ordered precedence once, and the frozen-dataclass return value structurally prevents a caller from partially overriding it.
unsafe_when:  A new handler path (or a new provider integration) computes its own inline conjunction instead of calling `CompressionDecision.decide(...)` — any of the precedence checks can be dropped or reordered without anyone noticing, reproducing the exact class of bug this factory was built to eliminate.

### layering.stateful-wrapper-delegates-to-pure-policy-module

label:        layering
statement:    A stateful, I/O- or lock-holding wrapper class delegates every actual decision computation to a "pure" sibling module (no I/O, no global state, unit-testable in isolation) — the wrapper only owns the mutable bookkeeping (dict/lock/timers) and calls into the pure module for the arithmetic.
exemplar:     `headroom/proxy/rate_limiter.py:1-16`
witnesses:    `headroom/proxy/rate_limit_policy.py:1-41`
              `headroom/proxy/memory_decision.py:36-39`
guard:        `rate_limit_policy.py`'s module docstring is literally "Pure token-bucket rate-limit policy helpers" — every function in it takes only plain values/dicts and returns plain values, no `self`, no lock, no `asyncio`. `rate_limiter.py`'s `TokenBucketRateLimiter` holds the `asyncio.Lock` and the state dict, and calls into the pure functions only after acquiring the lock.
unsafe_when:  New business logic (a new eligibility rule, a new threshold) is added directly inside the stateful wrapper class instead of the paired `*_policy.py` module — it then can't be unit-tested without standing up the lock/dict machinery, and a second stateful caller that needs the same rule is more likely to reimplement it inline than import the pure function.

### dead-code.marked-compatibility-reexport

label:        dead-code
statement:    A symbol that looks unused within the file that imports it (because it exists purely to preserve an external module's public API after an internal reorganization) is marked with an explicit compatibility-export comment and grouped under a clear section header, distinguishing it from an accidental orphaned import.
exemplar:     `headroom/proxy/helpers.py:55-68`
witnesses:    `headroom/proxy/server.py:120-148`
guard:        Each import is written as `X as X  # noqa: F401 - compatibility export` — the redundant `as X` combined with the comment makes the intent machine-checkable (a linter won't flag it) and human-legible (a reviewer sees why it's kept) in the same line, rather than a bare unadorned import a linter or a future cleanup pass would flag and delete.
unsafe_when:  An import that's actually part of an external-facing compatibility surface has no marking as intentional — a lint-driven or LLM-assisted "remove unused imports" cleanup then deletes it, breaking any external caller that still imports the symbol from its old location.
human_approved: true

## Promoted non-defects

(none — no ledger history exists yet for this repo/scope)

## Brief probes

```bash
# Router registration touch: new/changed FastAPI route wiring.
grep -nE '@app\.(get|post|put|delete|patch)\(|Depends\(' -- "$@" 2>/dev/null

# Money/amount-adjacent: token/cost counters, the closest cost-bearing surface here.
grep -nE 'max_input_tokens|max_output_tokens|cost_usd|rate_limit|token_savings' -- "$@" 2>/dev/null

# Migration path: none known in this scope (no SQL/schema code under headroom/proxy/).
grep -nE 'ALTER TABLE|CREATE TABLE|migrate_legacy' -- "$@" 2>/dev/null

# Lockfile/deps touch.
grep -nE '^\[dependencies\]|^\[project\.dependencies\]' -- "$@" 2>/dev/null
```

## Dependencies

### headroom-proxy (Python)

fastapi, uvicorn, httpx, asyncio (stdlib), zlib/zstandard/brotli (decompression codecs), ipaddress (stdlib, CIDR matching).
