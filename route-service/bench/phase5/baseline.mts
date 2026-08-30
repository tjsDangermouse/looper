/** Repeated warm Phase 3B baseline. Unlike trace capture, timings are untraced. */
import { mkdirSync, writeFileSync } from 'node:fs'
import { FIXTURES, hashRoute } from '../phase2/fixtures.mjs'
import { startService } from '../phase2/service.mjs'
import { warm } from '../phase3a/warm.mjs'

const ghUrl = process.env.GH_URL ?? 'http://localhost:8991'
const runs = Number(process.env.RUNS ?? 7)
const rounds = Number(process.env.ROUNDS ?? 4)
const retained = {
  ROUTING_CONCURRENCY: '4', LOOPER_MODEL_REGISTRY: 'true', LOOPER_ROUTE_MEMO: 'true',
  LOOPER_PULLBACK_REUSES_PREVIOUS: 'true', LOOPER_BACKTRACK_NEEDS_BUDGET: 'true', LOOPER_BUDGET_ONCE_PER_LEG: 'true',
}
const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]
const rows: any[] = []
await warm(ghUrl)
for (let round = 0; round < rounds; round++) {
  const service = await startService(8816, {
    GRAPHHOPPER_IOM_URL: ghUrl, GRAPHHOPPER_ENGLAND_URL: ghUrl, ...retained,
  })
  try {
    for (const fixture of FIXTURES) {
      const walls: number[] = [], calls: number[] = []
      let last: any
      for (let run = 0; run <= runs; run++) {
        const result = await service.generate(fixture.body)
        if (run === 0) continue
        walls.push(result.wallMs)
        calls.push(result.payload.diagnostics?.metrics?.graphhopperCalls ?? 0)
        last = result.payload
      }
      const metrics = last.diagnostics?.metrics
      rows.push({
        round, fixture: fixture.name, wallMs: median(walls), calls: median(calls),
        candidates: { built: metrics?.candidatesBuilt ?? 0, passed: metrics?.candidatesPassed ?? 0, rejections: metrics?.rejectionReasons ?? {} },
        offered: metrics?.offered ?? null,
        routes: (last.routes ?? []).map((route: any) => ({
          distance: route.distanceMeters, quality: route.quality?.score, repeated: route.quality?.repeatedPercent,
          uTurns: route.quality?.uTurnCount, geometryHash: hashRoute(route.geometry?.coordinates ?? []),
        })),
      })
      console.log(`r${round} ${fixture.name.padEnd(13)} ${String(median(walls)).padStart(5)}ms calls=${String(median(calls)).padStart(4)} candidates=${metrics?.candidatesBuilt ?? 0}/${metrics?.candidatesPassed ?? 0}`)
    }
  } finally { await service.stop() }
}
mkdirSync(new URL('results/', import.meta.url), { recursive: true })
writeFileSync(new URL('results/baseline.json', import.meta.url), JSON.stringify(rows, null, 2) + '\n')
const totals = Array.from({ length: rounds }, (_, round) => ({
  wallMs: rows.filter(row => row.round === round).reduce((sum, row) => sum + row.wallMs, 0),
  calls: rows.filter(row => row.round === round).reduce((sum, row) => sum + row.calls, 0),
}))
console.log(`\nround totals: ${totals.map(total => `${total.wallMs}ms/${total.calls}`).join(' | ')}`)
console.log(`median total: ${median(totals.map(total => total.wallMs))}ms/${median(totals.map(total => total.calls))} calls`)
