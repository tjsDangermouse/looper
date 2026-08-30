/**
 * P25 — the paired benchmark: Phase 3B against Direct Search, alternating.
 *
 * One service, one facade, the six probes every phase since Phase 1 has used,
 * and the two engines asked for the same walk one after the other so that
 * whatever the machine was doing is spread over both rather than over one. The
 * waypoint probes are here as regression checks, not as direct-search
 * benchmarks: an ordered pin list always goes to Phase 3B, and what these two
 * rows have to show is that asking for Direct Search does not change them.
 *
 * Everything reported is measured from the answer the service actually sent.
 */
import { writeFileSync } from 'node:fs'
import { FIXTURES } from '../phase2/fixtures.mjs'
import { startService } from '../phase2/service.mjs'
import { warm } from '../phase3a/warm.mjs'

const ghUrl = process.env.GH_URL ?? 'http://localhost:8991'
const repeats = Number(process.env.REPEATS ?? 3)
const port = Number(process.env.PORT ?? 8821)

/** Production's own flags, unchanged. Phase 10 adds an engine, not a tuning. */
const retained = {
  GRAPHHOPPER_IOM_URL: ghUrl,
  GRAPHHOPPER_ENGLAND_URL: ghUrl,
  ROUTING_CONCURRENCY: '4',
  LOOPER_MODEL_REGISTRY: 'true',
  LOOPER_ROUTE_MEMO: 'true',
  LOOPER_PULLBACK_REUSES_PREVIOUS: 'true',
  LOOPER_BACKTRACK_NEEDS_BUDGET: 'true',
  LOOPER_BUDGET_ONCE_PER_LEG: 'true',
}

type Row = {
  fixture: string
  engine: string
  actualEngine: string
  fallbackReason?: string
  wallMs: number
  routes: number
  medianErrorPercent: number
  quality: number
  repeatedPercent: number
  uTurns: number
  overlapPercent: number
  edgeOverlapPercent?: number
  graphhopperCalls: number
  searchStates?: number
  searchClosedWalks?: number
  searchMs?: number
  searchPeakBytes?: number
}

const median = (values: number[]) => {
  const sorted = [...values].sort((a, b) => a - b)
  return sorted.length % 2 ? sorted[sorted.length >> 1] : (sorted[(sorted.length >> 1) - 1] + sorted[sorted.length >> 1]) / 2
}

function measure(fixture: string, engine: string, wallMs: number, payload: any): Row {
  const routes = payload.routes ?? []
  const target = payload.diagnostics?.targetMetres ?? (fixture.includes('3km') ? 3000 : fixture === 'wp-one' ? 6000 : fixture === 'wp-two' ? 8000 : 5000)
  const offered = payload.engine?.offered ?? payload.diagnostics?.metrics?.offered
  return {
    fixture,
    engine,
    actualEngine: payload.engine?.routingEngine ?? 'remote',
    fallbackReason: payload.engine?.fallbackReason,
    wallMs,
    routes: routes.length,
    medianErrorPercent: offered?.medianDistanceErrorPercent
      ?? (routes.length ? Number(median(routes.map((r: any) => Math.abs(r.distanceMeters - target) / target * 100)).toFixed(1)) : 0),
    quality: routes.length ? Number((routes.reduce((sum: number, r: any) => sum + r.quality.score, 0) / routes.length).toFixed(1)) : 0,
    repeatedPercent: routes.length ? Number((routes.reduce((sum: number, r: any) => sum + r.quality.repeatedPercent, 0) / routes.length).toFixed(2)) : 0,
    uTurns: routes.reduce((sum: number, r: any) => sum + r.quality.uTurnCount, 0),
    overlapPercent: offered?.maxPairSharedPercent ?? 0,
    edgeOverlapPercent: offered?.maxPairSharedEdgePercent,
    graphhopperCalls: payload.diagnostics?.metrics?.graphhopperCalls ?? 0,
    searchStates: payload.engine?.searchStates,
    searchClosedWalks: payload.engine?.searchClosedWalks,
    searchMs: payload.engine?.searchMs,
    searchPeakBytes: payload.engine?.searchPeakBytes,
  }
}

