/** Repeated alternating warm Phase 3B versus Phase 6 prototype benchmark. */
import { mkdirSync, writeFileSync } from 'node:fs'
import { FIXTURES, hashRoute } from '../phase2/fixtures.mjs'
import { startService } from '../phase2/service.mjs'
import { warm } from '../phase3a/warm.mjs'
import { mutualSharedFraction } from '../../src/loops/diversity.js'

const ghUrl = process.env.GH_URL ?? 'http://localhost:8991'
const runs = Number(process.env.RUNS ?? 7)
const rounds = Number(process.env.ROUNDS ?? 4)
const retained = {
  ROUTING_CONCURRENCY: '4', LOOPER_MODEL_REGISTRY: 'true', LOOPER_ROUTE_MEMO: 'true',
  LOOPER_PULLBACK_REUSES_PREVIOUS: 'true', LOOPER_BACKTRACK_NEEDS_BUDGET: 'true', LOOPER_BUDGET_ONCE_PER_LEG: 'true',
}
const arms: Array<{ name: string; env: Record<string, string> }> = [{ name: 'phase3b', env: {} }, { name: 'phase6', env: { LOOPER_PERIMETER_RETENTION: 'true' } }]
const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]
const rows: any[] = []
await warm(ghUrl)
for (let round = 0; round < rounds; round++) {
  const order = round % 2 ? [...arms].reverse() : arms
  for (const arm of order) {
    const service = await startService(8818, {
      GRAPHHOPPER_IOM_URL: ghUrl, GRAPHHOPPER_ENGLAND_URL: ghUrl, ...retained, ...arm.env,
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
        const routes = (last.routes ?? []).map((route: any) => ({
          distance: route.distanceMeters, quality: route.quality?.score, repeated: route.quality?.repeatedPercent,
          uTurns: route.quality?.uTurnCount, coordinates: route.geometry?.coordinates ?? [],
          geometryHash: hashRoute(route.geometry?.coordinates ?? []),
        }))
        const overlaps: number[] = []
        for (let a = 0; a < routes.length; a++) for (let b = a + 1; b < routes.length; b++) overlaps.push(mutualSharedFraction(
          { coordinates: routes[a].coordinates, quality: { score: routes[a].quality }, bearing: 0 },
          { coordinates: routes[b].coordinates, quality: { score: routes[b].quality }, bearing: 0 },
        ))
        rows.push({
          round, arm: arm.name, fixture: fixture.name, wallMs: median(walls), calls: median(calls),
          candidates: { built: metrics?.candidatesBuilt ?? 0, passed: metrics?.candidatesPassed ?? 0, rejections: metrics?.rejectionReasons ?? {} },
          offered: metrics?.offered ?? null, worstPairwiseGeometricOverlap: overlaps.length ? Math.max(...overlaps) : 0,
          routes: routes.map((route: any) => ({
            distance: route.distance, quality: route.quality, repeated: route.repeated,
            uTurns: route.uTurns, geometryHash: route.geometryHash,
          })),
        })
        console.log(`r${round} ${arm.name.padEnd(7)} ${fixture.name.padEnd(13)} ${String(median(walls)).padStart(5)}ms calls=${String(median(calls)).padStart(4)} candidates=${metrics?.candidatesBuilt ?? 0}/${metrics?.candidatesPassed ?? 0}`)
      }
    } finally { await service.stop() }
  }
}
mkdirSync(new URL('results/', import.meta.url), { recursive: true })
writeFileSync(new URL('results/paired.json', import.meta.url), JSON.stringify(rows, null, 2) + '\n')
for (const arm of arms) {
  const totals = Array.from({ length: rounds }, (_, round) => ({
    wallMs: rows.filter(row => row.arm === arm.name && row.round === round).reduce((sum, row) => sum + row.wallMs, 0),
    calls: rows.filter(row => row.arm === arm.name && row.round === round).reduce((sum, row) => sum + row.calls, 0),
  }))
  console.log(`${arm.name}: ${median(totals.map(row => row.wallMs))}ms / ${median(totals.map(row => row.calls))} calls`)
}
