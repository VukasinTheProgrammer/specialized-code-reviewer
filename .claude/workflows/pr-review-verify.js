// @ts-nocheck — this file's top-level `await`/`return` are valid only inside
// the Workflow tool's runtime (it wraps the script body in an async
// function); a standalone JS/TS checker flags them as errors outside one.
export const meta = {
  name: 'pr-review-verify',
  description: 'Scout maps the diff and hands ranked hypotheses to 4 slice verifiers, run in parallel and merged',
  phases: [{ title: 'Scout' }, { title: 'Verify' }],
}

// Everything git/bash (diff, manifest, scope, brief) is built by the caller
// before this runs — workflow scripts have no filesystem access. This script
// only orchestrates the agent fan-out: one scout, four Read/Grep/Glob verifiers,
// then a deterministic merge/sort. See .claude/skills/pr-review/SKILL.md.

const SCOUT_SCHEMA = {
  type: 'object',
  properties: {
    graph: { type: 'string', enum: ['on', 'off'] },
    context: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          kind: { type: 'string' },
          related: { type: 'array', items: { type: 'string' } },
          graph_coverage: { type: 'string', enum: ['hit', 'none'] },
          classification: { type: 'string', enum: ['governed', 'new'] },
          matched_convention: { type: ['string', 'null'] },
          match_strength: { type: ['string', 'null'], enum: ['strong', 'weak', null] },
        },
        required: ['file', 'kind', 'related', 'graph_coverage', 'classification', 'matched_convention', 'match_strength'],
      },
    },
    hypotheses: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          label: { type: 'string' },
          one_line: { type: 'string' },
          related: { type: 'array', items: { type: 'string' } },
          rank: { type: 'number' },
        },
        required: ['file', 'label', 'one_line', 'related', 'rank'],
      },
    },
    impacted: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          calls: { type: 'string' },
          graph_coverage: { type: 'string', enum: ['hit', 'none'] },
        },
        required: ['file', 'calls', 'graph_coverage'],
      },
    },
  },
  required: ['graph', 'context', 'hypotheses', 'impacted'],
}

const VERIFIER_SCHEMA = {
  type: 'object',
  properties: {
    slice: { type: 'array', items: { type: 'string' } },
    hypotheses_received: { type: 'number' },
    hypotheses_unread: { type: 'number' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          line: { type: 'number' },
          label: { type: 'string' },
          source: { type: 'string', enum: ['sweep', 'hypothesis'] },
          failure_mode: { type: 'string' },
          // minItems mirrors the low end of core/doctrine.md's bar ("two to
          // five ordered file:line steps") — evidence was previously not
          // required at all, so a finding could clear this schema with the
          // four other fields but no trace (explain-bug/SKILL.md already
          // defends against exactly that gap, confirming it was real).
          // No maxItems: doctrine states "two to five" as guidance on a
          // typical trace, not a hard ceiling — capping it would let one
          // finding needing a genuinely longer chain fail the whole slice's
          // structured-output call (coarser than the old per-finding drop
          // this schema is meant to tighten, not worsen).
          evidence: { type: 'array', items: { type: 'string' }, minItems: 2 },
          // Week 7: which convention record this finding deviates from —
          // optional, present only for a finding proven against a governed
          // unit (core/doctrine.md's "Governed units" section). Never part
          // of the dedupe key below: two findings at the same file, line
          // and label are the same finding whether or not one cites a record.
          deviates_from: { type: 'string' },
        },
        required: ['file', 'line', 'label', 'failure_mode', 'evidence'],
      },
    },
    dropped_unreachable: { type: 'number' },
  },
  required: ['slice', 'hypotheses_received', 'hypotheses_unread', 'findings', 'dropped_unreachable'],
}

// `labels` is slice membership (pipeline-internals.md §"Slices"); `reportOrder`
// is §5.3's "table order" for sorting findings within a slice, given only where
// the two differ — which is Structure alone (pipeline-internals.md:50 vs :156).
// That divergence is preserved, not resolved: changing it renumbers every
// Structure finding in every report, which is a behavior change, not a cleanup.
const SLICES = [
  { name: 'Access', agentType: 'pr-verify-access', labels: ['auth', 'ownership', 'security', 'data-exposure'] },
  { name: 'Data', agentType: 'pr-verify-data', labels: ['db', 'concurrency'] },
  { name: 'Answer', agentType: 'pr-verify-answer', labels: ['logic', 'validation', 'control-flow', 'state', 'contract'] },
  { name: 'Structure', agentType: 'pr-verify-structure', labels: ['duplication', 'dead-code', 'layering', 'a11y'], reportOrder: ['layering', 'duplication', 'dead-code', 'a11y'] },
]

