/**
 * Phase 2 §25 and §26: the gate. Whole Looper generations, not legs.
 *
 * Every engine-level configuration this phase tested returns the same routes,
 * so what separates them is time — and the only time that matters is the time
 * a walker waits. A leg microbenchmark cannot answer that: the generator runs
 * six legs at once, so a change that halves a leg does not halve anything the
 * walker sees, and a change worth 5% of GraphHopper's own work is worth 5% of
 * a fifth of what Looper spends.
 *
 * Each engine gets its own route service, identical but for the URL, and each
 * fixture is run REPEATS times after a warm-up. The median is reported because
 * one run of `peel-5km` is not a measurement: the diversity-aware early stop
 * races concurrent candidates, so the call count moves between runs even on
 * one engine while the walks stay byte-identical.
 */
import { writeFileSync } from 'node:fs'
import { FIXTURES, hashRoute } from './fixtures.mjs'
import { startService } from './service.mjs'
import { percentiles } from '../../src/loops/metrics.js'

const REPEATS = Number(process.env.REPEATS ?? 9)
const PORT = 8804

const ENGINES = [
  { label: 'P0 baseline — 16 prepared / 8 active', url: process.env.GH_BASE ?? 'http://localhost:8991' },
  { label: 'P2 64 prepared / 12 active', url: process.env.GH_ALT ?? 'http://localhost:8992' },
]

const results: Record<string, any[]> = {}
for (const engine of ENGINES) {
  console.log(`\n=== ${engine.label} (${engine.url}) ===`)
  const service = await startService(PORT, { GRAPHHOPPER_IOM_URL: engine.url, GRAPHHOPPER_ENGLAND_URL: engine.url })
  const rows: any[] = []
  try {
    for (const fixture of FIXTURES) {
      await service.generate(fixture.body)   // warm the service and the engine
      const runs: any[] = []
      for (let i = 0; i < REPEATS; i++) runs.push(await service.generate(fixture.body))
      const wall = runs.map(r => r.wallMs)
      const p = percentiles(wall)
      const last = runs[runs.length - 1].payload
      const routes = (last.routes ?? []).map((r: any) => ({
        distanceMeters: r.distanceMeters,
        quality: r.quality?.score ?? r.score ?? null,
        repeatedFraction: r.quality?.repeatedFraction ?? null,
        geometryHash: hashRoute(r.geometry?.coordinates ?? r.coordinates ?? []),
      }))
      const calls = runs.map(r => r.payload?.diagnostics?.metrics?.graphhopperCalls ?? 0)
      const engineMs = runs.map(r => r.payload?.diagnostics?.metrics?.engineMs ?? 0)
      const visited = runs.map(r => r.payload?.diagnostics?.metrics?.visitedNodes ?? 0)
      rows.push({
        name: fixture.name, medianMs: p.median, p95Ms: p.p95, maxMs: p.max, minMs: Math.min(...wall),
        routes, callRange: [Math.min(...calls), Math.max(...calls)],
        medianEngineMs: percentiles(engineMs).median, medianVisited: percentiles(visited).median,
      })
      console.log(`${fixture.name.padEnd(14)} median ${String(p.median).padStart(5)}ms  p95 ${String(p.p95).padStart(5)}ms  routes=${routes.length}  calls ${Math.min(...calls)}–${Math.max(...calls)}  visited ${percentiles(visited).median.toLocaleString()}`)
    }
  } finally {
    await service.stop()
  }
  results[engine.label] = rows
}

writeFileSync(new URL('results/end-to-end.json', import.meta.url), JSON.stringify({ repeats: REPEATS, results }, null, 1))

const [a, b] = ENGINES.map(e => results[e.label])
console.log('\n| fixture | P0 median ms | P2 median ms | change | routes identical? |')
console.log('|---|---:|---:|---:|---|')
let differ = 0
for (let i = 0; i < FIXTURES.length; i++) {
  const same = JSON.stringify(a[i].routes) === JSON.stringify(b[i].routes)
  if (!same) differ++
  const change = ((b[i].medianMs - a[i].medianMs) / a[i].medianMs) * 100
  console.log(`| ${a[i].name} | ${a[i].medianMs} | ${b[i].medianMs} | ${change >= 0 ? '+' : ''}${change.toFixed(1)}% | ${same ? 'yes' : 'NO'} |`)
}
const total = (rows: any[]) => rows.reduce((s, r) => s + r.medianMs, 0)
console.log(`| **total** | **${total(a)}** | **${total(b)}** | **${(((total(b) - total(a)) / total(a)) * 100).toFixed(1)}%** | ${differ ? `${differ} differ` : 'all identical'} |`)
