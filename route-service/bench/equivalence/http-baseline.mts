/**
 * Gate 1A: the canonical baseline, measured against the warm GraphHopper
 * container exactly as the route service reaches it.
 *
 * Emits the same envelope shape the Java harness writes, so compare.mts can
 * read both without knowing which side it is looking at.
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { createHash } from 'node:crypto'

const BASE = process.env.GH_URL ?? 'http://localhost:8989'
/** Which engine answered, so two runs cannot overwrite each other's numbers. */
const OUT = process.env.OUT ?? 'results-http.json'
const LABEL = process.env.LABEL ?? 'http-server'
const REPEATS = Number(process.env.REPEATS ?? 7)
const fixtures = JSON.parse(readFileSync(new URL('fixtures.json', import.meta.url), 'utf8')) as Array<{ name: string; body: any }>

const post = async (body: unknown) => {
  const began = process.hrtime.bigint()
  const response = await fetch(`${BASE}/route`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })
  const ms = Number(process.hrtime.bigint() - began) / 1e6
  const payload: any = await response.json()
  return { ok: response.ok, ms, payload }
}

const round6 = (v: number) => Math.round(v * 1e6) / 1e6
/** The same fingerprint the Java side computes, over the same six decimals. */
const fingerprint = (coords: number[][]) =>
  createHash('sha256').update(coords.map(([lng, lat]) => `${round6(lng)},${round6(lat)}`).join(';') + ';').digest('hex').slice(0, 16)

const results: any[] = []
for (const { name, body } of fixtures) {
  const row: any = { name }
  const warm = await post(body)
  if (!warm.ok) {
    row.error = warm.payload?.message ?? 'request failed'
    results.push(row)
    console.log(`${name.padEnd(24)} ERROR ${row.error}`)
    continue
  }
  const times: number[] = []
  let last = warm
  for (let i = 0; i < REPEATS; i++) { last = await post(body); times.push(last.ms) }
  times.sort((a, b) => a - b)

  const path = last.payload.paths[0]
  row.ms = times[Math.floor(times.length / 2)]
  row.visitedNodes = last.payload?.hints?.['visited_nodes.sum'] ?? -1
  row.distance = path.distance
  row.weight = path.weight
  row.timeMs = path.time
  row.pointCount = path.points.coordinates.length
  row.geometryHash = fingerprint(path.points.coordinates)
  row.snappedWaypoints = (path.snapped_waypoints?.coordinates ?? []).map(([lng, lat]: number[]) => [round6(lng), round6(lat)])
  if (path.details?.edge_id) row.edgeIds = path.details.edge_id.map((d: any[]) => d[2])
  if (path.details?.road_class) row.roadClasses = path.details.road_class.map((d: any[]) => String(d[2]))
  row.instructionCount = path.instructions?.length ?? 0
  results.push(row)
  console.log(`${name.padEnd(24)} ${String(row.visitedNodes).padStart(7)}n ${row.ms.toFixed(1).padStart(7)}ms ${row.distance.toFixed(1).padStart(10)}m`)
}

writeFileSync(new URL(OUT, import.meta.url), JSON.stringify({ source: LABEL, results }, null, 1))
console.log(`\nwrote ${OUT} (${results.length} cases)`)
