## Stack scope prefixes

single-stack: backend

## Wiring files

```
headroom/transforms/base.py
headroom/transforms/pipeline.py
headroom/transforms/content_router.py
headroom/transforms/compressor_registry.py
headroom/transforms/content_detector.py
```

## Label probes

Nine records, all `stack: be`. Each cites a correct, base-branch pattern to
compare a diff against — never a defect to hunt.

### logic.compression-never-expands

label:       logic
stack:       be
statement:   After a unit is compressed, its output token count is
             re-measured and compared against the input count; if the
             result is not strictly smaller the compressed output is
             discarded and the original text is kept.
exemplar:    `headroom/transforms/compression_units.py:332`
witnesses:   `headroom/transforms/compression_batches.py:328`
             `headroom/transforms/kompress_compressor.py:1786`
             `headroom/transforms/content_router.py:3561`
guard:       a post-compression recount (`tokenizer.count_text(...)` /
             `payload_tokens(...)`) compared `>= tokens_before` /
             `>= original_tokens`; on no-shrink the code returns with
             `reason="rejected_not_smaller"` or `fallback_no_savings=True`
             and the caller keeps the original content
unsafe_when: the compressed form is adopted from the compressor's own
             self-reported count, or from a stale pre-compression count,
             so appended CCR retrieval markers or JSON re-canonicalisation
             that inflate the payload pass through as "compressed"

### control-flow.compressor-failure-passthrough

label:       control-flow
stack:       be
statement:   A compression step that raises is caught and turned into a
             well-formed passthrough result carrying the untouched input;
             the failure never propagates onto the request path.
exemplar:    `headroom/transforms/compression_batches.py:250`
witnesses:   `headroom/transforms/cold_prefix.py:228`
             `headroom/transforms/content_router.py:5516`
             `headroom/transforms/content_router.py:2825`
guard:       the `except` returns `_passthrough_batch_results(..., reason=
             "batch_router_error")` / `RouterCompressionResult(compressed=
             task_content, strategy_used=PASSTHROUGH)` / the original
             message list — content is the input verbatim and the strategy
             or reason is an explicit passthrough marker; it never re-raises
             and never returns a partial object
unsafe_when: the handler swallows the exception but returns an empty
             string, `None` where a result object is expected, or a
             message list that a partially-completed rewrite already
             mutated before the raise

### control-flow.router-override-restored-in-finally

label:       control-flow
stack:       be
statement:   Code that temporarily overrides the shared router's
             `_runtime_target_ratio` captures the prior value first and
             restores it in a `finally`, so an exception inside
             `router.compress()` cannot leak the temporary ratio to the
             next caller.
exemplar:    `headroom/transforms/compression_batches.py:258`
witnesses:   `headroom/transforms/compression_units.py:280`
             `headroom/transforms/compression_units.py:321`
guard:       `prior_target_ratio = getattr(router, "_runtime_target_ratio",
             None)` before the override, then `finally: router.
             _runtime_target_ratio = prior_target_ratio`
unsafe_when: the restore sits on the normal return path instead of
             `finally`, or the prior value is not captured before the
             override — a raising `router.compress()` then leaves the
             router mutated

### concurrency.shared-state-under-lock

label:       concurrency
stack:       be
statement:   In-process mutable state shared across the parallel
             compression workers (the result/skip cache, circuit-breaker
             counters, metrics counters, the frozen-verdict store) is only
             read or written while holding a dedicated `threading.Lock`,
             and the lock spans the whole read-modify-write.
exemplar:    `headroom/transforms/content_router.py:1279`
witnesses:   `headroom/transforms/content_router.py:1311`
             `headroom/transforms/pipeline.py:207`
             `headroom/transforms/code_compressor.py:156`
guard:       a `self._lock = threading.Lock()` (or module-level
             `threading.Lock()`) acquired with `with ...:` around every
             access; `CompressionCache` deliberately fires its `on_clear`
             callbacks outside the lock to avoid cross-lock ordering
unsafe_when: a new method touches `self._results` / `self._skip` / a
             counter without taking the lock, or releases the lock between
             the read and the dependent write (a check-then-act race that
             loses an update or double-counts a metric)

### logic.lossless-fold-roundtrip-verified

label:       logic
stack:       be
statement:   A lossless compaction fold is only adopted if applying its
             exact inverse to the candidate reproduces the original
             byte-for-byte; on any mismatch the original content is
             returned unchanged.
