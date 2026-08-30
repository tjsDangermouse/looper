/**
 * Phase 3A §19, §33: one generation per fixture, traced call by call.
 *
 * The same six production probes Phase 2 captured, run at the configuration
 * this phase retained, with the per-call boundary trace on. Each record now
 * carries what the call cost *where* — queueing for a slot, the round trip,
 * the engine's own `hopper.route` — alongside which corridor set it named and
 * whether the answer had already been given.
 *
 * That last part is for the phase after this one. Phase 2 established that the
 * number to attack is 1,863 calls and that a third of them are fix-ups of legs
 * already routed once. Deciding which of those are avoidable needs to know,
 * per call, what it was for, what it carried and what it cost, and this is
 * where that record comes from.
 */
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { FIXTURES, hashRoute } from '../phase2/fixtures.mjs'
import { startService } from '../phase2/service.mjs'
import { warm } from './warm.mjs'

const OUT = new URL('corpus/', import.meta.url)
rmSync(OUT, { recursive: true, force: true })
mkdirSync(OUT, { recursive: true })

const PORT = 8807
const GH_URL = process.env.GH_URL ?? 'http://localhost:8991'
await warm(GH_URL)

const summary: any[] = []
for (const fixture of FIXTURES) {
  const trace = new URL(`corpus/${fixture.name}.jsonl`, import.meta.url).pathname
  const service = await startService(PORT, {
    GRAPHHOPPER_IOM_URL: GH_URL, GRAPHHOPPER_ENGLAND_URL: GH_URL,
    LOOPER_MODEL_REGISTRY: 'true', LOOPER_ROUTE_MEMO: 'true',
    LOOPER_TRACE_FILE: trace,
  })
  try {
    await service.generate(fixture.body)   // warm-up; its trace is discarded
    writeFileSync(trace, '')
    const { wallMs, payload, headers } = await service.generate(fixture.body)
    const routes = (payload.routes ?? []).map((r: any) => ({
      distanceMeters: r.distanceMeters,
      quality: r.quality?.score ?? r.score ?? null,
      repeatedFraction: r.quality?.repeatedFraction ?? null,
      geometryHash: hashRoute(r.geometry?.coordinates ?? r.coordinates ?? []),
    }))
    summary.push({
      name: fixture.name, wallMs, routes,
      metrics: payload.diagnostics?.metrics ?? {},
      boundary: JSON.parse(headers.get('x-looper-boundary') ?? '{}'),
    })
    console.log(`${fixture.name.padEnd(14)} ${String(wallMs).padStart(6)}ms  routes=${routes.length}  calls=${payload.diagnostics?.metrics?.graphhopperCalls}`)
  } finally {
    await service.stop()
  }
}
writeFileSync(new URL('capture-summary.json', import.meta.url), JSON.stringify(summary, null, 1))
console.log(`\ncorpus written to ${OUT.pathname}`)