// Derived, never hand-typed a second time — the sort table and the membership
// table used to be two independent literals of the same 15 labels, with no way
// to tell Structure's different order from a typo that had drifted. A label
// missing from its slice's reportOrder would sit at indexOf === -1 and sort
// ahead of everything, so the permutation is checked once here rather than
// silently scrambling §5.3's numbering.
const LABEL_ORDER = {}
for (const s of SLICES) {
  LABEL_ORDER[s.name] = s.reportOrder || s.labels
  const missing = s.labels.filter((l) => !LABEL_ORDER[s.name].includes(l))
  if (missing.length) log(`Warning: ${s.name} reportOrder omits ${missing.join(', ')} — those labels sort ahead of the slice instead of in table order.`)
}

const SLICE_ORDER = ['Access', 'Data', 'Answer', 'Structure']

const {
  outDir, repoRoot, base, head, scope, be, fe, graph,
  briefText, wiringFilesText,
  probesAccessText, probesDataText, probesAnswerText, probesStructureText,
  probesAllText, knownNonDefectsText, impactedCandidatesText,
  candidatesText, recordsText,
} = args

const patchPath = `${outDir}/patch.diff`
const manifestPath = `${outDir}/manifest.txt`

// Pre-split by build-artifacts.sh so no verifier spawn has to open the
// domain pack itself to find its own rows — same content, delivered once.
const PROBES_TEXT = {
  Access: probesAccessText, Data: probesDataText,
  Answer: probesAnswerText, Structure: probesStructureText,
}

const labelToSlice = {}
for (const s of SLICES) for (const l of s.labels) labelToSlice[l] = s.name
// Labels a stack can't own: ownership/db need BE, state/a11y need FE.
const STACK_GATE = { ownership: 'be', db: 'be', state: 'fe', a11y: 'fe' }
// be/fe arrive from an LLM orchestrator following prose instructions (SKILL.md),
// not type-checked code — Number(...) coerces "1"/1/true alike so a stringified
// flag doesn't silently fail a strict === comparison (this exact bug shipped once).
const flags = { be: Number(be) === 1, fe: Number(fe) === 1 }

phase('Scout')
const graphSection = graph === 'on'
  ? `\ngraph: on — graphify MCP tools (get_node/get_neighbors/query_graph/shortest_path) are live; call them yourself per your agent definition.\n`
  : ''
// Pre-extracted by build-artifacts.sh so the scout doesn't Read the domain
// pack or the ledger itself — same content, delivered once, same reasoning
// as PROBES_TEXT above but the union (scout has no slice) instead of a split.
const domainPackProbes = probesAllText
  ? `\ndomain pack — this repo's own cited probes for every label (no need to\nopen the pack file yourself, this is already its whole '## Label probes'\ntable):\n\n${probesAllText}\n`
  : '\nNo domain pack this run — use the fallback Probes column in your own agent definition.\n'
const knownNonDefects = knownNonDefectsText
  ? `\nKnown non-defects — patterns a human has already ruled out here, each with\nthe guard that makes it safe (the ledger's own current text, no need to\nopen it yourself). Not a real hypothesis if it matches one of these:\n\n${knownNonDefectsText}\n`
  : ''
// Same source text, verifier-scoped wording — this was missing entirely
// until a regression-set replay caught it: a dismissed pattern only ever
// reached the scout's hypothesis-filtering ("not a real hypothesis"), never
// a verifier's own prompt, so a pattern the scout correctly declined to
// raise could still be independently rediscovered and reported by a
// verifier's own cold sweep (job 1) or while settling a hypothesis (job 2)
// — the ledger's whole enforcement mechanism was silently half-wired.
const knownNonDefectsForVerifier = knownNonDefectsText
  ? `\nKnown non-defects — patterns a human has already ruled out here, each with\nthe guard that makes it safe (the ledger's own current text, no need to\nopen it yourself). Not a real finding — on your own sweep (job 1) or while\nsettling a hypothesis (job 2) — if it matches one of these:\n\n${knownNonDefectsText}\n`
  : ''
