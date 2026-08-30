/**
 * Phase 3A §1, §2, §11, §12: what the boundary carries, and how much of it is
 * a restatement of something already said.
 *
 * Every number here is counted *per generation*, not across the corpus. The
 * registry this phase adds is scoped to one `generateLoops` request, so a
 * corridor repeated in a different fixture is not a repeat it can do anything
 * about, and counting it as one would overstate the opportunity.
 *
 * The two duplication rates Phase 2 measured are reproduced first, because
 * they are what the design has to answer to and they are easy to conflate:
 * 6.4% of calls repeat a whole request, and 51% of avoidance calls repeat a
 * model. They are different claims at very different scales.
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { buildRouteBody } from '../../src/graphhopper.js'

const FIXTURES = ['douglas-3km', 'douglas-5km', 'onchan-5km', 'peel-5km', 'wp-one', 'wp-two']
const dir = new URL('../phase2/corpus/', import.meta.url)

type Call = { purpose: string; class: string; points: [number, number][]; model: any; ms: number }
const sha = (s: string) => createHash('sha1').update(s).digest('hex').slice(0, 16)
const load = (fixture: string): Call[] => readFileSync(new URL(`${fixture}.jsonl`, dir), 'utf8')
  .trim().split('\n').filter(Boolean).map(line => JSON.parse(line)).filter((call: any) => call.points)

/** The corridor set alone, with the strength deliberately left out of it. */
const corridorKey = (model: any) => (model?.areas ? sha(JSON.stringify(model.areas)) : null)
const modelKey = (model: any) => (model ? sha(JSON.stringify(model)) : null)
const multiplierOf = (model: any) => model?.priority?.[0]?.multiply_by ?? null

// ---------------------------------------------------------------- duplication

const dupRows: any[] = []
const dupTotals = { calls: 0, exact: 0, avoidance: 0, models: 0, corridorSets: 0, bothStrengths: 0 }
for (const fixture of FIXTURES) {
  const calls = load(fixture)
  const exact = new Set<string>()
  const models = new Set<string>()
  const corridors = new Map<string, Set<string>>()
  let duplicates = 0
  let avoidance = 0
  for (const call of calls) {
    const key = sha(JSON.stringify([call.points, call.model ?? null]))
    if (exact.has(key)) duplicates++
    exact.add(key)
    const model = modelKey(call.model)
    if (!model) continue
    avoidance++
    models.add(model)
    const corridor = corridorKey(call.model)!
    if (!corridors.has(corridor)) corridors.set(corridor, new Set())
    corridors.get(corridor)!.add(String(multiplierOf(call.model)))
  }
  const bothStrengths = [...corridors.values()].filter(strengths => strengths.size > 1).length
  dupRows.push({ fixture, calls: calls.length, duplicates, avoidance, models: models.size, corridorSets: corridors.size, bothStrengths })
  dupTotals.calls += calls.length; dupTotals.exact += duplicates; dupTotals.avoidance += avoidance
  dupTotals.models += models.size; dupTotals.corridorSets += corridors.size; dupTotals.bothStrengths += bothStrengths
}

