/** Offline Phase 6 perimeter waterfall, aggregation, retention and oracle analysis. */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { FIXTURES } from '../phase2/fixtures.mjs'
import { haversine, type LngLat } from '../../src/loops/geo.js'
import { MAX_DISTANCE_ERROR } from '../../src/loops/quality.js'

type Row = Record<string, any> & { fixture: string }
type Occurrence = { fixture: string; candidateId: string; outcome: string; mechanism: string; stage: number; delta: number; controllable: boolean }
const corpusArg = process.env.CORPUS ?? 'corpus-P6'
const corpus = new URL(`${corpusArg.replace(/\/$/, '')}/`, import.meta.url)
const results = new URL('results/', import.meta.url)
mkdirSync(results, { recursive: true })
const rows: Row[] = []
for (const fixture of FIXTURES.map(value => value.name)) {
  const body = readFileSync(new URL(`${fixture}.jsonl`, corpus), 'utf8').trim()
  for (const line of body.split('\n')) if (line) rows.push({ fixture, ...JSON.parse(line) })
}
const key = (row: Row) => `${row.fixture}:${row.candidateId}`
const finite = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value)
const percentile = (values: number[], p: number) => {
  if (!values.length) return 0
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil(sorted.length * p) - 1))]
}
const pct = (part: number, total: number) => `${(100 * part / Math.max(1, total)).toFixed(1)}%`
const point = (value: unknown): LngLat | undefined => Array.isArray(value) && value.length === 2 && value.every(finite) ? value as LngLat : undefined
const pathCrow = (points: LngLat[]) => points.slice(1).reduce((sum, current, index) => sum + haversine(points[index], current), 0)
const classify = (distance: number, target: number) => distance < target * (1 - MAX_DISTANCE_ERROR)
  ? 'TOO_SHORT' : distance > target * (1 + MAX_DISTANCE_ERROR) ? 'TOO_LONG' : 'ACCEPTABLE'
const outcomeFor = (candidate: Row) => candidate.outcome === 'passed' ? 'PASS'
  : candidate.rejections?.includes('distance') ? classify(candidate.distance, candidate.target) : 'OTHER_QUALITY_FAILURE'

const decisions = rows.filter(row => row.event === 'decision')
const candidates = new Map<string, Row>()
for (const row of decisions.filter(row => row.kind === 'candidate' && finite(row.distance))) candidates.set(key(row), row)
const groups = new Map<string, Row[]>()
for (const row of decisions) {
  if (!row.candidateId) continue
  const id = key(row)
  groups.set(id, [...(groups.get(id) ?? []), row])
}

