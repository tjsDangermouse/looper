/**
 * Phase 5 P1-P4: evaluate complete remaining-shape estimates against the final
 * routed candidate. This never calls GraphHopper and never changes generation.
 *
 *   CORPUS=../phase4/corpus-P5_FULL npx tsx bench/phase5/analyse.mts
 */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { FIXTURES } from '../phase2/fixtures.mjs'
import { constructRemainingShape } from '../../src/loops/fullShape.js'
import { MAX_DISTANCE_ERROR } from '../../src/loops/quality.js'

const FIXTURE_NAMES = FIXTURES.map(fixture => fixture.name)
const starts = new Map(FIXTURES.map(fixture => [fixture.name, [fixture.body.start.lng, fixture.body.start.lat] as [number, number]]))
const corpusArg = process.env.CORPUS ?? '../phase4/corpus-P5_FULL'
const corpus = new URL(`${corpusArg.replace(/\/$/, '')}/`, import.meta.url)
const outputDir = new URL('results/', import.meta.url)
mkdirSync(outputDir, { recursive: true })

type Row = Record<string, any> & { fixture: string }
const rows: Row[] = []
for (const fixture of FIXTURE_NAMES) {
  const text = readFileSync(new URL(`${fixture}.jsonl`, corpus), 'utf8').trim()
  for (const line of text.split('\n')) if (line) rows.push({ fixture, ...JSON.parse(line) })
}
const key = (row: Row) => `${row.fixture}:${row.candidateId}`
const candidates = new Map(rows.filter(row => row.event === 'decision' && row.kind === 'candidate').map(row => [key(row), row]))
const estimators = ['F0', 'F1', 'F2', 'F3'] as const
type Estimator = typeof estimators[number]
const scales = [0.7, 0.85, 1, 1.15, 1.3]
const number = (value: unknown): number | undefined => typeof value === 'number' && Number.isFinite(value) ? value : undefined
const percentile = (values: number[], p: number): number => {
  if (!values.length) return 0
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * p) - 1)]
}
const median = (values: number[]) => percentile(values, .5)
const pct = (value: number, total: number) => `${(100 * value / Math.max(1, total)).toFixed(1)}%`
const classify = (distance: number, target: number) => distance < target * (1 - MAX_DISTANCE_ERROR)
  ? 'TOO_SHORT' : distance > target * (1 + MAX_DISTANCE_ERROR) ? 'TOO_LONG' : 'ACCEPTABLE'
const outcomeFor = (candidate: Row) => {
  if (candidate.outcome === 'passed') return 'PASS'
  if (candidate.rejections?.includes('distance')) return classify(candidate.distance, candidate.target)
  return 'OTHER_QUALITY_FAILURE'
}

type Stage = {
  fixture: string
  candidateId: string
  cornerCount: number
  stage: number
  target: number
  used: number
  actual: number
  actualError: number
  outcome: string
  predictions: Record<Estimator, number>
  samples: Record<Estimator, number[]>
  monotonic: boolean
}
const stages: Stage[] = []
for (const plan of rows.filter(row => row.event === 'decision' && row.kind === 'leg-plan')) {
  const candidate = candidates.get(key(plan))
  const currentLng = number(plan.currentLng), currentLat = number(plan.currentLat)
  const heading = number(plan.intendedHeading), radius = number(plan.guidePointCrowDistance)
  const used = number(plan.distanceUsedBeforeLeg), actual = number(candidate?.distance), target = number(candidate?.target)
  if (!candidate || currentLng === undefined || currentLat === undefined || heading === undefined || radius === undefined
    || used === undefined || actual === undefined || target === undefined || !plan.direction) continue
  const start = starts.get(plan.fixture)!
  const stretches: Record<Estimator, number> = {
    F0: 1,
    F1: 1.35,
    F2: Number(plan.fullShapeLocalStretch),
    F3: Number(plan.fullShapeBlendedStretch),
  }
  const sampled = Object.fromEntries(estimators.map(estimator => [estimator, scales.map(scale => {
    const shape = constructRemainingShape(
      start, [currentLng, currentLat], plan.cornerCount - plan.legIndex,
      radius * scale, heading, plan.direction, plan.cornerCount,
    )
    return used + shape.crowMetres * stretches[estimator]
  })])) as Record<Estimator, number[]>
  const predictions = Object.fromEntries(estimators.map(estimator => [estimator, sampled[estimator][2]])) as Record<Estimator, number>
  stages.push({
    fixture: plan.fixture, candidateId: plan.candidateId, cornerCount: plan.cornerCount, stage: plan.legIndex,
    target, used, actual, actualError: actual - target, outcome: outcomeFor(candidate), predictions, samples: sampled,
    monotonic: sampled.F1.every((value, index, values) => index === 0 || value >= values[index - 1] - 1e-6),
  })
}

