/**
 * One traced generation per fixture at a named configuration.
 *
 * The same shape as Phase 3A's capture — warm the engine, discard a warm-up
 * generation, keep the second — with the flags under test supplied by the
 * caller, so a before and an after are the same measurement of two algorithms
 * rather than two measurements.
 */
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { FIXTURES } from '../phase2/fixtures.mjs'
import { startService } from '../phase2/service.mjs'
import { warm } from '../phase3a/warm.mjs'

const label = process.argv[2] ?? 'B0'
const env = Object.fromEntries(process.argv.slice(3).map(pair => pair.split('=') as [string, string]))
const OUT = new URL(`corpus-${label}/`, import.meta.url)
rmSync(OUT, { recursive: true, force: true })
mkdirSync(OUT, { recursive: true })

const GH_URL = process.env.GH_URL ?? 'http://localhost:8991'
await warm(GH_URL)
for (const fixture of FIXTURES) {
  const trace = new URL(`corpus-${label}/${fixture.name}.jsonl`, import.meta.url).pathname
  const service = await startService(8811, {
    GRAPHHOPPER_IOM_URL: GH_URL, GRAPHHOPPER_ENGLAND_URL: GH_URL,
    LOOPER_MODEL_REGISTRY: 'true', LOOPER_ROUTE_MEMO: 'true', LOOPER_TRACE_FILE: trace, ...env,
  })
  try {
    await service.generate(fixture.body)
    writeFileSync(trace, '')
    const { wallMs, payload } = await service.generate(fixture.body)
    console.log(`${fixture.name.padEnd(14)} ${String(wallMs).padStart(6)}ms  routes=${(payload.routes ?? []).length}  calls=${payload.diagnostics?.metrics?.graphhopperCalls}`)
  } finally {
    await service.stop()
  }
}
console.log(`\ncorpus written to ${OUT.pathname}`)
