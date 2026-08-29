/**
 * Phase 2 step 1: what the generator actually asks the engine for.
 *
 * Runs the six production-probe fixtures through a real route service pointed
 * at the minimal core, with the engine-call trace on, and writes one JSONL
 * corpus per fixture. Everything downstream — the workload anatomy, the
 * landmark experiments, the algorithm comparison — replays these bodies rather
 * than fixtures picked by hand, so the numbers are about the workload Looper
 * has and not the one a benchmark author imagined.
 *
 * One service per fixture, and each one is warmed with its own fixture before
 * the trace is kept: a corpus is a record of what was asked, and a cold JIT
 * changes how long each answer took but not what was asked, so the second run
 * is the honest one on both counts.
 */
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { FIXTURES, hashRoute } from './fixtures.mjs'
import { startService } from './service.mjs'

const OUT = new URL('corpus/', import.meta.url)
rmSync(OUT, { recursive: true, force: true })
mkdirSync(OUT, { recursive: true })

const PORT = 8803
const GH_URL = process.env.GH_URL ?? 'http://localhost:8991'
const ENGINE_ENV = { GRAPHHOPPER_IOM_URL: GH_URL, GRAPHHOPPER_ENGLAND_URL: GH_URL }

const summary: any[] = []
for (const fixture of FIXTURES) {
  const trace = new URL(`corpus/${fixture.name}.jsonl`, import.meta.url).pathname
  const service = await startService(PORT, { ...ENGINE_ENV, LOOPER_TRACE_FILE: trace, LOOPER_TRACE_BODIES: '1' })
  try {
    await service.generate(fixture.body)   // warm-up; its trace is discarded
    writeFileSync(trace, '')
    const { wallMs, payload } = await service.generate(fixture.body)
    const routes = (payload.routes ?? []).map((r: any) => ({
      distanceMeters: r.distanceMeters,
      quality: r.quality?.score ?? r.score ?? null,
      repeatedFraction: r.quality?.repeatedFraction ?? null,
      geometryHash: hashRoute(r.geometry?.coordinates ?? r.coordinates ?? []),
    }))
    summary.push({ name: fixture.name, wallMs, routes, metrics: payload.diagnostics?.metrics ?? {} })
    console.log(`${fixture.name.padEnd(14)} ${String(wallMs).padStart(6)}ms  routes=${routes.length}  calls=${payload.diagnostics?.metrics?.graphhopperCalls}`)
  } finally {
    await service.stop()
  }
}
writeFileSync(new URL('capture-summary.json', import.meta.url), JSON.stringify(summary, null, 1))
console.log(`\ncorpus written to ${OUT.pathname}`)