const occurrences: Occurrence[] = []
const candidateData: any[] = []
for (const [id, candidate] of candidates) {
  const events = groups.get(id) ?? []
  const start = events.find(row => row.kind === 'candidate-start')
  const finalize = events.find(row => row.kind === 'candidate-finalize')
  const initial = Number(start?.initialIntendedPerimeter)
  if (!finite(initial) || initial <= 0) continue
  const outcome = outcomeFor(candidate)
  const plans = events.filter(row => row.kind === 'leg-plan').sort((a, b) => a.legIndex - b.legIndex)
  const legResults = events.filter(row => row.kind === 'leg-result')
  const stages: any[] = []
  for (const plan of plans) {
    const stage = Number(plan.legIndex)
    const used = Number(plan.distanceUsedBeforeLeg)
    const remaining = Number(plan.intendedRemainingShapeCrowMetres)
    if (!finite(stage) || !finite(used) || !finite(remaining)) continue
    let replanDelta = 0
    if (stage > 0) {
      const prior = plans.find(row => row.legIndex === stage - 1)
      const current = point([plan.currentLng, plan.currentLat])
      const oldGuides = (prior?.intendedGuideCoordinates ?? []).map(point).filter(Boolean) as LngLat[]
      const home = point((prior?.intendedRemainingPoints ?? []).at?.(-1))
      const fixtureStart = FIXTURES.find(value => value.name === candidate.fixture)?.body.start
      const startPoint: LngLat = home ?? [fixtureStart!.lng, fixtureStart!.lat]
      const originalFuture = oldGuides.slice(1)
      if (current) replanDelta = remaining - pathCrow([current, ...originalFuture, startPoint])
      occurrences.push({ fixture: candidate.fixture, candidateId: candidate.candidateId, outcome, mechanism: 'replanning', stage, delta: replanDelta, controllable: stage < plan.cornerCount })
    }
    stages.push({ stage, effectiveScale: used + remaining, retention: (used + remaining) / initial, replanDelta })

    const result = legResults.find(row => row.legIndex === stage)
    if (!result) continue
    const baseGuides = (plan.intendedGuideCoordinates ?? []).map(point).filter(Boolean) as LngLat[]
    const from = point([plan.currentLng, plan.currentLat])
    const selectedAttemptEvent = events.find(row => row.kind === 'leg-attempt-result' && row.legIndex === stage && row.attempt === result.selectedAttempt)
    const selectedTarget = point([result.intendedTargetLng, result.intendedTargetLat])
    const endpoint = point([selectedAttemptEvent?.routedEndpointLng, selectedAttemptEvent?.routedEndpointLat])
    if (from && selectedTarget && endpoint && selectedAttemptEvent) {
      const future = baseGuides.slice(1)
      const fixtureStart = FIXTURES.find(value => value.name === candidate.fixture)!.body.start
      const home: LngLat = [fixtureStart.lng, fixtureStart.lat]
      const selectedSkeleton = pathCrow([from, selectedTarget, ...future, home])
      const retryDelta = selectedSkeleton - remaining
      if (Number(result.selectedAttempt) > 0) occurrences.push({ fixture: candidate.fixture, candidateId: candidate.candidateId, outcome, mechanism: 'retry', stage, delta: retryDelta, controllable: stage < plan.cornerCount - 1 })
      const endpointRemainder = pathCrow([endpoint, ...future, home])
      let routingDelta = Number(selectedAttemptEvent.routedDistance) + endpointRemainder - selectedSkeleton
      const selectedFixups = events.filter(row => row.legIndex === stage && row.legAttempt === result.selectedAttempt && row.kept && ['leg-budget', 'spike'].includes(row.kind))
      routingDelta -= selectedFixups.reduce((sum, row) => sum + Number(row.delta ?? Number(row.after) - Number(row.before)), 0)
      const mechanism = stage === plan.cornerCount ? 'closure' : 'routing-displacement'
      occurrences.push({ fixture: candidate.fixture, candidateId: candidate.candidateId, outcome, mechanism, stage, delta: routingDelta, controllable: stage < plan.cornerCount - 1 })
    }
  }
  for (const event of events.filter(row => {
    if (!row.kept || !['leg-budget', 'spike', 'join-pullback'].includes(row.kind)) return false
    if (row.kind === 'join-pullback') return true
    const result = legResults.find(value => value.legIndex === row.legIndex)
    return result?.selectedAttempt === row.legAttempt
  })) {
    occurrences.push({ fixture: candidate.fixture, candidateId: candidate.candidateId, outcome, mechanism: event.kind, stage: Number(event.legIndex), delta: Number(event.delta ?? Number(event.after) - Number(event.before)), controllable: Number(event.legIndex) < Number(event.cornerCount) - 1 })
  }
  if (finalize && finite(finalize.trimDelta)) occurrences.push({ fixture: candidate.fixture, candidateId: candidate.candidateId, outcome, mechanism: 'final-trim', stage: Number(candidate.cornerCount) + 1, delta: finalize.trimDelta, controllable: false })
  const attempts = events.filter(row => row.kind === 'leg-attempt-result')
  const endpoint = attempts.map(row => ({ stage: row.legIndex, attempt: row.attempt, intendedReach: row.intendedReach, achievedReach: row.achievedCrowReach, guideMiss: row.guideMissDistance, relaxed: row.relaxed }))
  candidateData.push({ id, fixture: candidate.fixture, candidateId: candidate.candidateId, outcome, target: candidate.target, finalDistance: candidate.distance, finalError: candidate.distance - candidate.target, initial, stages, endpoint })
}

const mechanisms = [...new Set(occurrences.map(row => row.mechanism))].sort()
const outcomes = ['PASS', 'TOO_SHORT', 'TOO_LONG', 'OTHER_QUALITY_FAILURE']
const lines: string[] = []
const say = (line = '') => { lines.push(line); console.log(line) }
say(`# Phase 6 perimeter attribution — ${corpusArg}`)
say(`\n${candidateData.length} completed candidates; ${occurrences.length} attributed transformations.`)
say('\n## Outcome counts\n')
say('| outcome | candidates |')
say('|---|---:|')
for (const outcome of outcomes) say(`| ${outcome} | ${candidateData.filter(row => row.outcome === outcome).length} |`)