// Deterministic candidate list from build-artifacts.sh (§1.9) — unchanged files
// that reference something this diff changed, resolved by word-boundary grep at
// HEAD. Graph-independent on purpose: `impacted` used to be empty on every
// graph-off run, which is every repo without a graphify index. Candidates, not
// answers — the scout confirms each against the file and drops what doesn't hold.
const impactedCandidates = impactedCandidatesText
  ? `\nimpacted candidates — unchanged files that reference something this diff\nchanged, one \`caller<TAB>changed-file\` per line, already capped and with the\ndiff's own files removed. A reference is not a call: confirm each one before\nkeeping it, and drop the rest. With graph on, your own edge lookups take\nprecedence over this list where the two disagree.\n\n${impactedCandidatesText}\n`
  : '\nNo impacted candidates this run — nothing unchanged references the changed files, or the diff touches only files with no referencable name.\n'

// Week 6 deterministic pre-pass (model/parse_conventions.py's `match` mode,
// run by build-artifacts.sh): every record scored per changed file on four
// structural signals derived from its own exemplar/witnesses/guard
// (model/FORMAT.md §3c) — no author-set field. A score >= 3 is a candidate,
// never a verdict — restrict `classification`/`matched_convention` to what
// this list actually proposes (plus the narrow scout-names-a-miss
// exception below); confirm (`governed`) or reject it back to `new`.
const candidates = candidatesText
  ? `\ncandidates — the deterministic matcher's own ranked proposals, one\n\`file<TAB>id:score<TAB>id:score...\` line per changed file (\`(none)\` when\nnothing reached the threshold). This is a structural signal that never\nopened the file: a directory/filename/symbol/token match, not a semantic\none. Either signal may veto; only agreement may assert:\n- a listed candidate you confirm against the actual code -> governed, strong\n- a listed candidate the code doesn't actually support -> reject it, new\n- nothing listed here, but you recognize a record that genuinely governs this file -> governed, weak, and you must say in one line why\n- more than one candidate still looks applicable after checking, or you can't cleanly settle on one -> new (disagreement, not a guess)\n- nothing listed and you see no record either -> new\n\n${candidatesText}\n`
  : '\nNo candidates this run — no record scored >= 3 against any changed file, or no domain pack. Everything is `new` unless you can confidently name and justify a record yourself (governed, weak).\n'

const scoutPrompt = `graph: ${graph}

diff:      ${patchPath}
manifest:  ${manifestPath}
scope:     ${scope}

repository root: ${repoRoot}
Every path in your reply must be relative to that root.

${briefText}
${graphSection}
${domainPackProbes}
${knownNonDefects}${impactedCandidates}${candidates}
Read the patch and the manifest, then emit context (every changed unit),
optionally up to 12 ranked hypotheses, and optionally up to 12 impacted
callers. See your own agent definition for the label table, the reading
rules and the exact contract for all three arrays.`

// A scout crash/timeout/schema-drift must not abort the whole run: every
// verifier's job 1 (its own sweep for its own labels) does not depend on the
// scout at all (SKILL.md §3.4), so degrade to "scout found nothing" instead
// of throwing — the run proceeds with no head start and no hypotheses,
// which costs coverage the scout would have added, never review that ran.
let scout
let scoutFailed = false
try {
  scout = await agent(scoutPrompt, {
    agentType: 'pr-review-scout',
    schema: SCOUT_SCHEMA,
    phase: 'Scout',
  })
} catch {
  scout = { graph, context: [], hypotheses: [], impacted: [] }
  scoutFailed = true
  log('Scout spawn failed — proceeding with no context, hypotheses or impacted callers; each verifier still runs its own job 1 sweep.')
}

let droppedHypotheses = 0
const bucket = { Access: [], Data: [], Answer: [], Structure: [] }
for (const h of scout.hypotheses || []) {
  const sliceName = labelToSlice[h.label]
  const gate = STACK_GATE[h.label]
  const stackOk = !gate || flags[gate]
  if (!sliceName || !stackOk) {
    droppedHypotheses++
    continue
  }
  bucket[sliceName].push(h)
}
for (const k of Object.keys(bucket)) bucket[k].sort((a, b) => a.rank - b.rank)

