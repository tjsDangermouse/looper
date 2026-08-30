/** Read a Phase 4 capture into the closure anatomy and candidate-efficiency tables. */
import { readFileSync, writeFileSync } from 'node:fs'

const FIXTURES = ['douglas-3km', 'douglas-5km', 'onchan-5km', 'peel-5km', 'wp-one', 'wp-two']
const corpus = process.env.CORPUS ?? 'corpus-C0'
const dir = new URL(`${corpus}/`, import.meta.url)
type Record = { fixture: string; event?: string; kind?: string; candidateId?: string; cornerCount?: number; outcome?: string; rejections?: string[]; purpose?: string; [key: string]: any }
const records: Record[] = []
for (const fixture of FIXTURES) {
  const file = new URL(`${fixture}.jsonl`, dir)
  for (const line of readFileSync(file, 'utf8').trim().split('\n')) if (line) records.push({ fixture, ...JSON.parse(line) })
}

const number = (value: unknown) => typeof value === 'number' && Number.isFinite(value) ? value : undefined
const percentile = (values: number[], p: number) => {
  if (!values.length) return 0
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * p) - 1)]
}
const stats = (values: number[]) => `median ${percentile(values, .5).toFixed(0)}, p25 ${percentile(values, .25).toFixed(0)}, p75 ${percentile(values, .75).toFixed(0)}, p90 ${percentile(values, .9).toFixed(0)}`
const candidateKey = (row: Record) => `${row.fixture}:${row.candidateId ?? '(none)'}`
const calls = records.filter(r => !r.event)
const candidates = records.filter(r => r.kind === 'candidate')
const closures = records.filter(r => r.kind === 'closure')
const plans = records.filter(r => r.kind === 'leg-plan')
const results = records.filter(r => r.kind === 'leg-result')
const output: string[] = []
const say = (line = '') => { output.push(line); console.log(line) }
const pct = (value: number, total: number) => `${(100 * value / Math.max(1, total)).toFixed(1)}%`

say(`# Phase 4 closure analysis — ${corpus}`)
say()
say(`Trace: ${calls.length} calls, ${candidates.length} completed candidates, ${plans.length} planned legs, ${closures.length} completed closures.`)
say('\n## Candidate efficiency\n')
say('| fixture | built | passed | pass rate | distance failures | calls |')
say('|---|---:|---:|---:|---:|---:|')
for (const fixture of FIXTURES) {
  const cs = candidates.filter(c => c.fixture === fixture)
  const passed = cs.filter(c => c.outcome === 'passed').length
  const distance = cs.filter(c => c.rejections?.includes('distance')).length
  say(`| ${fixture} | ${cs.length} | ${passed} | ${pct(passed, cs.length)} | ${distance} | ${calls.filter(c => c.fixture === fixture).length} |`)
}
const passed = candidates.filter(c => c.outcome === 'passed').length
const distanceFailures = candidates.filter(c => c.rejections?.includes('distance'))
const tooShort = distanceFailures.filter(c => (number(c.distance) ?? Infinity) < (number(c.target) ?? 0)).length
say(`| **total** | **${candidates.length}** | **${passed}** | **${pct(passed, candidates.length)}** | **${distanceFailures.length} (${tooShort} short / ${distanceFailures.length - tooShort} long)** | **${calls.length}** |`)

