/**
 * Phase 9 capture — Phase 3B production behaviour, plus the offered walks.
 *
 * Identical to the Phase 6/8 capture in every flag, so the corpus it writes is
 * the same reference those phases used. The one addition is `offered.json`:
 * the walks the service actually returned, kept beside the trace so the
 * topology study can tell an offered walk from a merely passing candidate.
 */
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { FIXTURES } from '../phase2/fixtures.mjs'
import { startService } from '../phase2/service.mjs'
import { warm } from '../phase3a/warm.mjs'

const label = process.argv[2] ?? 'P9'
const out = new URL(`corpus-${label}/`, import.meta.url)
const ghUrl = process.env.GH_URL ?? 'http://localhost:8991'
const retained = {
  ROUTING_CONCURRENCY: '4', LOOPER_MODEL_REGISTRY: 'true', LOOPER_ROUTE_MEMO: 'true',
  LOOPER_PULLBACK_REUSES_PREVIOUS: 'true', LOOPER_BACKTRACK_NEEDS_BUDGET: 'true', LOOPER_BUDGET_ONCE_PER_LEG: 'true',
}

rmSync(out, { recursive: true, force: true })
mkdirSync(out, { recursive: true })
await warm(ghUrl)
const offered: Array<Record<string, unknown>> = []
let calls = 0, routes = 0
for (const fixture of FIXTURES) {
  const trace = new URL(`${fixture.name}.jsonl`, out).pathname
  const service = await startService(8821, {
    GRAPHHOPPER_IOM_URL: ghUrl, GRAPHHOPPER_ENGLAND_URL: ghUrl,
    LOOPER_TRACE_FILE: trace, ...retained,
  })
  try {
    await service.generate(fixture.body)
    writeFileSync(trace, '')
    const { wallMs, payload } = await service.generate(fixture.body)
    const metrics = payload.diagnostics?.metrics
    offered.push({
      fixture: fixture.name, wallMs, graphhopperCalls: metrics?.graphhopperCalls ?? 0,
      candidatesBuilt: metrics?.candidatesBuilt ?? 0, candidatesPassed: metrics?.candidatesPassed ?? 0,
      routes: (payload.routes ?? []).map((route: any) => ({
        distanceMeters: route.distanceMeters, durationSeconds: route.durationSeconds,
        coordinates: route.geometry?.coordinates ?? [],
      })),
    })
    if (!fixture.name.startsWith('wp-')) { calls += metrics?.graphhopperCalls ?? 0; routes += payload.routes?.length ?? 0 }
    console.log(`${fixture.name.padEnd(14)} ${String(wallMs).padStart(6)}ms calls=${String(metrics?.graphhopperCalls ?? 0).padStart(4)} built=${metrics?.candidatesBuilt ?? 0} passed=${metrics?.candidatesPassed ?? 0} offered=${payload.routes?.length ?? 0}`)
  } finally { await service.stop() }
}
writeFileSync(new URL('offered.json', out), JSON.stringify(offered, null, 2) + '\n')
console.log(`\nnormal-ring offered routes: ${routes}, GraphHopper calls: ${calls}`)
console.log(`corpus written to ${out.pathname}`)
