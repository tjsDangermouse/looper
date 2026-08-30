/**
 * P16 — Phase 3B, Phase 8 and the Phase 9 prototype on the same axes.
 *
 * Phase 3B's row is measured from this checkout's own capture; Phase 8's is
 * quoted from its report, since nothing about it was re-run here.
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { mutualSharedFraction, selectDiverseRoutes } from '../../src/loops/diversity.js'
import { measureTraversals } from '../../src/loops/edges.js'
import { STARTS, mean } from '../phase8/field.mjs'
import { loadSubgraphs, buildSearchGraph } from './graph.mjs'
import { beamSearch, objectiveFor, rootOf } from './search.mjs'
import { judge, type Judged } from './walk.mjs'
import { loadWalks } from './topology.mjs'

const NORMAL = ['douglas-5km', 'douglas-3km', 'peel-5km', 'onchan-5km']
const TARGETS = new Map([['douglas-5km', 5000], ['douglas-3km', 3000], ['peel-5km', 5000], ['onchan-5km', 5000]])

// ------------------------------------------------------- Phase 3B, measured
const corpus = new URL('corpus-P9/', import.meta.url)
const offeredPayload = JSON.parse(readFileSync(new URL('offered.json', corpus), 'utf8')) as Array<{ fixture: string; graphhopperCalls: number; wallMs: number; routes: Array<{ distanceMeters: number; coordinates: [number, number][] }> }>
const p3b = loadWalks(corpus, NORMAL).filter(walk => walk.offered)

// -------------------------------------------------------- Phase 9, measured
const p9 = new Map<string, { offered: Judged[]; searchMs: number; expanded: number; peakHeapMb: number; buildMs: number; exportMs: number }>()
for (const raw of loadSubgraphs(new URL('subgraphs.json', import.meta.url))) {
  if (!NORMAL.includes(raw.name)) continue
  const graph = buildSearchGraph(raw)
  const { root } = rootOf(graph)
  const { walks, stats } = beamSearch(graph, {
    objective: objectiveFor(graph.targetMetres), budget: Infinity,
    beam: 300, band: 100, perNode: 3, perFamily: 1, minCompactness: 0.2,
  })
  const passes = walks.map(walk => judge(graph, walk, root, STARTS.get(graph.name)!)).filter(entry => entry.report.pass)
  const offered = selectDiverseRoutes(passes.map(entry => ({ ...entry, coordinates: entry.assembled.coordinates, quality: entry.report.quality, totalMetres: entry.assembled.graphMetres })), 3) as unknown as Judged[]
  p9.set(graph.name, { offered, searchMs: stats.wallMs, expanded: stats.expanded, peakHeapMb: stats.peakHeapBytes / 1e6, buildMs: graph.stats.buildWallMs, exportMs: graph.stats.exportWallMs })
}

const worstOverlapP9 = (set: Judged[]) => {
  let worst = 0
  for (let i = 0; i < set.length; i++) for (let j = i + 1; j < set.length; j++) {
    const a = { coordinates: set[i].assembled.coordinates, quality: set[i].report.quality, bearing: set[i].bearing, traversals: set[i].traversals, totalMetres: set[i].assembled.graphMetres }
    const b = { coordinates: set[j].assembled.coordinates, quality: set[j].report.quality, bearing: set[j].bearing, traversals: set[j].traversals, totalMetres: set[j].assembled.graphMetres }
    worst = Math.max(worst, mutualSharedFraction(a, b))
  }
  return worst
}
const worstOverlapP3B = (fixture: string) => {
  const routes = offeredPayload.find(entry => entry.fixture === fixture)?.routes ?? []
  let worst = 0
  for (let i = 0; i < routes.length; i++) for (let j = i + 1; j < routes.length; j++) {
    const a = { coordinates: routes[i].coordinates, quality: { score: 0 }, bearing: 0, totalMetres: routes[i].distanceMeters, traversals: undefined as ReturnType<typeof measureTraversals> }
    const b = { coordinates: routes[j].coordinates, quality: { score: 0 }, bearing: 0, totalMetres: routes[j].distanceMeters, traversals: undefined as ReturnType<typeof measureTraversals> }
    worst = Math.max(worst, mutualSharedFraction(a, b))
  }
  return worst
}

const out: string[] = ['# Phase 9 P16 — Phase 3B, Phase 8 and Phase 9 side by side\n']
out.push('| fixture | generator | offered | mean abs distance error | mean quality | mean repeated ground | u-turns | worst overlap among offered | GraphHopper calls | search / routing wall |')
out.push('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|')
const p8Quoted: Record<string, [number, number, number, number, number]> = {
  // offered, mean abs error m, mean quality, repeated %, u-turns — quoted from
  // the Phase 8 report's section 16.
  'douglas-5km': [3, 88, 72.7, 0, 0], 'douglas-3km': [3, 122, 69.5, 0, 0],
  'peel-5km': [2, 65, 76.5, 0, 0], 'onchan-5km': [3, 83, 77.4, 0, 0],
}
for (const fixture of NORMAL) {
  const target = TARGETS.get(fixture)!
  const base = p3b.filter(walk => walk.fixture === fixture)
  const payload = offeredPayload.find(entry => entry.fixture === fixture)!
  out.push(`| ${fixture} | Phase 3B | ${base.length} | ${mean(base.map(walk => Math.abs(walk.distance - target))).toFixed(0)} m `
    + `| ${mean(base.map(walk => walk.quality)).toFixed(1)} | ${mean(base.map(walk => walk.repeatedPercent)).toFixed(2)}% `
    + `| ${base.reduce((sum, walk) => sum + walk.uTurns, 0)} | ${(100 * worstOverlapP3B(fixture)).toFixed(1)}% | ${payload.graphhopperCalls} | ${payload.wallMs} ms |`)
  const quoted = p8Quoted[fixture]
  out.push(`| ${fixture} | Phase 8 (quoted) | ${quoted[0]} | ${quoted[1]} m | ${quoted[2]} | ${quoted[3].toFixed(2)}% | ${quoted[4]} | — | see report | — |`)
  const row = p9.get(fixture)!
  out.push(`| ${fixture} | Phase 9 S2 | ${row.offered.length} | ${mean(row.offered.map(entry => Math.abs(entry.assembled.graphMetres - target))).toFixed(0)} m `
    + `| ${mean(row.offered.map(entry => entry.report.quality.score)).toFixed(1)} | ${mean(row.offered.map(entry => entry.report.quality.repeatedPercent)).toFixed(2)}% `
    + `| ${row.offered.reduce((sum, entry) => sum + entry.report.quality.uTurnCount, 0)} | ${(100 * worstOverlapP9(row.offered)).toFixed(1)}% | 0 `
    + `| ${(row.exportMs + row.buildMs + row.searchMs).toFixed(0)} ms |`)
}

const allP9 = [...p9.values()].flatMap(row => row.offered)
out.push('\n## Ring totals\n')
out.push('| generator | offered / 12 | mean abs error | mean quality | mean repeated | total u-turns | GraphHopper calls | total wall |')
out.push('|---|---:|---:|---:|---:|---:|---:|---:|')
out.push(`| Phase 3B | ${p3b.length} | ${mean(p3b.map(walk => Math.abs(walk.distance - TARGETS.get(walk.fixture)!))).toFixed(0)} m `
  + `| ${mean(p3b.map(walk => walk.quality)).toFixed(1)} | ${mean(p3b.map(walk => walk.repeatedPercent)).toFixed(2)}% `
  + `| ${p3b.reduce((sum, walk) => sum + walk.uTurns, 0)} | ${offeredPayload.filter(entry => NORMAL.includes(entry.fixture)).reduce((sum, entry) => sum + entry.graphhopperCalls, 0)} `
  + `| ${offeredPayload.filter(entry => NORMAL.includes(entry.fixture)).reduce((sum, entry) => sum + entry.wallMs, 0)} ms |`)
out.push('| Phase 8 (quoted) | 11 | 92 m | 73.8 | 0.00% | 0 | 924 + 64 probes | — |')
out.push(`| Phase 9 S2 | ${allP9.length} | ${mean([...p9].flatMap(([fixture, row]) => row.offered.map(entry => Math.abs(entry.assembled.graphMetres - TARGETS.get(fixture)!)))).toFixed(0)} m `
  + `| ${mean(allP9.map(entry => entry.report.quality.score)).toFixed(1)} | ${mean(allP9.map(entry => entry.report.quality.repeatedPercent)).toFixed(2)}% `
  + `| ${allP9.reduce((sum, entry) => sum + entry.report.quality.uTurnCount, 0)} | 0 `
  + `| ${[...p9.values()].reduce((sum, row) => sum + row.exportMs + row.buildMs + row.searchMs, 0).toFixed(0)} ms |`)

out.push('\n## Phase 9 cost detail\n')
out.push('| fixture | subgraph export ms | graph build ms | search ms | states expanded |')
out.push('|---|---:|---:|---:|---:|')
for (const [fixture, row] of p9) out.push(`| ${fixture} | ${row.exportMs.toFixed(2)} | ${row.buildMs.toFixed(1)} | ${row.searchMs.toFixed(0)} | ${row.expanded} |`)

writeFileSync(new URL('results/compare.md', import.meta.url), out.join('\n') + '\n')
console.log(out.join('\n'))