await warm(ghUrl)
const service = await startService(port, retained)
const rows: Row[] = []
try {
  // One warm pass so neither engine is measured cold, then alternating rounds.
  for (const fixture of FIXTURES) {
    for (const engine of ['remote', 'direct']) {
      await service.generate({ ...fixture.body, routingEngine: engine })
    }
  }
  for (let round = 0; round < repeats; round++) {
    for (const fixture of FIXTURES) {
      for (const engine of ['remote', 'direct']) {
        const { wallMs, payload } = await service.generate({ ...fixture.body, routingEngine: engine })
        rows.push(measure(fixture.name, engine, wallMs, payload))
      }
    }
  }
} finally {
  await service.stop()
}

// One row per fixture and engine, taking the median wall time of the repeats
// and the last run's route measurements — which are identical run to run,
// since the generator is deterministic.
const keyed = new Map<string, Row[]>()
for (const row of rows) {
  const key = `${row.fixture}|${row.engine}`
  keyed.set(key, [...(keyed.get(key) ?? []), row])
}
const summary = [...keyed.values()].map(group => ({ ...group[group.length - 1], wallMs: Math.round(median(group.map(r => r.wallMs))) }))

const table = (title: string, filter: (row: Row) => boolean) => {
  console.log(`\n### ${title}\n`)
  console.log('| fixture | engine | actual | wall ms | routes | median err % | quality | repeated % | u-turns | overlap % | edge overlap % | GH calls | states | search ms | peak store KB |')
  console.log('|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
  for (const row of summary.filter(filter)) {
    console.log(`| ${row.fixture} | ${row.engine} | ${row.actualEngine}${row.fallbackReason ? ` (${row.fallbackReason})` : ''} | ${row.wallMs} | ${row.routes} | `
      + `${row.medianErrorPercent} | ${row.quality} | ${row.repeatedPercent} | ${row.uTurns} | ${row.overlapPercent} | ${row.edgeOverlapPercent ?? '—'} | `
      + `${row.graphhopperCalls} | ${row.searchStates ?? '—'} | ${row.searchMs?.toFixed(1) ?? '—'} | ${row.searchPeakBytes ? Math.round(row.searchPeakBytes / 1024) : '—'} |`)
  }
}

table('Normal ring', row => !row.fixture.startsWith('wp-'))
table('Waypoint probes — regression checks, both engines route through Phase 3B', row => row.fixture.startsWith('wp-'))

const ring = (engine: string) => summary.filter(row => row.engine === engine && !row.fixture.startsWith('wp-'))
console.log('\n### Normal-ring totals\n')
console.log('| engine | offered / 12 | mean median err % | mean quality | mean repeated % | u-turns | GH calls | ring wall ms |')
console.log('|---|---:|---:|---:|---:|---:|---:|---:|')
for (const engine of ['remote', 'direct']) {
  const group = ring(engine)
  const mean = (pick: (row: Row) => number) => Number((group.reduce((sum, row) => sum + pick(row), 0) / group.length).toFixed(2))
  console.log(`| ${engine} | ${group.reduce((sum, row) => sum + row.routes, 0)} | ${mean(row => row.medianErrorPercent)} | ${mean(row => row.quality)} | `
    + `${mean(row => row.repeatedPercent)} | ${group.reduce((sum, row) => sum + row.uTurns, 0)} | ${group.reduce((sum, row) => sum + row.graphhopperCalls, 0)} | `
    + `${group.reduce((sum, row) => sum + row.wallMs, 0)} |`)
}

writeFileSync(new URL('results/paired.json', import.meta.url), JSON.stringify({ repeats, summary, rows }, null, 2))
console.log('\nwrote bench/phase10/results/paired.json')
