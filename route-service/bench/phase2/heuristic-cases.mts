/**
 * The four weightings §4 has to separate, over one pair of points.
 *
 * Same endpoints throughout, and a corridor taken from the real generator
 * rather than drawn by hand, so that what differs between the rows is the
 * weighting and nothing else.
 */
import { writeFileSync } from 'node:fs'
import { buildRouteBody } from '../../src/graphhopper.js'
import { avoidanceCustomModel, buildAvoidanceAreas, shortestPathCustomModel } from '../../src/loops/avoidance.js'
import type { LngLat } from '../../src/loops/geo.js'

const GH_URL = process.env.GH_URL ?? 'http://localhost:8991'
const FROM: LngLat = [-4.4816, 54.1506]   // Douglas seafront
const TO: LngLat = [-4.4530, 54.1745]     // Onchan

const route = async (points: LngLat[], customModel?: any) => {
  const response = await fetch(new URL('/route', GH_URL), {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify(buildRouteBody(points, { profile: 'foot', customModel })),
  })
  if (!response.ok) throw new Error(`${response.status} ${await response.text()}`)
  return (await response.json()) as any
}

// The corridor is the ground a plain route over the same pair covers, which is
// the corridor the generator would actually hand the next leg.
const plain = await route([FROM, TO])
const areas = buildAvoidanceAreas([plain.paths[0].points.coordinates as LngLat[]], FROM)
console.log(`corridor: ${areas.length} area(s), ${areas.reduce((s, a) => s + a.geometry.coordinates[0].length, 0)} vertices`)

const cases = [
  { name: 'plain', body: buildRouteBody([FROM, TO], { profile: 'foot' }) },
  { name: 'avoidance 0.2 (relaxed)', body: buildRouteBody([FROM, TO], { profile: 'foot', customModel: avoidanceCustomModel(areas, 0.2) }) },
  { name: 'avoidance 0.05 (strong)', body: buildRouteBody([FROM, TO], { profile: 'foot', customModel: avoidanceCustomModel(areas, 0.05) }) },
  { name: 'distance_influence 2000', body: buildRouteBody([FROM, TO], { profile: 'foot', customModel: shortestPathCustomModel() }) },
]
writeFileSync(new URL('heuristic-cases.json', import.meta.url), JSON.stringify(cases, null, 1))
console.log(`wrote ${cases.length} cases`)
