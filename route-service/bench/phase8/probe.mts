/**
 * Phase 8 probe capture (P1, P4, P5).
 *
 * Routes a bounded sample through GraphHopper so the cheap field/tree
 * quantities can be checked against what the router actually does:
 *   - start -> anchor, for the improved-seeding and stretch measurements;
 *   - anchor -> anchor, for the pairwise estimator and topology study.
 * The result is written once and reused by the analyser, so estimator work
 * never silently pays for fresh routing.
 */
import { mkdirSync, writeFileSync } from 'node:fs'
import { GraphHopperClient, parseLeg } from '../../src/graphhopper.js'
import { anchorPool, loadFields, pairFeatures, type Node } from './field.mjs'

const gh = new GraphHopperClient(process.env.GH_URL ?? 'http://localhost:8991', 'foot', 20000)
const p8 = loadFields(new URL('network-fields.json', import.meta.url))
const p7 = loadFields(new URL('../phase7/network-fields.json', import.meta.url))
const POOL = Number(process.env.POOL ?? 24)

let calls = 0, wallMs = 0
const routeMetres = async (from: [number, number], to: [number, number]) => {
  calls++
  const began = performance.now()
  const response = await gh.route([from, to], {})
  wallMs += performance.now() - began
  return parseLeg(response.payload).distanceMeters
}

type AnchorProbe = { fixture: string; node: number; lat: number; lon: number; degree: number
  fieldMetres: number; priorFieldMetres: number | null; crow: number; routed: number }
type PairProbe = { fixture: string; a: number; b: number; crow: number; tree: number
  sharedFraction: number; sharedMetres: number; sharedEdges: number; turn: number; routed: number; reverse: number }

const anchors: AnchorProbe[] = []
const pairs: PairProbe[] = []
const pools = new Map<string, Node[]>()

for (const field of p8) {
  const pool = anchorPool(field, { size: POOL })
  pools.set(field.name, pool)
  const prior = p7.find(value => value.name === field.name)
  for (const node of pool) {
    const priorNode = prior?.nodes.find(value => value.node === node.node)
    anchors.push({
      fixture: field.name, node: node.node, lat: node.lat, lon: node.lon, degree: node.degree,
      fieldMetres: node.networkMetres, priorFieldMetres: priorNode?.networkMetres ?? null,
      crow: field.crow(node), routed: await routeMetres(field.start, field.point(node)),
    })
  }
  // Full ordered pair sample for the pool. This is an analysis oracle, priced
  // explicitly in the report; the production design probes only a sparse
  // subset of it, and P6 measures how much of the value that subset keeps.
  for (let i = 0; i < pool.length; i++) for (let j = i + 1; j < pool.length; j++) {
    const a = pool[i], b = pool[j]
    const features = pairFeatures(field, a, b)
    const routed = await routeMetres(field.point(a), field.point(b))
    const reverse = await routeMetres(field.point(b), field.point(a))
    pairs.push({
      fixture: field.name, a: a.node, b: b.node, crow: features.crow, tree: features.tree,
      sharedFraction: features.sharedFraction, sharedMetres: features.sharedMetres,
      sharedEdges: features.sharedEdges, turn: features.turn, routed, reverse,
    })
  }
  console.log(`${field.name}: pool ${pool.length}, pairs ${pool.length * (pool.length - 1) / 2}, calls so far ${calls}`)
}

mkdirSync(new URL('results/', import.meta.url), { recursive: true })
writeFileSync(new URL(`results/probes-${POOL}.json`, import.meta.url), JSON.stringify({
  poolSize: POOL, calls, wallMs,
  pools: [...pools].map(([fixture, pool]) => ({ fixture, nodes: pool })),
  anchors, pairs,
}, null, 2) + '\n')
console.log(`probes: ${calls} GraphHopper calls, ${wallMs.toFixed(0)} ms boundary wall`)
