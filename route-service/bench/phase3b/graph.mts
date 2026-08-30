/**
 * Phase 3B §2–§5, §8, §21–§24: the call graph, and what each call was for.
 *
 * Phase 3A's trace says what a call carried and what it cost. This one adds
 * who asked for it — which candidate, which leg of it, which retry of that
 * leg, and which earlier call it is a fix-up of — so a call can be traced to
 * the decision that made it necessary rather than merely counted.
 *
 * Two rules it reads by, both inherited. Latency summed across concurrent
 * callers is not time a walker waited, so nothing here is stated as a
 * duration. And a call the generator never made and a call the memo answered
 * are different savings at different scales, counted apart throughout.
 */
import { writeFileSync } from 'node:fs'
import { load, type Call, type Decision } from './corpus.mjs'

const FIXTURES = ['douglas-3km', 'douglas-5km', 'onchan-5km', 'peel-5km', 'wp-one', 'wp-two']
const { calls, decisions } = load()
const sum = (values: number[]) => values.reduce((total, value) => total + value, 0)
const pct = (part: number, whole: number) => `${((part / Math.max(1, whole)) * 100).toFixed(1)}%`
const stats = (values: number[]) => {
  if (!values.length) return { mean: 0, median: 0, p90: 0, max: 0 }
  const sorted = [...values].sort((a, b) => a - b)
  const at = (f: number) => sorted[Math.min(sorted.length - 1, Math.ceil(f * sorted.length) - 1)]
  return { mean: sum(values) / values.length, median: at(0.5), p90: at(0.9), max: sorted[sorted.length - 1] }
}
const out: string[] = []
const say = (line = '') => { out.push(line); console.log(line) }

// ── §2 the call graph ───────────────────────────────────────────────────────
say('## Call graph: fix-ups by parent\n')
say('| purpose | calls | with a named parent | distinct parents | calls per parent |')
say('|---|---:|---:|---:|---:|')
const purposes = [...new Set(calls.map(call => call.purpose))]
  .sort((a, b) => calls.filter(c => c.purpose === b).length - calls.filter(c => c.purpose === a).length)
for (const purpose of purposes) {
  const group = calls.filter(call => call.purpose === purpose)
  const parented = group.filter(call => call.parentCallId !== undefined)
  const parents = new Set(parented.map(call => `${call.fixture}:${call.parentCallId}`))
  say(`| \`${purpose}\` | ${group.length} | ${parented.length} | ${parents.size} | ${parents.size ? (parented.length / parents.size).toFixed(2) : '—'} |`)
}
say(`| **total** | **${calls.length}** | | | |`)

