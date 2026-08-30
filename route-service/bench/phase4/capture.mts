/**
 * Phase 4 C0 trace capture. The trace now contains a plan/result record
 * for every corner and a closure record for every completed ring, so the
 * offline reader can explain closure error without changing engine behaviour.
 *
 *   npx tsx bench/phase4/capture.mts C0
 */
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { FIXTURES } from '../phase2/fixtures.mjs'
import { startService } from '../phase2/service.mjs'
import { warm } from '../phase3a/warm.mjs'

const label = process.argv[2] ?? 'C0'
const env = Object.fromEntries(process.argv.slice(3).map(pair => pair.split('=') as [string, string]))
const out = new URL(`corpus-${label}/`, import.meta.url)
const ghUrl = process.env.GH_URL ?? 'http://localhost:8991'
const retained = {
  ROUTING_CONCURRENCY: '4',
  LOOPER_MODEL_REGISTRY: 'true',
  LOOPER_ROUTE_MEMO: 'true',
  LOOPER_PULLBACK_REUSES_PREVIOUS: 'true',
  LOOPER_BACKTRACK_NEEDS_BUDGET: 'true',
  LOOPER_BUDGET_ONCE_PER_LEG: 'true',
}

rmSync(out, { recursive: true, force: true })
mkdirSync(out, { recursive: true })
await warm(ghUrl)
for (const fixture of FIXTURES) {
  const trace = new URL(`${fixture.name}.jsonl`, out).pathname
  const service = await startService(8814, {
    GRAPHHOPPER_IOM_URL: ghUrl, GRAPHHOPPER_ENGLAND_URL: ghUrl,
    LOOPER_TRACE_FILE: trace, ...retained, ...env,
  })
  try {
    await service.generate(fixture.body)
    writeFileSync(trace, '')
    const { wallMs, payload } = await service.generate(fixture.body)
    const metrics = payload.diagnostics?.metrics
    console.log(`${fixture.name.padEnd(14)} ${String(wallMs).padStart(6)}ms calls=${String(metrics?.graphhopperCalls ?? 0).padStart(4)} candidates=${metrics?.candidatesBuilt ?? 0}/${metrics?.candidatesPassed ?? 0}`)
  } finally {
    await service.stop()
  }
}
console.log(`\ncorpus written to ${out.pathname}`)