say('\n## Closure anatomy\n')
say('| fixture | closures | remaining budget (m) | close distance (m) | close / budget |')
say('|---|---:|---:|---:|---:|')
for (const fixture of FIXTURES) {
  const rows = closures.filter(c => c.fixture === fixture)
  const budgets = rows.map(c => number(c.remainingBudgetBeforeClose)).filter((x): x is number => x !== undefined)
  const close = rows.map(c => number(c.actualGraphHopperCloseDistance)).filter((x): x is number => x !== undefined)
  const ratios = rows.map(c => number(c.closeDistanceOverRemainingBudget)).filter((x): x is number => x !== undefined)
  say(`| ${fixture} | ${rows.length} | ${percentile(budgets, .5).toFixed(0)} | ${percentile(close, .5).toFixed(0)} | ${percentile(ratios, .5).toFixed(2)} |`)
}
say(`\nRemaining budget: ${stats(closures.map(c => number(c.remainingBudgetBeforeClose)).filter((x): x is number => x !== undefined))}.`)
say(`Actual close: ${stats(closures.map(c => number(c.actualGraphHopperCloseDistance)).filter((x): x is number => x !== undefined))}.`)

say('\n## Cheap-estimator trace\n')
const estimates = results
  .map(row => ({ actual: number(row.closureEstimate), crow: number(row.straightLineDistanceHome), stretch: number(row.closureStretch) }))
  .filter((row): row is { actual: number; crow: number; stretch: number } => row.actual !== undefined && row.crow !== undefined && row.stretch !== undefined)
say(`Intermediate endpoint estimates recorded: ${estimates.length}. Their local stretch multiplier is ${stats(estimates.map(x => x.stretch))}.`)
say('The C2 oracle must be run separately: a closure distance from an intermediate endpoint cannot be recovered from this trace without issuing the direct-home GraphHopper request.')

const closureByCandidate = new Map(closures.map(row => [candidateKey(row), row]))
const closingPlans = plans.filter(row => row.legIndex === row.cornerCount)
const estimatorRows = [
  ['E0 — current implicit budget', (plan: Record, closure: Record) => number(closure.remainingBudgetBeforeClose)],
  ['E1 — crow distance', (plan: Record) => number(plan.straightLineDistanceHome)],
  ['E2 — global 1.35× crow', (plan: Record) => (number(plan.straightLineDistanceHome) ?? 0) * 1.35],
  ['E3 — candidate-local bounded stretch', (plan: Record) => number(plan.closureEstimate)],
] as const
say('\n| estimator | median absolute error (m) | p75 | p90 | median bias | under / over |')
say('|---|---:|---:|---:|---:|---:|')
for (const [name, estimate] of estimatorRows) {
  const errors: number[] = []
  const signed: number[] = []
  for (const plan of closingPlans) {
    const closure = closureByCandidate.get(candidateKey(plan))
    if (!closure) continue
    const actual = number(closure.actualGraphHopperCloseDistance)
    const predicted = estimate(plan, closure)
    if (actual === undefined || predicted === undefined) continue
    signed.push(predicted - actual)
    errors.push(Math.abs(predicted - actual))
  }
  say(`| ${name} | ${percentile(errors, .5).toFixed(0)} | ${percentile(errors, .75).toFixed(0)} | ${percentile(errors, .9).toFixed(0)} | ${percentile(signed, .5).toFixed(0)} | ${signed.filter(x => x < 0).length} / ${signed.filter(x => x > 0).length} |`)
}

say('\n## Calls by outcome\n')
const callsByCandidate = new Map<string, number>()
for (const call of calls) callsByCandidate.set(candidateKey(call), (callsByCandidate.get(candidateKey(call)) ?? 0) + 1)
const outcomeByCandidate = new Map(candidates.map(c => [candidateKey(c), c]))
for (const outcome of ['passed', 'distance', 'quality/other']) {
  const selected = [...callsByCandidate].filter(([key]) => {
    const candidate = outcomeByCandidate.get(key)
    return outcome === 'passed' ? candidate?.outcome === 'passed'
      : outcome === 'distance' ? candidate?.rejections?.includes('distance')
      : candidate && candidate.outcome !== 'passed' && !candidate.rejections?.includes('distance')
  })
  say(`| ${outcome} | ${selected.length} candidates | ${selected.reduce((sum, [, count]) => sum + count, 0)} calls |`)
}

writeFileSync(new URL('results.md', dir), output.join('\n') + '\n')