// ── §5, §24 chain length per routed leg ─────────────────────────────────────
say('\n## Fix-up chains per routed leg\n')
const fixupsOf = new Map<string, Call[]>()
for (const call of calls) {
  if (call.parentCallId === undefined) continue
  const key = `${call.fixture}:${call.parentCallId}`
  fixupsOf.set(key, [...(fixupsOf.get(key) ?? []), call])
}
const baseCalls = calls.filter(call => call.purpose === 'leg' || call.purpose === 'waypoint-leg' || call.purpose === 'leg-relaxed')
const chainShape = new Map<string, number>()
for (const base of baseCalls) {
  const children = fixupsOf.get(`${base.fixture}:${base.callId}`) ?? []
  const shape = children.length ? children.map(child => child.purpose).join(' → ') : '(none)'
  chainShape.set(shape, (chainShape.get(shape) ?? 0) + 1)
}
say('| what hangs off one ordinary leg call | legs | share | calls it costs |')
say('|---|---:|---:|---:|')
for (const [shape, count] of [...chainShape.entries()].sort((a, b) => b[1] - a[1])) {
  const extra = shape === '(none)' ? 0 : shape.split(' → ').length
  say(`| ${shape === '(none)' ? '— nothing' : `\`${shape}\``} | ${count} | ${pct(count, baseCalls.length)} | ${count * (1 + extra)} |`)
}
say(`| **total ordinary leg calls** | **${baseCalls.length}** | | **${calls.length}** |`)

// ── §4 join-pullback anatomy ────────────────────────────────────────────────
say('\n## join-pullback anatomy\n')
const pullbacks = calls.filter(call => call.purpose === 'join-pullback')
// One invocation is one decision. The notes a call carries name the invocation
// it belongs to, and both of a pair carry them, so calls never count invocations.
const pullbackDecisions = decisions.filter(d => d.kind === 'join-pullback')
say(`${pullbacks.length} calls across ${pullbackDecisions.length} invocations — ` +
  `${(pullbacks.length / Math.max(1, pullbackDecisions.length)).toFixed(2)} calls each.\n`)
say('| trigger | invocations | share | median join turn | median pullback movement (m) |')
say('|---|---:|---:|---:|---:|')
for (const trigger of [...new Set(pullbackDecisions.map(d => d.trigger))]) {
  const group = pullbackDecisions.filter(d => d.trigger === trigger)
  say(`| ${trigger} | ${group.length} | ${pct(group.length, pullbackDecisions.length)} | ${stats(group.map(d => d.joinTurn ?? 0)).median} | ${stats(group.map(d => (d as any).moved ?? 0)).median} |`)
}
const kept = pullbackDecisions.filter(d => d.kept)
say(`\nkept: **${kept.length} of ${pullbackDecisions.length}** (${pct(kept.length, pullbackDecisions.length)})`)
const movement = stats(pullbackDecisions.map(d => (d as any).moved ?? 0))
say(`\npullback movement, metres: mean ${movement.mean.toFixed(0)}, median ${movement.median}, p90 ${movement.p90}, max ${movement.max}`)
const turnKept = stats(kept.map(d => (d.joinTurn ?? 0) - (d.redoneTurn ?? 0)))
say(`turn straightened where kept, degrees: mean ${turnKept.mean.toFixed(0)}, median ${turnKept.median}`)
const stillSharp = pullbackDecisions.filter(d => !d.kept && (d.redoneTurn ?? 0) >= (d.joinTurn ?? 0))
say(`invocations that paid two calls and left the join no straighter: **${stillSharp.length}** (${pct(stillSharp.length, pullbackDecisions.length)})`)

// chains: how many pullbacks per leg step
const stepKey = (d: { fixture: string; candidateId?: string; legIndex?: number }) => `${d.fixture}:${d.candidateId}:${d.legIndex}`
const perStep = new Map<string, number>()
for (const d of pullbackDecisions) perStep.set(stepKey(d), (perStep.get(stepKey(d)) ?? 0) + 1)
const shapeCount = new Map<number, number>()
for (const count of perStep.values()) shapeCount.set(count, (shapeCount.get(count) ?? 0) + 1)
say('\n| join-pullback invocations on one leg seam | seams |')
say('|---|---:|')
for (const [count, seams] of [...shapeCount.entries()].sort((a, b) => a[0] - b[0])) say(`| ${count} | ${seams} |`)

// ── §8, §9 leg-budget anatomy ───────────────────────────────────────────────
say('\n## leg-budget anatomy\n')
const budgets = calls.filter(call => call.purpose === 'leg-budget')
const budgetDecisions = decisions.filter(d => d.kind === 'leg-budget')
const budgetKept = budgetDecisions.filter(d => d.kept)
say(`${budgets.length} calls; kept **${budgetKept.length}** (${pct(budgetKept.length, budgetDecisions.length)}).\n`)
const shortenBy = budgetKept.map(d => (d.before ?? 0) - (d.after ?? 0))
const shorten = stats(shortenBy)
say(`where kept, metres saved: mean ${shorten.mean.toFixed(0)}, median ${shorten.median}, p90 ${shorten.p90}, max ${shorten.max}`)
const overBudget = budgets.map(c => (c.strongDistance ?? 0) / Math.max(1, c.budgetMetres ?? 1))
const over = stats(overBudget)
say(`the strong leg's length as a multiple of the budget: mean ${over.mean.toFixed(2)}×, median ${over.median.toFixed(2)}×, p90 ${over.p90.toFixed(2)}×`)
say('\n| leg-budget calls on one leg step | steps |')
say('|---|---:|')
const budgetPerStep = new Map<string, number>()
for (const call of budgets) budgetPerStep.set(stepKey(call), (budgetPerStep.get(stepKey(call)) ?? 0) + 1)
const budgetShape = new Map<number, number>()
for (const count of budgetPerStep.values()) budgetShape.set(count, (budgetShape.get(count) ?? 0) + 1)
for (const [count, steps] of [...budgetShape.entries()].sort((a, b) => a[0] - b[0])) say(`| ${count} | ${steps} |`)

// did the relaxed answer end up accepted by attemptLeg?
const legAttempts = decisions.filter(d => d.kind === 'leg-attempt')
say(`\nleg attempts: ${legAttempts.length}; accepted first time ${legAttempts.filter(d => d.attempt === 0 && d.kept).length}; ` +
  `retried ${legAttempts.filter(d => !d.kept).length}; of those exhausted ${legAttempts.filter(d => !d.kept && d.last).length}`)
const retryReason = { budget: 0, backtrack: 0, both: 0 }
for (const d of legAttempts.filter(x => !x.kept)) {
  if (!d.fitsBudget && d.shortBacktrack) retryReason.both++
  else if (!d.fitsBudget) retryReason.budget++
  else retryReason.backtrack++
}
say(`retry reasons — over planned length only ${retryReason.budget}, short backtrack only ${retryReason.backtrack}, both ${retryReason.both}`)

// §9: does a retry actually converge?
const byStep = new Map<string, Decision[]>()
for (const d of legAttempts) byStep.set(stepKey(d), [...(byStep.get(stepKey(d)) ?? []), d])
const chains = [...byStep.values()].filter(list => list.length > 1)
let closer = 0, further = 0
for (const chain of chains) {
  const ordered = [...chain].sort((a, b) => (a.attempt ?? 0) - (b.attempt ?? 0))
  const errorOf = (d: Decision) => Math.abs((d.got ?? 0) - (d.planned ?? 0))
  if (errorOf(ordered[ordered.length - 1]) < errorOf(ordered[0])) closer++
  else further++
}
say(`\nleg steps that retried: ${chains.length}; last attempt closer to planned length than the first: ${closer}, not closer: ${further}`)

// ── §3, §21, §22 calls per candidate and per outcome ────────────────────────
say('\n## Calls per candidate, and what the candidate came to\n')
const candidateKey = (row: { fixture: string; candidateId?: string }) => `${row.fixture}:${row.candidateId ?? '(none)'}`
const callsPerCandidate = new Map<string, number>()
for (const call of calls) callsPerCandidate.set(candidateKey(call), (callsPerCandidate.get(candidateKey(call)) ?? 0) + 1)
const candidateOutcome = new Map<string, Decision>()
for (const d of decisions.filter(x => x.kind === 'candidate')) candidateOutcome.set(candidateKey(d), d)
const spread = stats([...callsPerCandidate.values()])
say(`calls per candidate build: mean ${spread.mean.toFixed(1)}, median ${spread.median}, p90 ${spread.p90}, max ${spread.max}, over ${callsPerCandidate.size} builds\n`)

const outcomes = new Map<string, { builds: number; calls: number }>()
for (const [key, count] of callsPerCandidate) {
  const outcome = candidateOutcome.get(key)?.outcome
    ?? (key.endsWith('(none)') ? 'unattributed' : 'abandoned-or-cancelled')
  const bucket = outcomes.get(outcome) ?? { builds: 0, calls: 0 }
  bucket.builds++
  bucket.calls += count
  outcomes.set(outcome, bucket)
}
say('| candidate outcome | builds | GH calls | % of calls | calls per build |')
say('|---|---:|---:|---:|---:|')
for (const [outcome, bucket] of [...outcomes.entries()].sort((a, b) => b[1].calls - a[1].calls)) {
  say(`| ${outcome} | ${bucket.builds} | ${bucket.calls} | ${pct(bucket.calls, calls.length)} | ${(bucket.calls / bucket.builds).toFixed(1)} |`)
}

// §22 rejection reasons and what they cost
say('\n| first rejection reason | builds | GH calls | % of calls | calls per build |')
say('|---|---:|---:|---:|---:|')
const reasons = new Map<string, { builds: number; calls: number }>()
for (const [key, count] of callsPerCandidate) {
  const decision = candidateOutcome.get(key)
  if (!decision || decision.outcome !== 'failed-quality') continue
  const reason = decision.rejections?.[0] ?? 'unknown'
  const bucket = reasons.get(reason) ?? { builds: 0, calls: 0 }
  bucket.builds++
  bucket.calls += count
  reasons.set(reason, bucket)
}
for (const [reason, bucket] of [...reasons.entries()].sort((a, b) => b[1].calls - a[1].calls)) {
  say(`| ${reason} | ${bucket.builds} | ${bucket.calls} | ${pct(bucket.calls, calls.length)} | ${(bucket.calls / bucket.builds).toFixed(1)} |`)
}

// ── §12, §13 duplication ────────────────────────────────────────────────────
say('\n## Duplicate and near-duplicate questions\n')
say('| | calls |')
say('|---|---:|')
say(`| answered by the exact memo | ${calls.filter(c => c.memo === 'hit' || c.memo === 'join').length} |`)
const mirrorPairs = calls.filter(c => c.legIndex === 0 && c.legAttempt === 0 && c.purpose === 'leg' && c.candidateKind === 'ring')
const mirrored = new Map<string, number>()
for (const call of mirrorPairs) {
  const pair = `${call.fixture}:${call.candidateId?.split('-')[0]}@${call.cornerCount}:${call.plannedMetres}`
  mirrored.set(pair, (mirrored.get(pair) ?? 0) + 1)
}
const redundantMirrors = sum([...mirrored.values()].map(count => count - 1))
say(`| first legs of a mirrored bearing pair, which ask the identical question | ${redundantMirrors} |`)
say(`| first-leg calls in all | ${mirrorPairs.length} |`)

// ── §33 calls per returned route ────────────────────────────────────────────
say('\n## Calls per fixture\n')
say('| fixture | calls | leg | join-pullback | leg-budget | waypoint-leg | spike | other | memo hits | candidate builds |')
say('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
const named = ['leg', 'join-pullback', 'leg-budget', 'waypoint-leg', 'spike']
for (const fixture of FIXTURES) {
  const group = calls.filter(call => call.fixture === fixture)
  const counts = named.map(purpose => group.filter(call => call.purpose === purpose).length)
  const builds = new Set(group.map(call => call.candidateId)).size
  say(`| ${fixture} | ${group.length} | ${counts.join(' | ')} | ${group.length - sum(counts)} | ${group.filter(c => c.memo === 'hit' || c.memo === 'join').length} | ${builds} |`)
}
say(`| **total** | **${calls.length}** | ${named.map(p => calls.filter(c => c.purpose === p).length).join(' | ')} | ${calls.length - sum(named.map(p => calls.filter(c => c.purpose === p).length))} | ${calls.filter(c => c.memo === 'hit' || c.memo === 'join').length} | ${callsPerCandidate.size} |`)

writeFileSync(new URL('results/graph.md', import.meta.url), out.join('\n') + '\n')
