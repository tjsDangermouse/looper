/**
 * Phase 3A §18: a diagnostic, not a proposal.
 *
 * Looper fans one walker's request out six ways. Phase 2 attributed 55% of
 * what it calls engine time to waiting behind that limit, which is the number
 * most easily misread: six calls in flight means a call's measured latency is
 * mostly a measure of the other five, and that is what makes the suite take
 * two seconds instead of twelve rather than what makes it slow.
 *
 * The sweep is here to understand the six, not to move it. Anything it found
 * would have to return identical walks before it could be considered, and the
 * early stop makes the *call count* legitimately vary with arrival order — so
 * what is asserted is the walks, and the call count is reported.
 */
import { writeFileSync } from 'node:fs'
import { FIXTURES, hashRoute } from '../phase2/fixtures.mjs'
import { startService } from '../phase2/service.mjs'
import { percentiles } from '../../src/loops/metrics.js'
import { warm } from './warm.mjs'

const REPEATS = Number(process.env.REPEATS ?? 7)
const PORT = 8806
const GH_URL = process.env.GH_URL ?? 'http://localhost:8991'
const LEVELS = (process.env.LEVELS ?? '1,2,4,6,8').split(',')

await warm(GH_URL)

const results: Record<string, any[]> = {}
for (const level of LEVELS) {
  const service = await startService(PORT, {
    ROUTING_CONCURRENCY: level,
    LOOPER_MODEL_REGISTRY: 'true',
    LOOPER_ROUTE_MEMO: 'true',
    GRAPHHOPPER_IOM_URL: GH_URL,
    GRAPHHOPPER_ENGLAND_URL: GH_URL,
  })
  const rows: any[] = []
  try {
    for (const fixture of FIXTURES) {
      await service.generate(fixture.body)
      const runs: any[] = []
      for (let i = 0; i < REPEATS; i++) runs.push(await service.generate(fixture.body))
      const p = percentiles(runs.map(r => r.wallMs))
      const boundary = runs.map(r => JSON.parse(r.headers.get('x-looper-boundary') ?? '{}'))
      const calls = runs.map(r => r.payload?.diagnostics?.metrics?.graphhopperCalls ?? 0)
      rows.push({
        name: fixture.name, medianMs: p.median,
        routes: (runs[runs.length - 1].payload.routes ?? []).map((r: any) => ({
          distanceMeters: r.distanceMeters,
          quality: r.quality?.score ?? r.score ?? null,
          geometryHash: hashRoute(r.geometry?.coordinates ?? r.coordinates ?? []),
        })),
        callRange: [Math.min(...calls), Math.max(...calls)],
        queueMs: percentiles(boundary.map(b => b.queueMs ?? 0)).median,
        routed: percentiles(boundary.map(b => b.routed ?? 0)).median,
        engineMs: percentiles(runs.map(r => r.payload?.diagnostics?.metrics?.engineMs ?? 0)).median,
      })
    }
  } finally {
    await service.stop()
  }
  results[level] = rows
  const total = rows.reduce((sum, r) => sum + r.medianMs, 0)
  console.log(`concurrency ${level.padStart(2)}: total ${String(total).padStart(5)} ms   queue ${rows.reduce((s, r) => s + r.queueMs, 0)} ms   engineMs ${rows.reduce((s, r) => s + r.engineMs, 0)}`)
}

writeFileSync(new URL('results/concurrency.json', import.meta.url), JSON.stringify({ repeats: REPEATS, results }, null, 1))

const six = results['6']
console.log(`\n| fixture | ${LEVELS.join(' | ')} |`)
console.log(`|---|${LEVELS.map(() => '---:').join('|')}|`)
for (let i = 0; i < FIXTURES.length; i++) {
  console.log(`| ${FIXTURES[i].name} | ${LEVELS.map(l => results[l][i].medianMs).join(' | ')} |`)
}
const total = (rows: any[]) => rows.reduce((sum, r) => sum + r.medianMs, 0)
console.log(`| **total** | ${LEVELS.map(l => `**${total(results[l])}**`).join(' | ')} |`)
console.log(`| queue ms | ${LEVELS.map(l => results[l].reduce((s: number, r: any) => s + r.queueMs, 0)).join(' | ')} |`)
console.log(`| routed calls | ${LEVELS.map(l => results[l].reduce((s: number, r: any) => s + r.routed, 0)).join(' | ')} |`)
if (six) {
  console.log('\nwalks against six-way:')
  for (const level of LEVELS.filter(l => l !== '6')) {
    const differ = FIXTURES.filter((_, i) => JSON.stringify(results[level][i].routes) !== JSON.stringify(six[i].routes))
    console.log(`  ${level}: ${differ.length ? `DIFFERS on ${differ.map(f => f.name).join(', ')}` : 'identical on all six'}`)
  }
}
