# core/ vs harness/

**The test:** would this survive a rewrite in a different language? If yes,
it's `core/`. If it's mechanical — a shell script, a build step, glue that
just needs *a* runtime, any runtime — it's `harness/`.

`core/` holds the reviewer's actual doctrine: the verifier contract, the
label taxonomy, the agent prompts (as sources, composed into `.claude/` by
`harness/build-agents.sh` — Claude Code discovers agents/skills by path
convention, so the sources can't just live where the runtime expects them),
the schemas, the report format. None of it is bash. None of it is
JavaScript. Port the whole reviewer to a different orchestration mechanism
in week 12 and every file in here still describes what the tool should do.

`harness/` holds everything that makes `core/`'s doctrine actually run on
this stack, today: `build-agents.sh` composes the agent sources into
`.claude/agents/`, `build-artifacts.sh` builds the diff/pack artifacts,
`pr-review-verify.js` orchestrates the workflow spawns. Week 12 replaces all
of it. None of it carries doctrine — if a harness file's content changes
what the reviewer decides is a defect, that content belongs in `core/`
instead.

`model/` and `eval/` are neither — `model/` is the domain pack itself
(`pr-review-domain.md` for this repo, `partners/<name>/pr-review-domain.md`
for a foreign one), its format contract (`FORMAT.md`), and its validator
(`validate-pack.sh` + `parse_conventions.py`) — repo-specific data plus the
tool that checks it; `eval/` is the ledger, the regression corpus, and the
baseline measurements. Both survive a rewrite same as `core/`, they're just
not *doctrine* — they're data and evidence, not the rules the doctrine
states.

The two pack-authoring skills (`.claude/skills/generate-domain-pack`,
`.claude/skills/learn`) are harness, not core: they orchestrate reads and a
worktree to *produce* `model/` data, but the rules that make a probe valid
live in `model/FORMAT.md` and the label taxonomy lives in
`core/agents/verify-*.body.md`. A skill that started encoding what counts as
a real convention would be doctrine in the wrong place.