exemplar:    `headroom/transforms/lossless_compaction.py:525`
witnesses:   `headroom/transforms/lossless_compaction.py:512`
             `headroom/transforms/lossless_compaction.py:533`
             `headroom/transforms/lossless_compaction.py:505`
guard:       each `kind` branch computes `candidate`, then checks
             `inverse(candidate) != content: return content` (and
             `_smaller(...)` before adopting); the whole dispatch is
             wrapped in `except Exception: return content`
unsafe_when: a new fold kind ships without a verifying inverse, or
             verifies against a normalised/stripped baseline that hides a
             real difference from the caller's actual bytes

### logic.protected-placeholders-survive

label:       logic
stack:       be
statement:   Protected-tag placeholder strings must round-trip through a
             compressor exactly once; a section that still carries a
             placeholder is passed through verbatim rather than
             compressed, and a batch whose placeholder count changed is
             rejected to passthrough.
exemplar:    `headroom/transforms/content_router.py:2521`
witnesses:   `headroom/transforms/compression_batches.py:270`
             `headroom/transforms/compression_batches.py:288`
guard:       `if placeholders and any(ph in section.content ...)` skips
             the compressor before the fact; `if any(compressed.count(
             placeholder) != 1 ...)` returns `_passthrough_batch_results(
             reason="batch_invalid")` after it; `restore_tags` itself
             discards a block whose placeholder was rewritten or stripped
unsafe_when: compressed output is spliced back without re-counting the
             placeholders, so a compressor that mangled a `<<...>>`
             marker silently drops the entire protected block

### logic.scores-clamped-to-domain

label:       logic
stack:       be
statement:   A computed confidence / probability / normalised score is
             clamped to its documented domain before it is returned or fed
             downstream, and NaN is guarded explicitly where the value is
             float-derived.
exemplar:    `headroom/transforms/anchor_selector.py:175`
witnesses:   `headroom/transforms/cache_aligner.py:389`
             `headroom/transforms/code_compressor.py:958`
             `headroom/transforms/compression_policy.py:182`
guard:       `min(hi, max(lo, x))` on the final value; `compression_policy`
             additionally special-cases `math.isnan(...)` before the clamp
             because Python `min`/`max` propagate NaN from the first
             argument, unlike the Rust `f32::max` it is a parity port of
unsafe_when: an intermediate weight sum above 1, or a NaN input, flows
             into a ratio or weighting with no clamp, producing an
             out-of-range score a consumer then treats as a probability

### layering.upward-imports-function-local

label:       layering
stack:       be
statement:   Modules in `headroom/transforms/` never import the telemetry
             or proxy layers at module scope; those upward dependencies
             are imported inside the function that needs them.
exemplar:    `headroom/transforms/pipeline.py:165`
witnesses:   `headroom/transforms/content_router.py:2128`
             `headroom/transforms/smart_crusher.py:942`
             `headroom/transforms/kompress_compressor.py:447`
guard:       `from ..telemetry.toin import get_toin` / `from headroom.
             telemetry.session import ...` / `from headroom.proxy.
             interceptors import ...` all sit in function bodies, with a
             comment noting "transforms sits below telemetry in the import
             graph"
unsafe_when: a new module-scope `from headroom.proxy...` or `from
             ..telemetry...` in a transforms file — it creates an import
             cycle and drags telemetry into every transforms import
deviations:  `headroom/transforms/compression_policy.py:25`

### contract.passthrough-signalled-by-flag

label:       contract
stack:       be
statement:   A compressor that did not shrink its input signals that with
             an explicit result flag (`was_modified=False` /
             `strategy=="passthrough"` / `compressed=False`), and every
             consumer gates on that flag rather than string-comparing
             output to input.
exemplar:    `headroom/transforms/smart_crusher.py:512`
witnesses:   `headroom/transforms/config_compressor.py:225`
             `headroom/transforms/smart_crusher.py:869`
guard:       consumers write `if r.was_modified and r.strategy !=
             "passthrough":` before counting savings or splicing; the
             passthrough producers set `strategy=CompressionStrategy.
             PASSTHROUGH.value` / `compressed=False`
unsafe_when: a consumer infers "compressed" from `output != input`, so a
             lossless re-canonicalisation that changed bytes without
             shrinking is miscounted, or an idempotent compressor that
             returned identical bytes is treated as having done nothing

## Promoted non-defects

## Brief probes

```bash
# Deferred to generate-domain-pack — learn authors only the Label probes
# section.
:
```

## Dependencies

Deferred to `generate-domain-pack`.