// `graph_coverage` is stripped here rather than shipped four times over: it
// records which tool resolved `related` (graph hit vs. Grep fallback), which
// is a fact a report reader wants and a spawn proving a trace has no use for
// — no pr-verify-* definition reads it. scoutGraphCoverage below is tallied
// from scout.context itself, not from this text, so the telemetry survives.
// `classification`/`matched_convention`/`match_strength` are stripped the
// same way — no verifier reads a bare classification string, it reads the
// actual record (below) once routed to it.
const contextText = JSON.stringify((scout.context || []).map(({ file, kind, related }) => ({ file, kind, related })))
const impactedText = JSON.stringify((scout.impacted || []).map(({ file, calls }) => ({ file, calls })))

// Week 7: route a governed·strong unit's own record to exactly the verifier
// that owns its label — reusing labelToSlice (built above from the same
// SLICES table hypotheses route through), not a second table to drift from
// it. `weak` is routed nowhere this week (todays-work/week7/monday.md's own
// decision, strong only — a weak match is the scout asserting alone, the
// case with the least evidence, and widening is week 8's call to make on
// real precision numbers, not a guess made here).
let recordsById = {}
try {
  for (const r of JSON.parse(recordsText || '[]')) recordsById[r.id] = r
} catch {
  recordsById = {}
}

function stackAllowsRecord(record) {
  // Same rule as model/parse_conventions.py's stack_allows() and the
  // hypothesis STACK_GATE above — a record's own `stack` is a veto, not a
  // score, and this is the one place in this script that has to reproduce
  // that rule for a record instead of a label (a record's stack can differ
  // from its label's — `logic` itself isn't stack-restricted, one of its
  // records still can be).
  if (record.stack === 'be') return flags.be
  if (record.stack === 'fe') return flags.fe
  return true
}

function governedBlock(file, record) {
  // record.id is already the full `label.short-name` slug (model/FORMAT.md
  // §3's own id grammar) — not "label" + "." + "id" again.
  return `${file}\n  governed by ${record.id}\n  correct      ${record.exemplar}\n  guard        ${record.guard}\n  unsafe when  ${record.unsafe_when}`
}

const governedBySlice = { Access: [], Data: [], Answer: [], Structure: [] }
let droppedGoverned = 0
for (const c of scout.context || []) {
  if (c.classification !== 'governed' || c.match_strength !== 'strong' || !c.matched_convention) continue
  const record = recordsById[c.matched_convention]
  const sliceName = record && labelToSlice[record.label]
  if (!record || !sliceName || !stackAllowsRecord(record)) {
    droppedGoverned++
    continue
  }
  governedBySlice[sliceName].push(governedBlock(c.file, record))
}
if (droppedGoverned > 0) log(`${droppedGoverned} governed unit(s) dropped before reaching a verifier — matched record not found in this run's pack, label outside every slice, or outside this repo's stack scope`)

const governedText = {}
for (const s of SLICES) {
  governedText[s.name] = governedBySlice[s.name].length
    ? `\ngoverned units in this diff — a domain-pack record already matched to these\nfiles by the scout and a deterministic matcher (strong match only). This is\nadditional ground, not a replacement for your labels' probes above; see your\nown agent definition's "Governed units" section for the bar a finding here\nstill has to clear.\n\n${governedBySlice[s.name].join('\n\n')}\n`
    : ''
}