const output: string[] = []
const say = (line = '') => { output.push(line); console.log(line) }
const stageNames = [...new Set(stages.map(row => row.stage))].sort((a, b) => a - b)
say(`# Phase 5 full-shape offline analysis — ${corpusArg}`)
say(`\n${stages.length} intermediate states from ${new Set(stages.map(row => `${row.fixture}:${row.candidateId}`)).size} completed candidates.`)

say('\n## P1 — distance-failure anatomy\n')
say('| fixture | outcome | candidates | median final error (m) |')
say('|---|---|---:|---:|')
for (const fixture of FIXTURE_NAMES) {
  const fixtureCandidates = [...candidates.values()].filter(row => row.fixture === fixture)
  for (const outcome of ['PASS', 'TOO_SHORT', 'TOO_LONG', 'OTHER_QUALITY_FAILURE']) {
    const selected = fixtureCandidates.filter(row => outcomeFor(row) === outcome)
    if (!selected.length) continue
    say(`| ${fixture} | ${outcome} | ${selected.length} | ${median(selected.map(row => row.distance - row.target)).toFixed(0)} |`)
  }
}

say('\n## P2/P3 — estimator accuracy by stage\n')
say('| stage | estimator | n | median abs (m) | p75 | p90 | median bias | under / over | classification accuracy |')
say('|---:|---|---:|---:|---:|---:|---:|---:|---:|')
for (const stage of stageNames) for (const estimator of estimators) {
  const selected = stages.filter(row => row.stage === stage)
  const signed = selected.map(row => row.predictions[estimator] - row.actual)
  const absolute = signed.map(Math.abs)
  const correct = selected.filter(row => classify(row.predictions[estimator], row.target) === classify(row.actual, row.target)).length
  say(`| ${stage} | ${estimator} | ${selected.length} | ${median(absolute).toFixed(0)} | ${percentile(absolute, .75).toFixed(0)} | ${percentile(absolute, .9).toFixed(0)} | ${median(signed).toFixed(0)} | ${signed.filter(x => x < 0).length} / ${signed.filter(x => x > 0).length} | ${pct(correct, selected.length)} |`)
}

say('\n### Predictability by corner count, stage, and final outcome (F0)\n')
say('| corners | stage | final outcome | states | F0 predicts same distance class | median final error (m) |')
say('|---:|---:|---|---:|---:|---:|')
const cornerCounts = [...new Set(stages.map(row => row.cornerCount))].sort((a, b) => a - b)
for (const cornerCount of cornerCounts) for (const stage of stageNames) for (const outcome of ['PASS', 'TOO_SHORT', 'TOO_LONG', 'OTHER_QUALITY_FAILURE']) {
  const selected = stages.filter(row => row.cornerCount === cornerCount && row.stage === stage && row.outcome === outcome)
  if (!selected.length) continue
  const correct = selected.filter(row => classify(row.predictions.F0, row.target) === classify(row.actual, row.target)).length
  say(`| ${cornerCount} | ${stage} | ${outcome} | ${selected.length} | ${correct} (${pct(correct, selected.length)}) | ${median(selected.map(row => row.actualError)).toFixed(0)} |`)
}

say('\n### Accuracy by fixture and stage (median absolute error, metres)\n')
say('| fixture | stage | F0 | F1 | F2 | F3 |')
say('|---|---:|---:|---:|---:|---:|')
for (const fixture of FIXTURE_NAMES) for (const stage of stageNames) {
  const selected = stages.filter(row => row.fixture === fixture && row.stage === stage)
  if (!selected.length) continue
  say(`| ${fixture} | ${stage} | ${estimators.map(estimator => median(selected.map(row => Math.abs(row.predictions[estimator] - row.actual))).toFixed(0)).join(' | ')} |`)
}

