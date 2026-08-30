/**
 * Phase 3A §25, §26, §27: the gate. Whole Looper generations, not legs.
 *
 * Nothing this phase changes is allowed to change a route, so what separates
 * the stages is time — and the only time that counts is the time a walker
 * waits between asking and being offered three walks. A leg microbenchmark
 * cannot answer that: six legs are in flight at once, so halving a leg does
 * not halve anything the walker sees.
 *
 * Each stage gets its own route service against its own facade, and both are
 * warmed against the whole workload first. The median of REPEATS is reported
 * because one run of `peel-5km` is not a measurement — the diversity-aware
 * early stop races concurrent candidates, so the call count moves between runs
 * on one engine while the walks stay byte-identical.
 */
import { writeFileSync } from 'node:fs'
import { FIXTURES, hashRoute } from '../phase2/fixtures.mjs'
import { startService } from '../phase2/service.mjs'
import { percentiles } from '../../src/loops/metrics.js'
import { warm } from './warm.mjs'

const REPEATS = Number(process.env.REPEATS ?? 9)
const PORT = 8805
const REUSE = process.env.GH_REUSE ?? 'http://localhost:8991'
const REBUILD = process.env.GH_REBUILD ?? 'http://localhost:8992'

/**
 * The stages, in the order the brief asks for them. `P1` and `P2` differ only
 * in the facade: the same registry, with the weighting cache off and on. That
 * is deliberate — it is the only way to say what naming a corridor saves on
 * the wire and what it saves inside GraphHopper without inferring one from the
 * other.
 */
const STAGES: Array<{ label: string; url: string; env: Record<string, string> }> = [
  { label: 'P0 baseline — model in every body', url: REUSE, env: { LOOPER_MODEL_REGISTRY: 'false', LOOPER_ROUTE_MEMO: 'false' } },
  { label: 'P1 + model registry (weighting rebuilt)', url: REBUILD, env: { LOOPER_MODEL_REGISTRY: 'true', LOOPER_ROUTE_MEMO: 'false' } },
  { label: 'P2 + weighting reuse', url: REUSE, env: { LOOPER_MODEL_REGISTRY: 'true', LOOPER_ROUTE_MEMO: 'false' } },
  { label: 'P3 + exact route memo', url: REUSE, env: { LOOPER_MODEL_REGISTRY: 'true', LOOPER_ROUTE_MEMO: 'true' } },
  { label: 'memo alone, no registry', url: REUSE, env: { LOOPER_MODEL_REGISTRY: 'false', LOOPER_ROUTE_MEMO: 'true' } },
].filter(stage => !process.env.ONLY || process.env.ONLY.split(',').some(prefix => stage.label.startsWith(prefix)))

/**
 * How many times the whole stage list is run, alternating.
 *
 * One round is not enough and the reason is specific: each stage gets a fresh
 * route service, and two runs of the *same* stage in different services differ
 * by more than any change this phase makes. Alternating and taking the median
 * across rounds measures the change rather than which service happened to warm
 * up better.
 */
const ROUNDS = Number(process.env.ROUNDS ?? 1)

for (const url of new Set(STAGES.map(s => s.url))) {
  process.stdout.write(`warming ${url}… `)
  await warm(url)
  console.log('done')
}