function verifierPrompt(hyps, probesText, governed) {
  const hypText = hyps.length
    ? hyps.map((h, i) => `  ${i + 1}. ${h.file} — ${h.label} — ${h.one_line}   rank ${h.rank}\n     related: ${(h.related || []).join(', ') || '(none)'}`).join('\n')
    : '(none — job 1 is the whole job)'
  const wiring = wiringFilesText
    ? `\nReadable without stating a reason, in addition to your standing free list:\n\n${wiringFilesText}\n`
    : ''
  const probes = probesText
    ? `\ndomain pack — this repo's own cited probes for your labels (use these before\nyour fallback prose; no need to open the pack file yourself, this is already\nevery row that applies to you):\n\n${probesText}\n`
    : '\nNo domain pack for your labels this run — use your own fallback prose.\n'
  return `Review this diff for your slice (job 1), then settle the hypotheses
below (job 2) — see your own agent definition for the two-job order, the
five-field bar and the monotonic-findings rule; this prompt carries only this
run's values, not the doctrine you already have.

hypotheses:
${hypText}

context (from the scout, every changed unit in this diff — pick out what is
relevant to your own labels; the rest belongs to another slice):
${contextText}

impacted (from the scout, unchanged files that call into something this diff
changed — this diff's own lines don't cover them, so check whether the
change broke one of them under whichever of your own labels the breakage
would show up as; empty is normal, not a gap):
${impactedText}
${probes}${governed || ''}${knownNonDefectsForVerifier}
diff:      ${patchPath}
manifest:  ${manifestPath}

repository root: ${repoRoot}
Every path in the hypotheses and the diff is relative to that root. Reading
the same path under any other root gives you a different version of the file
and line numbers that do not match.

${briefText}
${wiring}`
}

// One spawn per slice. The merge below is written per-slice rather than per
// spawn, so it stays correct if a slice ever runs more than once again.
phase('Verify')
const verified = await parallel(
  SLICES.map((s) => () =>
    agent(verifierPrompt(bucket[s.name], PROBES_TEXT[s.name], governedText[s.name]), {
      agentType: s.agentType,
      schema: VERIFIER_SCHEMA,
      phase: 'Verify',
      label: `verify:${s.name}`,
    })
      .then((result) => ({ slice: s.name, result }))
      .catch(() => ({ slice: s.name, result: null }))
  )
)

const failed = []
const verifiedClean = []
const degraded = []
const sliceMismatch = []
let droppedMalformed = 0
let droppedUnreachable = 0
let unread = 0
const rows = []

const bySlice = {}
for (const s of SLICES) bySlice[s.name] = []
for (const v of verified) bySlice[v.slice].push(v.result)

for (const s of SLICES) {
  const slice = s.name
  const passResults = bySlice[slice].filter((r) => r && Array.isArray(r.findings))
  // Nothing parseable back for this slice — its labels went unreviewed.
  if (passResults.length === 0) {
    failed.push(slice)
    continue
  }

  for (const result of passResults) {
    unread += result.hypotheses_unread || 0
    droppedUnreachable += result.dropped_unreachable || 0
  }

  // A label is unreviewed if the slice's own echo didn't name it.
  const echoedUnion = new Set()
  for (const result of passResults) for (const l of result.slice || []) echoedUnion.add(l)
  const missingLabels = s.labels.filter((l) => !echoedUnion.has(l))
  if (missingLabels.length) sliceMismatch.push({ slice, missing: missingLabels })

  let kept = 0
  let returned = 0
  for (const result of passResults) {
    returned += result.findings.length
    for (const f of result.findings) {
      if (!f || !f.file || f.line == null || !f.label || !f.failure_mode || !Array.isArray(f.evidence) || f.evidence.length < 2) {
        droppedMalformed++
        continue
      }
      rows.push({ ...f, slice })
      kept++
    }
  }
  if (returned === 0) verifiedClean.push(slice)
  else if (kept === 0) degraded.push({ slice, returned })
}

// §5.3 — slice, then label in table order within slice, then file, then line.
function compareBySliceLabelFileLine(a, b) {
  const sa = SLICE_ORDER.indexOf(a.slice), sb = SLICE_ORDER.indexOf(b.slice)
  if (sa !== sb) return sa - sb
  const la = LABEL_ORDER[a.slice].indexOf(a.label), lb = LABEL_ORDER[b.slice].indexOf(b.label)
  if (la !== lb) return la - lb
  if (a.file !== b.file) return a.file < b.file ? -1 : 1
  return a.line - b.line
}

// Dedup key is file+line+label (§5.2) — first survivor wins, keeps its own evidence.
const seen = new Set()
const deduped = []
for (const r of rows) {
  const key = `${r.file}::${r.line}::${r.label}`
  if (seen.has(key)) continue
  seen.add(key)
  deduped.push(r)
}

// Tallied off the deduped set, not raw rows — a hypothesis-sourced duplicate
// that dedup collapses to one entry must not still count twice toward proven.
const proven = deduped.filter((r) => r.source === 'hypothesis').length