say('\n### Accepted-band classification matrices\n')
for (const estimator of estimators) {
  say(`\n${estimator}: rows are actual, columns predicted.\n`)
  say('| stage / actual | TOO_SHORT | ACCEPTABLE | TOO_LONG |')
  say('|---|---:|---:|---:|')
  for (const stage of stageNames) for (const actualClass of ['TOO_SHORT', 'ACCEPTABLE', 'TOO_LONG']) {
    const selected = stages.filter(row => row.stage === stage && classify(row.actual, row.target) === actualClass)
    if (!selected.length) continue
    const counts = ['TOO_SHORT', 'ACCEPTABLE', 'TOO_LONG'].map(predicted => selected.filter(row => classify(row.predictions[estimator], row.target) === predicted).length)
    say(`| ${stage} / ${actualClass} | ${counts.join(' | ')} |`)
  }
}

say('\n## Radius monotonicity\n')
say('| stage | states | non-decreasing with non-zero control range over 0.7×…1.3× |')
say('|---:|---:|---:|')
for (const stage of stageNames) {
  const selected = stages.filter(row => row.stage === stage)
  const actionable = selected.filter(row => row.monotonic && row.samples.F1.at(-1)! - row.samples.F1[0] > 1).length
  say(`| ${stage} | ${selected.length} | ${actionable} (${pct(actionable, selected.length)}) |`)
}

say('\n## P4 — conservative theoretical correction ceiling\n')
say('A failure is counted only when the estimator predicts the correct failure side and the sampled radius range has enough predicted movement in that direction to cover the oracle metres needed to reach the accepted band. This establishes geometric opportunity, not guaranteed network recovery.')
say('\n| stage | estimator | failures observed | predictably bad | plausibly correctable |')
say('|---:|---|---:|---:|---:|')
const recovery: Record<string, Record<string, string[]>> = {}
for (const stage of stageNames) for (const estimator of estimators) {
  const failures = stages.filter(row => row.stage === stage && ['TOO_SHORT', 'TOO_LONG'].includes(row.outcome))
  const predictable = failures.filter(row => classify(row.predictions[estimator], row.target) === row.outcome)
  const correctable = predictable.filter(row => {
    const base = row.samples[estimator][2]
    const needed = row.outcome === 'TOO_SHORT'
      ? row.target * (1 - MAX_DISTANCE_ERROR) - row.actual
      : row.actual - row.target * (1 + MAX_DISTANCE_ERROR)
    const freedom = row.outcome === 'TOO_SHORT'
      ? Math.max(...row.samples[estimator].slice(3)) - base
      : base - Math.min(...row.samples[estimator].slice(0, 2))
    return needed > 0 && freedom >= needed
  })
  recovery[`${stage}:${estimator}`] = { predictable: predictable.map(row => `${row.fixture}:${row.candidateId}`), correctable: correctable.map(row => `${row.fixture}:${row.candidateId}`) }
  say(`| ${stage} | ${estimator} | ${failures.length} | ${predictable.length} (${pct(predictable.length, failures.length)}) | ${correctable.length} (${pct(correctable.length, failures.length)}) |`)
}

say('\n### Unique failures recoverable at any pre-closure stage\n')
say('| estimator | all distance failures | recoverable | no-waypoint failures | recoverable |')
say('|---|---:|---:|---:|---:|')
const distanceFailures = [...candidates.values()].filter(row => ['TOO_SHORT', 'TOO_LONG'].includes(outcomeFor(row)))
for (const estimator of estimators) {
  const recovered = new Set(stageNames.flatMap(stage => recovery[`${stage}:${estimator}`].correctable))
  const normal = distanceFailures.filter(row => !row.fixture.startsWith('wp-'))
  const normalRecovered = normal.filter(row => recovered.has(key(row))).length
  say(`| ${estimator} | ${distanceFailures.length} | ${recovered.size} (${pct(recovered.size, distanceFailures.length)}) | ${normal.length} | ${normalRecovered} (${pct(normalRecovered, normal.length)}) |`)
}

writeFileSync(new URL('offline-analysis.md', outputDir), output.join('\n') + '\n')
writeFileSync(new URL('offline-analysis.json', outputDir), JSON.stringify({ corpus: corpusArg, stages, recovery }, null, 2) + '\n')