console.log('| fixture | calls | whole requests repeated | % | avoidance calls | distinct models | model reuse % | distinct corridor sets | sets used at both strengths |')
console.log('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
for (const row of dupRows) {
  console.log(`| ${row.fixture} | ${row.calls} | ${row.duplicates} | ${((row.duplicates / row.calls) * 100).toFixed(1)}% | ${row.avoidance} | ${row.models} | ${row.avoidance ? (((row.avoidance - row.models) / row.avoidance) * 100).toFixed(1) : '0.0'}% | ${row.corridorSets} | ${row.bothStrengths} |`)
}
console.log(`| **total** | **${dupTotals.calls}** | **${dupTotals.exact}** | **${((dupTotals.exact / dupTotals.calls) * 100).toFixed(1)}%** | **${dupTotals.avoidance}** | **${dupTotals.models}** | **${(((dupTotals.avoidance - dupTotals.models) / dupTotals.avoidance) * 100).toFixed(1)}%** | **${dupTotals.corridorSets}** | **${dupTotals.bothStrengths}** |`)

// ------------------------------------------------------- the polygon, not the set

/**
 * Why the unit of registration is one corridor and not one corridor set.
 *
 * A model is the ground walked *so far*, so the model for leg four contains
 * the model for leg three plus one new polygon. Registering whole sets would
 * therefore re-send almost every polygon on almost every new set — 738 sets
 * against 658 polygons says exactly that, and it is the difference between
 * sending the corridors once and sending them once per leg they survive into.
 */
let areaRefs = 0
let uniqueAreas = 0
let areaBytes = 0
let uniqueAreaBytes = 0
for (const fixture of FIXTURES) {
  const seen = new Set<string>()
  for (const call of load(fixture)) {
    for (const feature of call.model?.areas?.features ?? []) {
      const geometry = JSON.stringify(feature.geometry)
      areaRefs++
      areaBytes += geometry.length
      const key = sha(geometry)
      if (!seen.has(key)) { seen.add(key); uniqueAreas++; uniqueAreaBytes += geometry.length }
    }
  }
}
console.log(`\ncorridor polygons named across the six generations: ${areaRefs} references to ${uniqueAreas} distinct polygons (${((1 - uniqueAreas / areaRefs) * 100).toFixed(1)}% repeated)`)
console.log(`the same, in bytes: ${(areaBytes / 1024 / 1024).toFixed(2)} MB sent today, ${(uniqueAreaBytes / 1024 / 1024).toFixed(2)} MB if each polygon were sent once`)

// ------------------------------------------------------------------- payload

/** The protocol as built: one registration per polygon, one per model, then a name. */
function measure(fixture: string) {
  const calls = load(fixture)
  const sentAreas = new Set<string>()
  const sentModels = new Set<string>()
  let before = 0
  let afterFine = 0
  let afterCoarse = 0
  const sentSets = new Set<string>()
  const byClass = new Map<string, { calls: number; before: number; after: number }>()
  for (const call of calls) {
    const bodyBefore = JSON.stringify(buildRouteBody(call.points, { profile: 'foot', customModel: call.model ?? undefined }))
    before += bodyBefore.length

    const features = call.model?.areas?.features ?? []
    const areaIds = features.map((feature: any) => `a${sha(JSON.stringify(feature.geometry))}`)
    const register: Record<string, unknown> = {}
    features.forEach((feature: any, index: number) => {
      if (sentAreas.has(areaIds[index])) return
      register[areaIds[index]] = { type: 'Feature', properties: {}, geometry: feature.geometry }
      sentAreas.add(areaIds[index])
    })
    const modelId = modelKey(call.model)
    const handle = !call.model ? undefined
      : modelId && sentModels.has(modelId) ? { generation: 'g', id: modelId }
        : {
          generation: 'g', id: modelId,
          ...(Object.keys(register).length ? { register } : {}),
          define: { areas: areaIds, multiply_by: multiplierOf(call.model), distance_influence: call.model.distance_influence },
        }
    if (modelId) sentModels.add(modelId)
    const bodyAfter = JSON.stringify({ ...buildRouteBody(call.points, { profile: 'foot' }), ...(handle ? { looper_model: handle } : {}) })
    afterFine += bodyAfter.length

    // The same protocol with the whole corridor set as the unit, for contrast.
    const setKey = corridorKey(call.model)
    afterCoarse += !call.model ? bodyBefore.length
      : setKey && sentSets.has(`${setKey}|${multiplierOf(call.model)}`)
        ? JSON.stringify({ ...buildRouteBody(call.points, { profile: 'foot' }), looper_model: { generation: 'g', id: modelId } }).length
        : bodyBefore.length
    if (setKey) sentSets.add(`${setKey}|${multiplierOf(call.model)}`)

    const row = byClass.get(call.class) ?? { calls: 0, before: 0, after: 0 }
    row.calls++; row.before += bodyBefore.length; row.after += bodyAfter.length
    byClass.set(call.class, row)
  }
  return { fixture, calls: calls.length, before, afterFine, afterCoarse, byClass }
}

const payload = FIXTURES.map(measure)
const kb = (n: number) => Math.round(n / 1024).toLocaleString()
console.log('\n| fixture | calls | request KB today | KB, corridor set as the unit | KB, one corridor as the unit | reduction |')
console.log('|---|---:|---:|---:|---:|---:|')
for (const row of payload) {
  console.log(`| ${row.fixture} | ${row.calls} | ${kb(row.before)} | ${kb(row.afterCoarse)} | ${kb(row.afterFine)} | ${(((row.before - row.afterFine) / row.before) * 100).toFixed(1)}% |`)
}
const sum = (pick: (r: typeof payload[number]) => number) => payload.reduce((total, row) => total + pick(row), 0)
console.log(`| **total** | **${dupTotals.calls}** | **${kb(sum(r => r.before))}** | **${kb(sum(r => r.afterCoarse))}** | **${kb(sum(r => r.afterFine))}** | **${(((sum(r => r.before) - sum(r => r.afterFine)) / sum(r => r.before)) * 100).toFixed(1)}%** |`)

const classes = new Map<string, { calls: number; before: number; after: number }>()
for (const row of payload) {
  for (const [klass, value] of row.byClass) {
    const total = classes.get(klass) ?? { calls: 0, before: 0, after: 0 }
    total.calls += value.calls; total.before += value.before; total.after += value.after
    classes.set(klass, total)
  }
}
console.log('\n| request class | calls | mean request bytes today | mean with a handle | reduction |')
console.log('|---|---:|---:|---:|---:|')
for (const [klass, row] of [...classes].sort((a, b) => b[1].calls - a[1].calls)) {
  console.log(`| ${klass} | ${row.calls} | ${Math.round(row.before / row.calls).toLocaleString()} | ${Math.round(row.after / row.calls).toLocaleString()} | ${(((row.before - row.after) / row.before) * 100).toFixed(1)}% |`)
}
console.log(`| **corpus** | **${dupTotals.calls}** | **${Math.round(sum(r => r.before) / dupTotals.calls).toLocaleString()}** | **${Math.round(sum(r => r.afterFine) / dupTotals.calls).toLocaleString()}** | **${(((sum(r => r.before) - sum(r => r.afterFine)) / sum(r => r.before)) * 100).toFixed(1)}%** |`)

writeFileSync(new URL('results/anatomy.json', import.meta.url), JSON.stringify({
  duplication: { rows: dupRows, totals: dupTotals },
  polygons: { references: areaRefs, distinct: uniqueAreas, bytes: areaBytes, distinctBytes: uniqueAreaBytes },
  payload: payload.map(row => ({ fixture: row.fixture, calls: row.calls, before: row.before, afterFine: row.afterFine, afterCoarse: row.afterCoarse })),
  classes: Object.fromEntries(classes),
}, null, 1))