// A Set of matched sweep-finding keys, not a per-hypothesis counter — two
// hypotheses landing on the same file+label must not double-credit the one
// sweep finding underneath them (§5.3). Matching is by slice+file+label only
// — hypotheses carry no line (scout's {file, label, one_line, related, rank}
// shape has none) — so that's the finest disambiguation available; .find()
// skips any sweep finding already claimed by an earlier hypothesis in this
// same loop, so when two *distinct* sweep findings share a file+label (two
// different lines), two hypotheses on that file+label each claim a
// different one instead of both racing for the same first match while the
// second genuinely-distinct finding goes uncounted.
let alsoSwept = 0
const sweptMatched = new Set()
for (const s of SLICES) {
  for (const h of bucket[s.name]) {
    const match = deduped.find((r) => {
      if (!(r.slice === s.name && r.file === h.file && r.label === h.label && r.source === 'sweep')) return false
      const key = `${r.slice}::${r.file}::${r.line}::${r.label}`
      return !sweptMatched.has(key)
    })
    if (!match) continue
    const key = `${match.slice}::${match.file}::${match.line}::${match.label}`
    sweptMatched.add(key)
    alsoSwept++
  }
}

deduped.sort(compareBySliceLabelFileLine)

const findings = deduped.map((r, i) => ({
  n: i + 1,
  file: r.file,
  line: r.line,
  label: r.label,
  source: r.source || null,
  failure_mode: r.failure_mode,
  evidence: r.evidence || [],
  // Optional, omitted entirely rather than null — matches core/doctrine.md's
  // own "every other finding omits it entirely, never null" instruction.
  ...(r.deviates_from ? { deviates_from: r.deviates_from } : {}),
}))

const scoutGraphCoverage = (scout.context || []).reduce((acc, c) => {
  acc[c.graph_coverage] = (acc[c.graph_coverage] || 0) + 1
  return acc
}, { hit: 0, none: 0 })

const scoutClassification = (scout.context || []).reduce((acc, c) => {
  if (c.classification) acc[c.classification] = (acc[c.classification] || 0) + 1
  return acc
}, { governed: 0, new: 0 })

const scoutMatchStrength = (scout.context || []).reduce((acc, c) => {
  if (c.match_strength) acc[c.match_strength] = (acc[c.match_strength] || 0) + 1
  return acc
}, { strong: 0, weak: 0 })

const hypothesesRaised = (scout.hypotheses || []).length
// What actually reached a verifier — raised minus what the router dropped
// (wrong label, wrong stack). Precision reads as proven ÷ routed, never
// ÷ raised, so a hypothesis nobody could act on doesn't count against it.
const hypothesesRouted = SLICES.reduce((acc, s) => acc + bucket[s.name].length, 0)

if (droppedHypotheses > 0) log(`${droppedHypotheses} scout hypothesis(es) dropped — label outside every slice, or outside this repo's stack scope`)
if (droppedMalformed > 0) log(`${droppedMalformed} finding(s) dropped — missing a required field`)
if (droppedUnreachable > 0) log(`${droppedUnreachable} candidate(s) dropped as unreachable — closing file not named`)
for (const d of degraded) log(`Degraded: ${d.slice} — ${d.returned} finding(s) returned, none renderable (missing fields). ${LABEL_ORDER[d.slice].join(', ')} was not reliably reviewed.`)
for (const m of sliceMismatch) log(`Warning: ${m.slice} echoed its slice without ${m.missing.join(', ')} — treat as unreviewed this run.`)

return {
  base,
  head,
  scope,
  graph,
  scout_failed: scoutFailed,
  slices_run: SLICE_ORDER,
  verified_clean: verifiedClean,
  failed,
  degraded,
  slice_mismatch: sliceMismatch,
  scout_graph_coverage: scoutGraphCoverage,
  scout_classification: scoutClassification,
  scout_match_strength: scoutMatchStrength,
  hypotheses: { raised: hypothesesRaised, routed: hypothesesRouted, proven, also_swept: alsoSwept, unread, dropped: droppedHypotheses },
  dropped_malformed: droppedMalformed,
  dropped_unreachable: droppedUnreachable,
  findings,
}
