/**
 * Phase 3B §29, §30, §32: the gate.
 *
 * Phase 3A measured its own baseline against itself four times and found a
 * 4.2% spread, which is larger than most of what this phase is trying to see.
 * So the comparison is paired inside alternating rounds — a fresh service for
 * each arm of each round, each fixture the median of several warm generations
 * — and the per-round differences are reported alongside the pooled one.
 *
 * Everything a walker would notice is compared on every run: how many walks
 * came back, how long each is, what it scored, how much of it retraces, and
 * the geometry itself.
 */
import { writeFileSync } from 'node:fs'
import { FIXTURES, hashRoute } from '../phase2/fixtures.mjs'
import { startService } from '../phase2/service.mjs'
import { warm } from '../phase3a/warm.mjs'

const PORT = 8813
const GH_URL = process.env.GH_URL ?? 'http://localhost:8991'
const RUNS = Number(process.env.RUNS ?? 7)
const ROUNDS = Number(process.env.ROUNDS ?? 4)
const RETAINED_BOUNDARY = { LOOPER_MODEL_REGISTRY: 'true', LOOPER_ROUTE_MEMO: 'true' }

const ARMS: Array<{ id: string; what: string; env: Record<string, string> }> = [
  { id: 'P3A', what: 'Phase 3A retained, six-way', env: { ROUTING_CONCURRENCY: '6' } },
  { id: 'P3B', what: 'B1 + B2 + B3, four-way', env: {
    ROUTING_CONCURRENCY: '4',
    LOOPER_PULLBACK_REUSES_PREVIOUS: 'true',
    LOOPER_BUDGET_ONCE_PER_LEG: 'true',
    LOOPER_BACKTRACK_NEEDS_BUDGET: 'true',
  } },
]

const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]
await warm(GH_URL)

const rows: any[] = []
for (let round = 0; round < ROUNDS; round++) {
  for (const arm of ARMS) {
    const service = await startService(PORT, { GRAPHHOPPER_IOM_URL: GH_URL, GRAPHHOPPER_ENGLAND_URL: GH_URL, ...RETAINED_BOUNDARY, ...arm.env })
    try {
      for (const fixture of FIXTURES) {
        const walls: number[] = []
        const calls: number[] = []
        let last: any
        for (let run = 0; run < RUNS + 1; run++) {
          const { wallMs, payload } = await service.generate(fixture.body)
          if (run === 0) continue
          walls.push(wallMs)
          calls.push(payload.diagnostics?.metrics?.graphhopperCalls ?? 0)
          last = payload
        }
        const routes = (last.routes ?? []).map((r: any) => ({
          distanceMeters: Math.round(r.distanceMeters),
          quality: r.quality?.score ?? null,
          repeatedPercent: r.quality?.repeatedPercent ?? null,
          uTurnCount: r.quality?.uTurnCount ?? null,
          geometryHash: hashRoute(r.geometry?.coordinates ?? []),
        }))
        rows.push({
          arm: arm.id, round, fixture: fixture.name,
          wallMs: median(walls), calls: median(calls), routes,
          offered: last.diagnostics?.metrics?.offered ?? null,
        })
        console.log(`r${round} ${arm.id} ${fixture.name.padEnd(13)} ${String(median(walls)).padStart(5)}ms  calls=${String(median(calls)).padStart(4)}  routes=${routes.length}`)
      }
    } finally {
      await service.stop()
    }
  }
}
writeFileSync(new URL('results/gate.json', import.meta.url), JSON.stringify(rows, null, 1))

// ── the tables ──────────────────────────────────────────────────────────────
const totalsFor = (arm: string, round: number, pick: (r: any) => number) =>
  rows.filter(r => r.arm === arm && r.round === round).reduce((total, r) => total + pick(r), 0)
console.log('\n| fixture | P3A ms | P3B ms | change | P3A calls | P3B calls | change |')
console.log('|---|---:|---:|---:|---:|---:|---:|')
for (const fixture of FIXTURES) {
  const of = (arm: string, pick: (r: any) => number) =>
    median(rows.filter(r => r.arm === arm && r.fixture === fixture.name).map(pick))
  const a = of('P3A', r => r.wallMs), b = of('P3B', r => r.wallMs)
  const ca = of('P3A', r => r.calls), cb = of('P3B', r => r.calls)
  console.log(`| ${fixture.name} | ${a} | ${b} | ${(((b - a) / a) * 100).toFixed(1)}% | ${ca} | ${cb} | ${(((cb - ca) / ca) * 100).toFixed(1)}% |`)
}
const roundTotals = (arm: string, pick: (r: any) => number) =>
  Array.from({ length: ROUNDS }, (_, round) => totalsFor(arm, round, pick))
const wa = roundTotals('P3A', r => r.wallMs), wb = roundTotals('P3B', r => r.wallMs)
const cA = roundTotals('P3A', r => r.calls), cB = roundTotals('P3B', r => r.calls)
console.log(`| **total** | **${median(wa)}** | **${median(wb)}** | **${(((median(wb) - median(wa)) / median(wa)) * 100).toFixed(1)}%** | **${median(cA)}** | **${median(cB)}** | **${(((median(cB) - median(cA)) / median(cA)) * 100).toFixed(1)}%** |`)
console.log(`\nwall by round — P3A ${wa.join(' / ')} (spread ${(((Math.max(...wa) - Math.min(...wa)) / Math.min(...wa)) * 100).toFixed(1)}%)`)
console.log(`                P3B ${wb.join(' / ')} (spread ${(((Math.max(...wb) - Math.min(...wb)) / Math.min(...wb)) * 100).toFixed(1)}%)`)
console.log(`paired by round: ${wa.map((a, i) => `${(((wb[i] - a) / a) * 100).toFixed(1)}%`).join(' / ')}`)
console.log(`calls by round — P3A ${cA.join(' / ')};  P3B ${cB.join(' / ')}`)

console.log('\n| fixture | routes | distance, P3A → P3B | quality | repeated % | geometry |')
console.log('|---|---|---|---|---|---|')
for (const fixture of FIXTURES) {
  const pick = (arm: string) => rows.filter(r => r.arm === arm && r.fixture === fixture.name).at(-1)!.routes
  const a = pick('P3A'), b = pick('P3B')
  const fmt = (rs: any[], f: (r: any) => any) => rs.map(f).join(', ')
  const same = JSON.stringify(a.map((r: any) => r.geometryHash)) === JSON.stringify(b.map((r: any) => r.geometryHash))
  console.log(`| ${fixture.name} | ${a.length} → ${b.length} | ${fmt(a, (r: any) => r.distanceMeters)} → ${fmt(b, (r: any) => r.distanceMeters)} | ${fmt(a, (r: any) => r.quality)} → ${fmt(b, (r: any) => r.quality)} | ${fmt(a, (r: any) => r.repeatedPercent?.toFixed(1))} → ${fmt(b, (r: any) => r.repeatedPercent?.toFixed(1))} | ${same ? 'identical' : 'differs'} |`)
}
