/**
 * P24 — the Java engine against the Phase 9 TypeScript prototype.
 *
 * The question is not whether the two produce the same walks — a beam is an
 * ordered process and any difference in iteration order picks a different
 * member of an equally good set. The question is whether the Java version
 * reproduces Phase 9 *structurally*: the same graph after the same reductions,
 * the same order of magnitude of search, three routes per fixture, and
 * comparable distance, quality and separation.
 *
 * Phase 9's own numbers are read from `bench/phase9/results/`, not retyped.
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { FIXTURES } from '../phase2/fixtures.mjs'
import { startService } from '../phase2/service.mjs'
import { warm } from '../phase3a/warm.mjs'

const ghUrl = process.env.GH_URL ?? 'http://localhost:8991'
const normal = FIXTURES.filter(fixture => !fixture.name.startsWith('wp-'))

const offline = JSON.parse(readFileSync(new URL('../phase9/results/offline.json', import.meta.url), 'utf8')) as any[]
/** Phase 9's own subgraph and search-graph sizes, for the structural check. */
const phase9Graph = JSON.parse(readFileSync(new URL('../phase9/subgraphs.json', import.meta.url), 'utf8')) as any[]

await warm(ghUrl)
const service = await startService(Number(process.env.PORT ?? 8827), { GRAPHHOPPER_IOM_URL: ghUrl, GRAPHHOPPER_ENGLAND_URL: ghUrl })
const java: Record<string, any> = {}
try {
  for (const fixture of normal) {
    await service.generate({ ...fixture.body, routingEngine: 'direct' })
    const { payload } = await service.generate({ ...fixture.body, routingEngine: 'direct' })
    const routes = payload.routes ?? []
    const target = payload.diagnostics?.targetMetres ?? fixture.body.distanceKm * 1000
    java[fixture.name] = {
      offered: routes.length,
      engine: payload.engine?.routingEngine,
      meanAbsErrorMetres: routes.length ? Math.round(routes.reduce((sum: number, route: any) => sum + Math.abs(route.distanceMeters - target), 0) / routes.length) : 0,
      meanQuality: routes.length ? Number((routes.reduce((sum: number, route: any) => sum + route.quality.score, 0) / routes.length).toFixed(1)) : 0,
      meanRepeatedPercent: routes.length ? Number((routes.reduce((sum: number, route: any) => sum + route.quality.repeatedPercent, 0) / routes.length).toFixed(2)) : 0,
      uTurns: routes.reduce((sum: number, route: any) => sum + route.quality.uTurnCount, 0),
      worstOverlapPercent: payload.engine?.offered?.maxPairSharedEdgePercent ?? payload.engine?.offered?.maxPairSharedPercent,
      states: payload.engine?.searchStates,
      closedWalks: payload.engine?.searchClosedWalks,
      turnRejections: payload.engine?.searchTurnRejections,
      searchMs: payload.engine?.searchMs,
      expanded: payload.engine?.searchExpanded,
      graphNodes: payload.engine?.searchGraphNodes,
      rawNodes: payload.engine?.searchRawNodes,
    }
  }
} finally {
  await service.stop()
}

/** Phase 9's retained S2 prototype, summarised from its own recorded offers. */
const phase9 = (fixture: string) => {
  const row = offline.find((entry: any) => entry.fixture === fixture && entry.prototype === 'S2')
  if (!row) return undefined
  const offered = row.offered as any[]
  const target = fixture.includes('3km') ? 3000 : 5000
  const mean = (pick: (entry: any) => number) => offered.length ? offered.reduce((sum, entry) => sum + pick(entry), 0) / offered.length : 0
  return {
    offered: offered.length,
    meanAbsErrorMetres: Math.round(mean(entry => Math.abs(entry.metres - target))),
    meanQuality: Number(mean(entry => entry.quality.score).toFixed(1)),
    meanRepeatedPercent: Number(mean(entry => entry.quality.repeatedPercent).toFixed(2)),
    uTurns: offered.reduce((sum, entry) => sum + entry.quality.uTurnCount, 0),
    closedWalks: row.found,
    passes: row.passes,
    states: row.stats.storeSize,
    expanded: row.stats.expanded,
    searchMs: row.stats.wallMs,
    exportMs: row.exportMs,
    buildMs: row.buildMs,
  }
}

console.log('### Route outcome: Phase 9 prototype (TypeScript) against Phase 10 (Java)\n')
console.log('| fixture | offered P9 / P10 | mean abs error P9 / P10 | mean quality P9 / P10 | repeated % P9 / P10 | u-turns P9 / P10 |')
console.log('|---|---|---|---|---|---|')
for (const fixture of normal) {
  const before = phase9(fixture.name)
  const after = java[fixture.name]
  const show = (a: unknown, b: unknown, unit = '') => `${a ?? '—'}${unit} / ${b ?? '—'}${unit}`
  console.log(`| ${fixture.name} | ${show(before?.offered, after.offered)} | ${show(before?.meanAbsErrorMetres, after.meanAbsErrorMetres, ' m')} | `
    + `${show(before?.meanQuality, after.meanQuality)} | ${show(before?.meanRepeatedPercent, after.meanRepeatedPercent)} | `
    + `${show(before?.uTurns, after.uTurns)} |`)
}

console.log('\n### Search cost, and the graph both searched\n')
console.log('| fixture | explored nodes P9 / P10 | reduced search nodes P10 | states P9 / P10 | expanded P9 / P10 | closed walks P9 / P10 | dropped on turns P10 | search ms P9 / P10 |')
console.log('|---|---|---:|---|---|---|---:|---|')
for (const fixture of normal) {
  const before = phase9(fixture.name)
  const raw = phase9Graph.find((entry: any) => entry.name === fixture.name)
  const after = java[fixture.name]
  console.log(`| ${fixture.name} | ${raw?.nodeCount ?? '—'} / ${after.rawNodes ?? '—'} | ${after.graphNodes ?? '—'} | ${before?.states ?? '—'} / ${after.states} | `
    + `${before?.expanded ?? '—'} / ${after.expanded ?? '—'} | ${before?.closedWalks ?? '—'} / ${after.closedWalks} | ${after.turnRejections ?? '—'} | `
    + `${before?.searchMs?.toFixed(0) ?? '—'} / ${after.searchMs?.toFixed(0)} |`)
}

writeFileSync(new URL('results/compare9.json', import.meta.url), JSON.stringify({ java, phase9: offline.filter((row: any) => /Phase 9/.test(String(row.generator))) }, null, 2))
console.log('\nwrote bench/phase10/results/compare9.json')
