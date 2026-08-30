/**
 * Does the bounded search graph actually contain the walks Looper already
 * offers? If a reduction removes a single edge of an accepted Phase 3B walk,
 * the search built on it can never find that walk, and every later result
 * would be measuring the reduction rather than the search.
 */
import { loadSubgraphs, buildSearchGraph } from './graph.mjs'
import { loadWalks } from './topology.mjs'

const NORMAL = ['douglas-5km', 'douglas-3km', 'peel-5km', 'onchan-5km']
const raws = loadSubgraphs(new URL('subgraphs.json', import.meta.url))
const walks = loadWalks(new URL('corpus-P9/', import.meta.url), NORMAL)

console.log('| fixture | walks | edges in walk | in exported region | in 2-core | in search graph | max home m of walk |')
console.log('|---|---:|---:|---:|---:|---:|---:|')
for (const name of NORMAL) {
  const raw = raws.find(entry => entry.name === name)!
  const graph = buildSearchGraph(raw)
  const exported = new Set(raw.edges.map(edge => edge[1]))
  const core = new Set(graph.edges.flatMap(edge => edge.physical.map(([id]) => id)))
  // Network distance home of the far end of every physical edge the walk used.
  const homeOf = new Map<number, number>()
  raw.edges.forEach(edge => {
    const from = raw.nodes.find(node => node[0] === edge[2]), to = raw.nodes.find(node => node[0] === edge[3])
    const reach = Math.max(from?.[3] ?? 0, to?.[3] ?? 0)
    homeOf.set(edge[1], Math.max(homeOf.get(edge[1]) ?? 0, reach))
  })
  const set = walks.filter(walk => walk.fixture === name && walk.offered)
  let total = 0, inRegion = 0, inCore = 0, maxHome = 0
  for (const walk of set) {
    const ids = new Set(walk.passes.map(([id]) => id))
    total += ids.size
    for (const id of ids) {
      if (exported.has(id)) inRegion++
      if (core.has(id)) inCore++
      maxHome = Math.max(maxHome, homeOf.get(id) ?? 0)
    }
  }
  console.log(`| ${name} | ${set.length} | ${total} | ${inRegion} (${(100 * inRegion / total).toFixed(1)}%) | ${inCore} (${(100 * inCore / total).toFixed(1)}%) | ${inCore} | ${maxHome.toFixed(0)} |`)
}

// Where the start sits relative to the 2-core, per fixture.
console.log('\nstart node against the 2-core:')
for (const name of NORMAL) {
  const graph = buildSearchGraph(raws.find(entry => entry.name === name)!)
  const inCore = (graph.arcs[graph.start]?.length ?? 0) > 0
  // Nearest node that does carry search arcs, by network distance from start.
  let nearest = Infinity, nearestNode = -1
  for (let node = 0; node < graph.arcs.length; node++) {
    if (!graph.arcs[node].length) continue
    if (graph.home[node] < nearest) { nearest = graph.home[node]; nearestNode = node }
  }
  console.log(`  ${name.padEnd(13)} start in 2-core: ${String(inCore).padEnd(5)}  nearest 2-core node ${graph.id[nearestNode]} at ${nearest.toFixed(1)} m`)
}
