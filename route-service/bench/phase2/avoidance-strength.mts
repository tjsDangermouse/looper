/**
 * Phase 2 §12 and §13: what the avoidance multiplier actually buys.
 *
 * Every avoidance call in the corpus was made at 0.05 — a twentyfold weight
 * multiplier. That is a deliberately strong number, and Phase 1 showed it is
 * also the number that costs the landmark heuristic most of its accuracy. The
 * question this answers is not "is 0.05 too strong" in the abstract; it is:
 * for the requests Looper actually makes, how weak could the penalty be and
 * still return *the same path*, and what would the weaker penalty have saved?
 *
 * Each sampled request is re-asked at every multiplier. Identity is the
 * engine's own edge-id sequence, not distance and not a geometry hash: two
 * genuinely different walks can share a distance to the metre, and a hash of
 * coordinates cannot say whether the difference is a re-routed block or a
 * rounding digit.
 *
 * Serial, one request in flight, so a millisecond is a millisecond.
 */
import { readFileSync, readdirSync, writeFileSync } from 'node:fs'
import booleanPointInPolygon from '@turf/boolean-point-in-polygon'
import { point } from '@turf/helpers'
import { buildRouteBody } from '../../src/graphhopper.js'
import { avoidanceCustomModel } from '../../src/loops/avoidance.js'
import type { LngLat } from '../../src/loops/geo.js'

const GH_URL = process.env.GH_URL ?? 'http://localhost:8991'
/** The production strength, and the value every other row is compared against. */
const REFERENCE = 0.05
const MULTIPLIERS = [1.0, 0.5, 0.2, 0.1, 0.05, 0.02]
const SAMPLE = Number(process.env.SAMPLE ?? 150)

const dir = new URL('corpus/', import.meta.url)
type Record_ = { purpose: string; class: string; points: LngLat[]; model: any }
const avoidance: Record_[] = readdirSync(dir).filter(f => f.endsWith('.jsonl')).sort()
  .flatMap(f => readFileSync(new URL(f, dir), 'utf8').trim().split('\n').filter(Boolean).map(l => JSON.parse(l)))
  .filter((r: any) => r.points && r.class === 'avoid-strong')

// Evenly spaced through the corpus rather than the first N, so the sample is
// not all early legs of one fixture — the corridors grow as a walk is built up,
// and a sample of first legs would be a sample of the easiest ones.
const step = Math.max(1, Math.floor(avoidance.length / SAMPLE))
const sampled = avoidance.filter((_, i) => i % step === 0).slice(0, SAMPLE)
console.log(`${sampled.length} of ${avoidance.length} strong-avoidance calls, at ${MULTIPLIERS.join(', ')}\n`)

const ask = async (points: LngLat[], model: any) => {
  const began = performance.now()
  const response = await fetch(new URL('/route', GH_URL), {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify(buildRouteBody(points, { profile: 'foot', customModel: model })),
  })
  const ms = performance.now() - began
  if (!response.ok) return undefined
  const payload = (await response.json()) as any
  const path = payload.paths[0]
  return {
    ms,
    visited: payload.hints?.['visited_nodes.sum'] ?? 0,
    distance: path.distance as number,
    edges: (path.details?.edge_id ?? []).map((d: any[]) => d[2]).join(',') as string,
    coordinates: path.points.coordinates as LngLat[],
  }
}

/**
 * How much of the returned walk lies on ground the request asked it to avoid,
 * as a fraction of its length. Measured on the geometry rather than on edge
 * ids because the corridors are polygons: an edge is in or out by where it
 * runs, and that is the question the custom model itself asks.
 */
const overlapFraction = (coordinates: LngLat[], areas: any[]) => {
  if (!areas.length || coordinates.length < 2) return 0
  let inside = 0
  let total = 0
  for (let i = 1; i < coordinates.length; i++) {
    const a = coordinates[i - 1], b = coordinates[i]
    const length = Math.hypot((b[0] - a[0]) * Math.cos((a[1] * Math.PI) / 180), b[1] - a[1]) * 111320
    const middle = point([(a[0] + b[0]) / 2, (a[1] + b[1]) / 2])
    total += length
    if (areas.some(area => booleanPointInPolygon(middle, area as any))) inside += length
  }
  return total > 0 ? inside / total : 0
}

type Row = { multiplier: number; calls: number; ms: number; visited: number; sameAsReference: number; distance: number; overlap: number }
const rows = new Map<number, Row>(MULTIPLIERS.map(m => [m, { multiplier: m, calls: 0, ms: 0, visited: 0, sameAsReference: 0, distance: 0, overlap: 0 }]))
/** The weakest multiplier that still gave the reference path, per request. */
const weakestSame: number[] = []

for (const record of sampled) {
  const areas = (record.model?.areas?.features ?? []) as any[]
  const results = new Map<number, Awaited<ReturnType<typeof ask>>>()
  for (const multiplier of MULTIPLIERS) {
    const model = areas.length ? avoidanceCustomModel(areas, multiplier) : undefined
    await ask(record.points, model)                                    // warm
    results.set(multiplier, await ask(record.points, model))
  }
  const reference = results.get(REFERENCE)
  if (!reference) continue
  let weakest = REFERENCE
  for (const multiplier of MULTIPLIERS) {
    const result = results.get(multiplier)
    if (!result) continue
    const row = rows.get(multiplier)!
    row.calls++
    row.ms += result.ms
    row.visited += result.visited
    row.distance += result.distance
    row.overlap += overlapFraction(result.coordinates, areas)
    if (result.edges === reference.edges) {
      row.sameAsReference++
      // "Weakest" means the largest multiplier: priority divides the weight,
      // so a bigger number is a lighter penalty.
      if (multiplier > weakest) weakest = multiplier
    }
  }
  weakestSame.push(weakest)
}

console.log('| multiplier | calls | total ms | mean ms | mean visited | same path as 0.05 | mean distance m | mean overlap with avoided ground |')
console.log('|---:|---:|---:|---:|---:|---:|---:|---:|')
for (const multiplier of MULTIPLIERS) {
  const row = rows.get(multiplier)!
  console.log(`| ${multiplier} | ${row.calls} | ${row.ms.toFixed(0)} | ${(row.ms / row.calls).toFixed(2)} | ${Math.round(row.visited / row.calls)} | ${((row.sameAsReference / row.calls) * 100).toFixed(1)}% | ${Math.round(row.distance / row.calls)} | ${((row.overlap / row.calls) * 100).toFixed(2)}% |`)
}

console.log('\nWeakest multiplier that still returns the 0.05 path, per request:\n')
console.log('| weakest that matches | requests | share |')
console.log('|---|---:|---:|')
for (const multiplier of [...MULTIPLIERS].sort((a, b) => b - a)) {
  const n = weakestSame.filter(w => w === multiplier).length
  if (n) console.log(`| ${multiplier} | ${n} | ${((n / weakestSame.length) * 100).toFixed(1)}% |`)
}

writeFileSync(new URL('results/avoidance-strength.json', import.meta.url),
  JSON.stringify({ sampled: sampled.length, reference: REFERENCE, rows: [...rows.values()], weakestSame }, null, 1))
