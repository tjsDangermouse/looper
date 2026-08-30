/** P0: confirm the Phase 3B normal-ring offered-route count with production flags. */
import { FIXTURES } from '../phase2/fixtures.mjs'
import { startService } from '../phase2/service.mjs'
import { warm } from '../phase3a/warm.mjs'

const ghUrl = process.env.GH_URL ?? 'http://localhost:8991'
const retained = {
  ROUTING_CONCURRENCY: '4', LOOPER_MODEL_REGISTRY: 'true', LOOPER_ROUTE_MEMO: 'true',
  LOOPER_PULLBACK_REUSES_PREVIOUS: 'true', LOOPER_BACKTRACK_NEEDS_BUDGET: 'true', LOOPER_BUDGET_ONCE_PER_LEG: 'true',
}
await warm(ghUrl)
let offered = 0, calls = 0
for (const fixture of FIXTURES) {
  const service = await startService(8819, { GRAPHHOPPER_IOM_URL: ghUrl, GRAPHHOPPER_ENGLAND_URL: ghUrl, ...retained })
  try {
    await service.generate(fixture.body)
    const { wallMs, payload } = await service.generate(fixture.body)
    const metrics = payload.diagnostics?.metrics
    const routes = payload.routes?.length ?? 0
    const normal = !fixture.name.startsWith('wp-')
    if (normal) { offered += routes; calls += metrics?.graphhopperCalls ?? 0 }
    console.log(`${fixture.name.padEnd(14)} ${String(wallMs).padStart(5)}ms calls=${String(metrics?.graphhopperCalls ?? 0).padStart(4)} builds=${metrics?.candidatesBuilt ?? 0} passes=${metrics?.candidatesPassed ?? 0} offered=${routes}`)
  } finally { await service.stop() }
}
console.log(`\nnormal-ring offered routes: ${offered}, GraphHopper calls: ${calls}`)