say('\n## Per-leg intended versus achieved endpoint progress\n')
say('| fixture | outcome | attempts | median intended reach | median achieved reach | median guide miss | p90 guide miss | retries | relaxed |')
say('|---|---|---:|---:|---:|---:|---:|---:|---:|')
for (const fixture of FIXTURES.map(value => value.name)) for (const outcome of outcomes) {
  const attemptRows = candidateData.filter(row => row.fixture === fixture && row.outcome === outcome).flatMap(row => row.endpoint)
  if (!attemptRows.length) continue
  say(`| ${fixture} | ${outcome} | ${attemptRows.length} | ${percentile(attemptRows.map(row => row.intendedReach), .5).toFixed(0)} | ${percentile(attemptRows.map(row => row.achievedReach), .5).toFixed(0)} | ${percentile(attemptRows.map(row => row.guideMiss), .5).toFixed(0)} | ${percentile(attemptRows.map(row => row.guideMiss), .9).toFixed(0)} | ${attemptRows.filter(row => row.attempt > 0).length} | ${attemptRows.filter(row => row.relaxed).length} |`)
}

say('\n## Mechanism attribution by outcome\n')
say('| mechanism | outcome | triggers | mean delta | median delta | p75 abs | p90 abs | total delta | controllable |')
say('|---|---|---:|---:|---:|---:|---:|---:|---:|')
for (const mechanism of mechanisms) for (const outcome of outcomes) {
  const selected = occurrences.filter(row => row.mechanism === mechanism && row.outcome === outcome)
  if (!selected.length) continue
  const deltas = selected.map(row => row.delta)
  const absolute = deltas.map(Math.abs)
  say(`| ${mechanism} | ${outcome} | ${selected.length} | ${(deltas.reduce((a, b) => a + b, 0) / deltas.length).toFixed(0)} | ${percentile(deltas, .5).toFixed(0)} | ${percentile(absolute, .75).toFixed(0)} | ${percentile(absolute, .9).toFixed(0)} | ${deltas.reduce((a, b) => a + b, 0).toFixed(0)} | ${selected.filter(row => row.controllable).length} |`)
}

say('\n### Mechanism attribution by fixture\n')
say('| fixture | mechanism | triggers | median delta | total delta |')
say('|---|---|---:|---:|---:|')
for (const fixture of FIXTURES.map(value => value.name)) for (const mechanism of mechanisms) {
  const selected = occurrences.filter(row => row.fixture === fixture && row.mechanism === mechanism)
  if (!selected.length) continue
  say(`| ${fixture} | ${mechanism} | ${selected.length} | ${percentile(selected.map(row => row.delta), .5).toFixed(0)} | ${selected.reduce((sum, row) => sum + row.delta, 0).toFixed(0)} |`)
}

say('\n### Mechanism attribution by leg stage\n')
say('| stage | mechanism | triggers | median delta | p90 absolute delta |')
say('|---:|---|---:|---:|---:|')
for (const stage of [...new Set(occurrences.map(row => row.stage))].sort((a, b) => a - b)) for (const mechanism of mechanisms) {
  const selected = occurrences.filter(row => row.stage === stage && row.mechanism === mechanism)
  if (!selected.length) continue
  say(`| ${stage} | ${mechanism} | ${selected.length} | ${percentile(selected.map(row => row.delta), .5).toFixed(0)} | ${percentile(selected.map(row => Math.abs(row.delta)), .9).toFixed(0)} |`)
}