const rounds: Array<Record<string, any[]>> = []
for (let round = 0; round < ROUNDS; round++) {
if (ROUNDS > 1) console.log(`\n———————————————————————— round ${round + 1} of ${ROUNDS}`)
const results: Record<string, any[]> = {}
for (const stage of STAGES) {
  console.log(`\n=== ${stage.label} (${stage.url}) ===`)
  const service = await startService(PORT, { ...stage.env, GRAPHHOPPER_IOM_URL: stage.url, GRAPHHOPPER_ENGLAND_URL: stage.url })
  const rows: any[] = []
  try {
    for (const fixture of FIXTURES) {
      await service.generate(fixture.body)   // warm the service itself
      const runs: any[] = []
      for (let i = 0; i < REPEATS; i++) runs.push(await service.generate(fixture.body))
      const wall = runs.map(r => r.wallMs)
      const p = percentiles(wall)
      const last = runs[runs.length - 1]
      const routes = (last.payload.routes ?? []).map((r: any) => ({
        distanceMeters: r.distanceMeters,
        quality: r.quality?.score ?? r.score ?? null,
        repeatedFraction: r.quality?.repeatedFraction ?? null,
        geometryHash: hashRoute(r.geometry?.coordinates ?? r.coordinates ?? []),
      }))
      const boundary = runs.map(r => JSON.parse(r.headers.get('x-looper-boundary') ?? '{}'))
      const median = (pick: (b: any) => number) => percentiles(boundary.map(pick)).median
      const calls = runs.map(r => r.payload?.diagnostics?.metrics?.graphhopperCalls ?? 0)
      rows.push({
        name: fixture.name, medianMs: p.median, p95Ms: p.p95, minMs: Math.min(...wall),
        routes, callRange: [Math.min(...calls), Math.max(...calls)],
        medianEngineMs: percentiles(runs.map(r => r.payload?.diagnostics?.metrics?.engineMs ?? 0)).median,
        boundary: {
          calls: median(b => b.calls ?? 0), routed: median(b => b.routed ?? 0),
          memoHits: median(b => b.memoHits ?? 0), memoJoins: median(b => b.memoJoins ?? 0),
          handleCalls: median(b => b.handleCalls ?? 0),
          areaRegistrations: median(b => b.areaRegistrations ?? 0),
          modelDefinitions: median(b => b.modelDefinitions ?? 0),
          modelReferences: median(b => b.modelReferences ?? 0),
          rediscoveries: median(b => b.rediscoveries ?? 0),
          requestKB: Math.round(median(b => b.requestBytes ?? 0) / 1024),
          responseKB: Math.round(median(b => b.responseBytes ?? 0) / 1024),
          queueMs: median(b => b.queueMs ?? 0), transportMs: median(b => b.transportMs ?? 0),
          parseMs: median(b => b.parseMs ?? 0), javaRouteMs: median(b => b.javaRouteMs ?? 0),
          javaDispatchMs: median(b => b.javaDispatchMs ?? 0), javaSerializeMs: median(b => b.javaSerializeMs ?? 0),
        },
      })
      const b = rows[rows.length - 1].boundary
      console.log(`${fixture.name.padEnd(14)} median ${String(p.median).padStart(5)}ms  routes=${routes.length}  calls ${Math.min(...calls)}–${Math.max(...calls)}  routed=${b.routed} memo=${b.memoHits}+${b.memoJoins}  req=${b.requestKB}KB  gh=${b.javaRouteMs}ms`)
    }
  } finally {
    await service.stop()
  }
  results[stage.label] = rows
}
rounds.push(results)
}

/** The median round per fixture per stage, so one unlucky service cannot decide. */
const results: Record<string, any[]> = {}
for (const stage of STAGES) {
  results[stage.label] = FIXTURES.map((fixture, index) => {
    const across = rounds.map(round => round[stage.label][index])
    const medianMs = percentiles(across.map(row => row.medianMs)).median
    return { ...across[0], medianMs, perRound: across.map(row => row.medianMs) }
  })
}

writeFileSync(new URL('results/end-to-end.json', import.meta.url), JSON.stringify({ repeats: REPEATS, rounds: ROUNDS, results, raw: rounds }, null, 1))

const base = results[STAGES[0].label]
console.log(`\n| fixture | ${STAGES.map(s => s.label.split(' ')[0]).join(' | ')} |`)
console.log(`|---|${STAGES.map(() => '---:').join('|')}|`)
for (let i = 0; i < FIXTURES.length; i++) {
  console.log(`| ${base[i].name} | ${STAGES.map(s => results[s.label][i].medianMs).join(' | ')} |`)
}
const total = (rows: any[]) => rows.reduce((sum, row) => sum + row.medianMs, 0)
console.log(`| **total** | ${STAGES.map(s => `**${total(results[s.label])}**`).join(' | ')} |`)
console.log(`| change | ${STAGES.map(s => `${(((total(results[s.label]) - total(base)) / total(base)) * 100).toFixed(1)}%`).join(' | ')} |`)

if (ROUNDS > 1) {
  console.log(`\nper round, so the spread of one configuration against itself is visible:`)
  for (const stage of STAGES) {
    const totals = rounds.map(round => round[stage.label].reduce((sum, row) => sum + row.medianMs, 0))
    const spread = ((Math.max(...totals) - Math.min(...totals)) / Math.min(...totals)) * 100
    console.log(`  ${stage.label.padEnd(42)} ${totals.join(' / ')}   spread ${spread.toFixed(1)}%`)
  }
}

console.log('\nroute identity against P0:')
for (const stage of STAGES.slice(1)) {
  const differ = FIXTURES.filter((_, i) => JSON.stringify(results[stage.label][i].routes) !== JSON.stringify(base[i].routes))
  console.log(`  ${stage.label}: ${differ.length ? `DIFFERS on ${differ.map(f => f.name).join(', ')}` : 'identical on all six'}`)
}
