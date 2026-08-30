/**
 * P6 — what turn awareness buys, measured on and off.
 *
 * Phase 9's one quality regression against Phase 3B was u-turns: one across
 * the offered ring against four. The search now carries two things it did not:
 * a ranking penalty for a tight junction return, and the gate's own exact
 * u-turn count applied to a completed walk before it is ranked at all. This
 * runs the normal ring with both switched off and both switched on, and reports
 * what actually changed — coverage, quality, turns, and cost.
 */
import { writeFileSync } from 'node:fs'
import { FIXTURES } from '../phase2/fixtures.mjs'
import { startService } from '../phase2/service.mjs'
import { warm } from '../phase3a/warm.mjs'

const ghUrl = process.env.GH_URL ?? 'http://localhost:8991'
const normal = FIXTURES.filter(fixture => !fixture.name.startsWith('wp-'))

await warm(ghUrl)
const results: Record<string, any[]> = {}

for (const turnAware of ['false', 'true']) {
  const service = await startService(8823, {
    GRAPHHOPPER_IOM_URL: ghUrl,
    GRAPHHOPPER_ENGLAND_URL: ghUrl,
    LOOPER_DIRECT_TURN_AWARE: turnAware,
  })
  const rows: any[] = []
  try {
    for (const fixture of normal) {
      await service.generate({ ...fixture.body, routingEngine: 'direct' })
      const { wallMs, payload } = await service.generate({ ...fixture.body, routingEngine: 'direct' })
      const routes = payload.routes ?? []
      rows.push({
        fixture: fixture.name,
        wallMs,
        offered: routes.length,
        engine: payload.engine?.routingEngine,
        closedWalks: payload.engine?.searchClosedWalks ?? 0,
        turnRejections: payload.engine?.searchTurnRejections ?? 0,
        uTurns: routes.reduce((sum: number, route: any) => sum + route.quality.uTurnCount, 0),
        quality: routes.length ? Number((routes.reduce((sum: number, route: any) => sum + route.quality.score, 0) / routes.length).toFixed(1)) : 0,
        errorPercent: payload.engine?.offered?.medianDistanceErrorPercent ?? 0,
        searchMs: payload.engine?.searchMs,
      })
    }
  } finally {
    await service.stop()
  }
  results[turnAware] = rows
}

console.log('| turn aware | fixture | offered | closed walks | dropped on turns | offered u-turns | quality | median err % | search ms | wall ms |')
console.log('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|')
for (const [turnAware, rows] of Object.entries(results)) {
  for (const row of rows) {
    console.log(`| ${turnAware} | ${row.fixture} | ${row.offered} | ${row.closedWalks} | ${row.turnRejections} | ${row.uTurns} | ${row.quality} | ${row.errorPercent} | ${row.searchMs?.toFixed(1) ?? '—'} | ${row.wallMs} |`)
  }
}

console.log('\n| turn aware | offered / 12 | closed walks | dropped on turns | offered u-turns | mean quality | ring search ms |')
console.log('|---|---:|---:|---:|---:|---:|---:|')
for (const [turnAware, rows] of Object.entries(results)) {
  const sum = (pick: (row: any) => number) => rows.reduce((total, row) => total + pick(row), 0)
  console.log(`| ${turnAware} | ${sum(row => row.offered)} | ${sum(row => row.closedWalks)} | ${sum(row => row.turnRejections)} | ${sum(row => row.uTurns)} | `
    + `${(sum(row => row.quality) / rows.length).toFixed(1)} | ${sum(row => row.searchMs ?? 0).toFixed(0)} |`)
}

writeFileSync(new URL('results/turns.json', import.meta.url), JSON.stringify(results, null, 2))
console.log('\nwrote bench/phase10/results/turns.json')
