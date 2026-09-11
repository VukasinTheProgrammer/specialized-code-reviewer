# Baseline — pre-existing findings, accepted as debt

Created 2026-09-11T09:20:14Z at `70f9f9a3dde71f02ef96aa4e5ec3a8c7ae88da0d`. 3 finding(s).

Suppressed on every run after this one, matched by `file:line:label` — see `model/baseline.py`'s own docstring for what a fingerprint match does and doesn't survive.

## concurrency

- `headroom/transforms/content_router.py:4822` — Two concurrent proxy requests sharing the same process-wide ContentRouter instance call apply() with different target_ratio values; the second call's write to self._runtime_target_ratio overwrites the first while the first's per-block compression (dispatched via ThreadPoolExecutor) is still reading it, so a block from request A is compressed using request B's target ratio.

## dead-code

- `headroom/transforms/read_lifecycle.py:58` — FileOperation.content_size is never populated when FileOperation instances are constructed, so ReadClassification.content_size (documented as the real tool_result content size) is always 0 for every classified Read.

## duplication

- `headroom/transforms/read_maturation.py:65` — read_maturation.py independently defines _READ_TOOLS = frozenset({'Read','read'}) instead of importing the existing canonical _READ_TOOL_NAMES from headroom/config.py that read_lifecycle.py (the sibling module sharing 'the same recovery contract') already imports for the identical check; a future addition to config._READ_TOOL_NAMES is picked up by read_lifecycle but silently missed by read_maturation, causing the two mechanisms to disagree on which tool calls count as a Read.