say('\n## Peel contrast\n')
say('| fixture | candidates | median guide miss | p90 guide miss | retry attempts / candidate | kept leg-budget / candidate | kept pullbacks / candidate | negative replan metres / candidate | median closure delta | short-backtrack retry triggers |')
say('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
for (const fixture of ['douglas-5km', 'douglas-3km', 'peel-5km', 'onchan-5km']) {
  const selected = candidateData.filter(row => row.fixture === fixture)
  const endpoints = selected.flatMap(row => row.endpoint)
  const candidateEvents = decisions.filter(row => row.fixture === fixture)
  const perCandidate = (kind: string) => occurrences.filter(row => row.fixture === fixture && row.mechanism === kind).length / Math.max(1, selected.length)
  const negativeReplan = occurrences.filter(row => row.fixture === fixture && row.mechanism === 'replanning' && row.delta < 0).reduce((sum, row) => sum - row.delta, 0) / Math.max(1, selected.length)
  const closures = occurrences.filter(row => row.fixture === fixture && row.mechanism === 'closure').map(row => row.delta)
  say(`| ${fixture} | ${selected.length} | ${percentile(endpoints.map(row => row.guideMiss), .5).toFixed(0)} | ${percentile(endpoints.map(row => row.guideMiss), .9).toFixed(0)} | ${(endpoints.filter(row => row.attempt > 0).length / Math.max(1, selected.length)).toFixed(2)} | ${perCandidate('leg-budget').toFixed(2)} | ${perCandidate('join-pullback').toFixed(2)} | ${negativeReplan.toFixed(0)} | ${percentile(closures, .5).toFixed(0)} | ${candidateEvents.filter(row => row.kind === 'leg-attempt' && row.shortBacktrack).length} |`)
}

say('\n## Retention curves\n')
say('Retention is `(actual routed metres already committed + current remaining crow skeleton) / initial crow skeleton`. Final uses the post-trim routed distance. It is an effective-scale diagnostic, not a claim that crow and network metres are interchangeable.')
say('\n| outcome | initial | after leg 1 | after leg 2 | after leg 3 | before closure | final |')
say('|---|---:|---:|---:|---:|---:|---:|')
for (const outcome of ['PASS', 'TOO_SHORT', 'TOO_LONG']) {
  const selected = candidateData.filter(row => row.outcome === outcome)
  const at = (stage: number) => percentile(selected.map(row => row.stages.find((value: any) => value.stage === stage)?.retention).filter(finite), .5)
  const before = percentile(selected.map(row => row.stages.at(-1)?.retention).filter(finite), .5)
  const final = percentile(selected.map(row => row.finalDistance / row.initial), .5)
  say(`| ${outcome} | 1.000 | ${at(1).toFixed(3)} | ${at(2).toFixed(3)} | ${at(3).toFixed(3)} | ${before.toFixed(3)} | ${final.toFixed(3)} |`)
}
say('\n### Retention by fixture and outcome (final median)\n')
say('| fixture | pass | too short | too long |')
say('|---|---:|---:|---:|')
for (const fixture of FIXTURES.map(value => value.name).filter(name => !name.startsWith('wp-'))) {
  const cell = (outcome: string) => percentile(candidateData.filter(row => row.fixture === fixture && row.outcome === outcome).map(row => row.finalDistance / row.initial), .5).toFixed(3)
  say(`| ${fixture} | ${cell('PASS')} | ${cell('TOO_SHORT')} | ${cell('TOO_LONG')} |`)
}

say('\n## Candidate waterfall examples\n')
for (const wanted of ['PASS', 'TOO_SHORT', 'TOO_LONG']) {
  const candidate = candidateData.find(row => row.outcome === wanted && (wanted !== 'TOO_SHORT' || row.fixture === 'peel-5km')) ?? candidateData.find(row => row.outcome === wanted)
  if (!candidate) continue
  say(`### ${candidate.id} — ${wanted}`)
  say(`\nInitial crow skeleton ${candidate.initial.toFixed(0)} m; final routed/trimmed distance ${candidate.finalDistance.toFixed(0)} m.`)
  say('\n| stage | effective scale before leg | retention | replan delta |')
  say('|---:|---:|---:|---:|')
  for (const stage of candidate.stages) say(`| ${stage.stage} | ${stage.effectiveScale.toFixed(0)} | ${stage.retention.toFixed(3)} | ${stage.replanDelta.toFixed(0)} |`)
  const own = occurrences.filter(row => `${row.fixture}:${row.candidateId}` === candidate.id)
  say(`\nTransformation deltas: ${own.map(row => `${row.mechanism}@${row.stage} ${row.delta >= 0 ? '+' : ''}${row.delta.toFixed(0)} m`).join('; ')}.`)
}

say('\n## Controllability ranking\n')
say('Score = total absolute delta × mean early-weight × controllable-trigger share. Early weight is remaining outward legs divided by corner count; it is zero at/after closure.')
say('\n| rank | mechanism | absolute metres | mean early weight | controllable share | score |')
say('|---:|---|---:|---:|---:|---:|')
const ranking = mechanisms.map(mechanism => {
  const selected = occurrences.filter(row => row.mechanism === mechanism)
  const absolute = selected.reduce((sum, row) => sum + Math.abs(row.delta), 0)
  const weights = selected.map(row => Math.max(0, (Number(groups.get(`${row.fixture}:${row.candidateId}`)?.find(event => event.kind === 'candidate-start')?.cornerCount ?? 3) - row.stage) / Number(groups.get(`${row.fixture}:${row.candidateId}`)?.find(event => event.kind === 'candidate-start')?.cornerCount ?? 3)))
  const early = weights.reduce((a, b) => a + b, 0) / Math.max(1, weights.length)
  const share = selected.filter(row => row.controllable).length / Math.max(1, selected.length)
  return { mechanism, absolute, early, share, score: absolute * early * share }
}).sort((a, b) => b.score - a.score)
ranking.forEach((row, index) => say(`| ${index + 1} | ${row.mechanism} | ${row.absolute.toFixed(0)} | ${row.early.toFixed(2)} | ${pct(row.share * 100, 100)} | ${row.score.toFixed(0)} |`))

say('\n## Conservative offline correction ceiling\n')
say('A mechanism recovers a distance failure only when its signed cumulative pre-closure delta opposes the final error, reaches the accepted-band deficit, and the required correction is no more than 30% of the remaining outward planned crow reach at the earliest matching event. This is an oracle ceiling, not a production prediction.')
const failures = candidateData.filter(row => ['TOO_SHORT', 'TOO_LONG'].includes(row.outcome))
const recovered = new Map<string, Set<string>>()
for (const mechanism of [...mechanisms, 'combined-cumulative-deficit']) {
  const set = new Set<string>()
  for (const candidate of failures) {
    const desiredSign = candidate.outcome === 'TOO_SHORT' ? -1 : 1
    const needed = candidate.outcome === 'TOO_SHORT' ? candidate.target * (1 - MAX_DISTANCE_ERROR) - candidate.finalDistance : candidate.finalDistance - candidate.target * (1 + MAX_DISTANCE_ERROR)
    const own = occurrences.filter(row => `${row.fixture}:${row.candidateId}` === candidate.id && row.controllable && (mechanism === 'combined-cumulative-deficit' || row.mechanism === mechanism) && Math.sign(row.delta) === desiredSign)
    const magnitude = own.reduce((sum, row) => sum + Math.abs(row.delta), 0)
    const earliest = own.reduce((min, row) => Math.min(min, row.stage), Infinity)
    const plan = candidate.stages.find((row: any) => row.stage === earliest)
    const remainingOutward = plan ? Math.max(0, plan.effectiveScale - Number(groups.get(candidate.id)?.find(row => row.kind === 'leg-plan' && row.legIndex === earliest)?.distanceUsedBeforeLeg ?? 0) - Number(groups.get(candidate.id)?.find(row => row.kind === 'leg-plan' && row.legIndex === earliest)?.straightLineDistanceHome ?? 0)) : 0
    if (own.length && magnitude >= needed && needed <= remainingOutward * .3) set.add(candidate.id)
  }
  recovered.set(mechanism, set)
}
say('\n| mechanism | failures recoverable | unique recoveries |')
say('|---|---:|---:|')
for (const [mechanism, set] of recovered) {
  const unique = [...set].filter(id => [...recovered].filter(([other]) => other !== mechanism && other !== 'combined-cumulative-deficit').every(([, values]) => !values.has(id))).length
  say(`| ${mechanism} | ${set.size} / ${failures.length} (${pct(set.size, failures.length)}) | ${unique} |`)
}
const combined = recovered.get('combined-cumulative-deficit')!.size
say('\n### Combined recovery by fixture\n')
say('| fixture | failures | recoverable |')
say('|---|---:|---:|')
const combinedFixtures = new Set<string>()
for (const fixture of FIXTURES.map(value => value.name)) {
  const selected = failures.filter(row => row.fixture === fixture)
  if (!selected.length) continue
  const count = selected.filter(row => recovered.get('combined-cumulative-deficit')!.has(row.id)).length
  if (!fixture.startsWith('wp-') && count > 0) combinedFixtures.add(fixture)
  say(`| ${fixture} | ${selected.length} | ${count} (${pct(count, selected.length)}) |`)
}
const passesGate = combined / Math.max(1, failures.length) >= .4 && combinedFixtures.size > 1
say(`\n**Gate: ${passesGate ? 'GO' : 'NO-GO'}** — combined conservative recovery is ${combined}/${failures.length} (${pct(combined, failures.length)}) across ${combinedFixtures.size} non-waypoint fixtures; the production threshold is 40% and the result must be generic.`)

writeFileSync(new URL('analysis.md', results), lines.join('\n') + '\n')
writeFileSync(new URL('analysis.json', results), JSON.stringify({ corpus: corpusArg, candidateData, occurrences, ranking, recovery: Object.fromEntries([...recovered].map(([name, set]) => [name, [...set]])) }, null, 2) + '\n')
