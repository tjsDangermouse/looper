/** Why a fixture offers fewer than three: how many families the search reaches. */
import { bearingOctant, mutualSharedFraction, selectDiverseRoutes } from '../../src/loops/diversity.js'
import { STARTS } from '../phase8/field.mjs'
import { loadSubgraphs, buildSearchGraph } from './graph.mjs'
import { beamSearch, objectiveFor, rootOf } from './search.mjs'
import { judge } from './walk.mjs'

const BEAM = Number(process.env.BEAM ?? 300)
const PER_FAMILY = Number(process.env.PER_FAMILY ?? 40)
const WANTED = Number(process.env.WANTED ?? 1e9)
for (const raw of loadSubgraphs(new URL('subgraphs.json', import.meta.url))) {
  const graph = buildSearchGraph(raw)
  const { root } = rootOf(graph)
  const start = STARTS.get(graph.name)!
  const { walks, stats } = beamSearch(graph, {
    objective: objectiveFor(graph.targetMetres), budget: Infinity,
    beam: BEAM, band: Number(process.env.BAND ?? 100), perNode: Number(process.env.PER_NODE ?? 3),
    perFamily: PER_FAMILY, wanted: WANTED, minCompactness: 0.2,
  })
  const judged = walks.map(walk => judge(graph, walk, root, start))
  const passes = judged.filter(entry => entry.report.pass)
  const byOctant = new Map<number, number>()
  for (const entry of passes) byOctant.set(bearingOctant(entry.bearing), (byOctant.get(bearingOctant(entry.bearing)) ?? 0) + 1)
  const selectable = passes.map(entry => ({ ...entry, coordinates: entry.assembled.coordinates, quality: entry.report.quality, totalMetres: entry.assembled.graphMetres }))
  const offered = selectDiverseRoutes(selectable, 3)
  console.log(`${graph.name.padEnd(13)} found ${String(walks.length).padStart(5)} pass ${String(passes.length).padStart(5)} offered ${offered.length}  ${stats.wallMs.toFixed(0)}ms`)
  console.log(`   pass octants: ${[...byOctant].sort((a, b) => a[0] - b[0]).map(([o, c]) => `${o}:${c}`).join(' ')}`)
  // Why the second and third were refused.
  const ranked = [...selectable].sort((a, b) => b.quality.score - a.quality.score)
  const best = ranked[0]
  if (best) {
    const overlaps = ranked.slice(1, 400).map(entry => mutualSharedFraction(
      { coordinates: best.assembled.coordinates, quality: best.report.quality, bearing: best.bearing, traversals: best.traversals, totalMetres: best.assembled.graphMetres },
      { coordinates: entry.assembled.coordinates, quality: entry.report.quality, bearing: entry.bearing, traversals: entry.traversals, totalMetres: entry.assembled.graphMetres }))
    overlaps.sort((a, b) => a - b)
    console.log(`   overlap with best: min ${(100 * (overlaps[0] ?? 1)).toFixed(1)}%  p25 ${(100 * (overlaps[Math.floor(overlaps.length * 0.25)] ?? 1)).toFixed(1)}%  median ${(100 * (overlaps[overlaps.length >> 1] ?? 1)).toFixed(1)}%  (55% is the bar)`)
  }
}
