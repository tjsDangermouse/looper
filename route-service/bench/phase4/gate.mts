/**
 * Generic paired gate for a future, separately-authorised candidate experiment.
 * Phase 4 itself supplies no candidate-generation environment: the reverted
 * state is Phase 3B routing plus passive observability.
 */
import { writeFileSync } from 'node:fs'
import { FIXTURES } from '../phase2/fixtures.mjs'
import { startService } from '../phase2/service.mjs'
import { warm } from '../phase3a/warm.mjs'

const ghUrl = process.env.GH_URL ?? 'http://localhost:8991'
const runs = Number(process.env.RUNS ?? 7)
const rounds = Number(process.env.ROUNDS ?? 4)
const retained = {
  ROUTING_CONCURRENCY: '4', LOOPER_MODEL_REGISTRY: 'true', LOOPER_ROUTE_MEMO: 'true',
  LOOPER_PULLBACK_REUSES_PREVIOUS: 'true', LOOPER_BACKTRACK_NEEDS_BUDGET: 'true', LOOPER_BUDGET_ONCE_PER_LEG: 'true',
}
const experimentName = process.env.EXPERIMENT_NAME
const experimentEnv = Object.fromEntries((process.env.EXPERIMENT_ENV ?? '')
  .split(',').filter(Boolean).map(pair => pair.split('=') as [string, string]))
if (!experimentName || !Object.keys(experimentEnv).length) {
  throw new Error('Set EXPERIMENT_NAME and EXPERIMENT_ENV=KEY=VALUE before using the paired gate.')
}
const arms: Array<{ id: string; env: Record<string, string> }> = [
  { id: 'P3B', env: {} },
  { id: experimentName, env: experimentEnv },
]
const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]
const rows: any[] = []
await warm(ghUrl)
for (let round = 0; round < rounds; round++) {
  for (const arm of arms) {
    const service = await startService(8815, { GRAPHHOPPER_IOM_URL: ghUrl, GRAPHHOPPER_ENGLAND_URL: ghUrl, ...retained, ...arm.env })
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
        rows.push({ arm: arm.id, round, fixture: fixture.name, wallMs: median(walls), calls: median(calls),
          routes: (last.routes ?? []).map((route: any) => ({ distance: route.distanceMeters, quality: route.quality?.score, repeated: route.quality?.repeatedPercent, uTurns: route.quality?.uTurnCount })),
          candidates: { built: metrics?.candidatesBuilt ?? 0, passed: metrics?.candidatesPassed ?? 0, rejections: metrics?.rejectionReasons ?? {} },
          offered: metrics?.offered ?? null,
        })
        console.log(`r${round} ${arm.id} ${fixture.name.padEnd(13)} ${String(median(walls)).padStart(5)}ms calls=${String(median(calls)).padStart(4)} candidates=${metrics?.candidatesBuilt ?? 0}/${metrics?.candidatesPassed ?? 0}`)
      }
    } finally { await service.stop() }
  }
}
writeFileSync(new URL('gate.json', import.meta.url), JSON.stringify(rows, null, 2) + '\n')
console.log(`\n| fixture | P3B ms/calls | ${experimentName} ms/calls | wall change | call change | P3B pass | ${experimentName} pass |`)
console.log('|---|---:|---:|---:|---:|---:|---:|')
for (const fixture of FIXTURES) {
  const take = (arm: string, pick: (row: any) => number) => median(rows.filter(row => row.arm === arm && row.fixture === fixture.name).map(pick))
  const p3bMs = take('P3B', row => row.wallMs), experimentMs = take(experimentName, row => row.wallMs)
  const p3bCalls = take('P3B', row => row.calls), experimentCalls = take(experimentName, row => row.calls)
  const rate = (arm: string) => {
    const row = rows.filter(row => row.arm === arm && row.fixture === fixture.name).at(-1)
    return `${row.candidates.passed}/${row.candidates.built}`
  }
  console.log(`| ${fixture.name} | ${p3bMs}/${p3bCalls} | ${experimentMs}/${experimentCalls} | ${((experimentMs / p3bMs - 1) * 100).toFixed(1)}% | ${((experimentCalls / p3bCalls - 1) * 100).toFixed(1)}% | ${rate('P3B')} | ${rate(experimentName)} |`)
}
