/**
 * Phase 3B §25, §29, §30, §31: the staged call-elimination experiments.
 *
 * Each stage is its own service, its own flags and its own set of warm runs,
 * because §25 refuses a single combined number with no way to attribute it.
 * Wall time is the walker's, measured end to end; call count is the
 * generator's, read back from its own diagnostics. Both are reported, and
 * neither is allowed to stand in for the other.
 *
 * Route identity is checked on every stage against the baseline's own output:
 * where a stage only changes planning it must return the same walks, and where
 * it changes what is asked for the difference is stated rather than averaged
 * away.
 */
import { writeFileSync } from 'node:fs'
import { FIXTURES, hashRoute } from '../phase2/fixtures.mjs'
import { startService } from '../phase2/service.mjs'
import { warm } from '../phase3a/warm.mjs'

const PORT = 8809
const GH_URL = process.env.GH_URL ?? 'http://localhost:8991'
/** Warm runs per fixture per stage; the median is what the tables report. */
const RUNS = Number(process.env.RUNS ?? 7)
const ROUNDS = Number(process.env.ROUNDS ?? 1)

const RETAINED = { LOOPER_MODEL_REGISTRY: 'true', LOOPER_ROUTE_MEMO: 'true' }

export const STAGES: Array<{ id: string; what: string; env: Record<string, string> }> = [
  { id: 'B0', what: 'Phase 3A retained baseline', env: {} },
  { id: 'B1', what: '+ join-pullback trims the previous leg', env: { LOOPER_PULLBACK_REUSES_PREVIOUS: 'true' } },
  { id: 'B2', what: '+ the cheaper reroute asked once per leg', env: { LOOPER_BUDGET_ONCE_PER_LEG: 'true' } },
  { id: 'B3', what: '+ a short backtrack alone no longer forces a retry', env: { LOOPER_BACKTRACK_NEEDS_BUDGET: 'true' } },
  { id: 'B5', what: '+ the closest-fitting attempt is kept, not the last', env: { LOOPER_KEEP_BEST_LEG_ATTEMPT: 'true' } },
  { id: 'B6', what: 'B1 + B2 + B3 + B5 together', env: {
    LOOPER_PULLBACK_REUSES_PREVIOUS: 'true', LOOPER_BUDGET_ONCE_PER_LEG: 'true',
    LOOPER_BACKTRACK_NEEDS_BUDGET: 'true', LOOPER_KEEP_BEST_LEG_ATTEMPT: 'true',
  } },
  { id: 'B6-noB1', what: 'B2 + B3 + B5, leaving the pullback alone', env: {
    LOOPER_BUDGET_ONCE_PER_LEG: 'true', LOOPER_BACKTRACK_NEEDS_BUDGET: 'true', LOOPER_KEEP_BEST_LEG_ATTEMPT: 'true',
  } },
  { id: 'B6-noB5', what: 'B1 + B2 + B3, keeping the last attempt', env: {
    LOOPER_PULLBACK_REUSES_PREVIOUS: 'true', LOOPER_BUDGET_ONCE_PER_LEG: 'true', LOOPER_BACKTRACK_NEEDS_BUDGET: 'true',
  } },
]

const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]

export type Run = {
  stage: string; round: number; fixture: string
  wallMs: number; calls: number; routes: number
  distances: number[]; quality: number[]; repeated: number[]; hashes: string[]
  callsByPurpose: Record<string, number>
  candidatesBuilt: number; candidatesPassed: number; earlyStop: string
}

await warm(GH_URL)
const runs: Run[] = []
for (let round = 0; round < ROUNDS; round++) {
  for (const stage of STAGES) {
    const service = await startService(PORT, { GRAPHHOPPER_IOM_URL: GH_URL, GRAPHHOPPER_ENGLAND_URL: GH_URL, ...RETAINED, ...stage.env })
    try {
      for (const fixture of FIXTURES) {
        const samples: Run[] = []
        for (let run = 0; run < RUNS + 1; run++) {
          const { wallMs, payload } = await service.generate(fixture.body)
          if (run === 0) continue   // the first is the warm-up and is discarded
          const metrics = payload.diagnostics?.metrics ?? {}
          const routes = payload.routes ?? []
          samples.push({
            stage: stage.id, round, fixture: fixture.name, wallMs,
            calls: metrics.graphhopperCalls ?? 0, routes: routes.length,
            distances: routes.map((r: any) => Math.round(r.distanceMeters)),
            quality: routes.map((r: any) => r.quality?.score ?? 0),
            repeated: routes.map((r: any) => r.quality?.repeatedPercent ?? 0),
            hashes: routes.map((r: any) => hashRoute(r.geometry?.coordinates ?? [])),
            callsByPurpose: metrics.callsByPurpose ?? {},
            candidatesBuilt: metrics.candidatesBuilt ?? 0,
            candidatesPassed: metrics.candidatesPassed ?? 0,
            earlyStop: metrics.earlyStop ?? '',
          })
        }
        const pick = samples[samples.map(s => s.wallMs).indexOf(median(samples.map(s => s.wallMs)))]
        runs.push({ ...pick, wallMs: median(samples.map(s => s.wallMs)), calls: median(samples.map(s => s.calls)) })
        console.log(`${stage.id} r${round} ${fixture.name.padEnd(13)} ${String(pick.wallMs).padStart(5)}ms  calls=${String(pick.calls).padStart(4)}  routes=${pick.routes}`)
      }
    } finally {
      await service.stop()
    }
  }
}
writeFileSync(new URL('results/experiments.json', import.meta.url), JSON.stringify(runs, null, 1))
console.log('\nwritten to results/experiments.json')
