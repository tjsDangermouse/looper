/**
 * The low-level fixture set for the GraphHopper equivalence work.
 *
 * One file builds the fixtures and both sides of the comparison read it, so
 * the HTTP server and the direct Java harness are answering byte-identical
 * request bodies. The avoidance cases need a routed leg to draw a corridor
 * around, so they are generated once here and baked in rather than rebuilt on
 * each side, where two runs of turf could disagree in the last decimal and
 * make an engine difference out of a geometry difference.
 */
import { writeFileSync } from 'node:fs'
import { buildAvoidanceAreas, avoidanceCustomModel, shortestPathCustomModel } from '../../src/loops/avoidance.js'
import type { LngLat } from '../../src/loops/geo.js'

const BASE = process.env.GH_URL ?? 'http://localhost:8989'
const PROFILE = 'foot'

/** Exactly what src/graphhopper.ts sends, so a fixture is a real Looper leg. */
const body = (points: LngLat[], customModel?: unknown) => ({
  points: points.map(([lng, lat]) => [lng, lat]),
  profile: PROFILE,
  'ch.disable': true,
  points_encoded: false,
  instructions: true,
  elevation: false,
  calc_points: true,
  locale: 'en',
  details: ['street_name', 'road_class', 'edge_id'],
  snap_preventions: ['ferry'],
  ...(customModel ? { custom_model: customModel } : {}),
})

/** Isle of Man ground, chosen for the different things that can go wrong on it. */
const P = {
  douglasSeafront:  [-4.4816, 54.1506],
  douglasInland:    [-4.4693, 54.1602],
  douglasNorth:     [-4.4750, 54.1650],
  onchan:           [-4.4530, 54.1745],
  promenadeEast:    [-4.4700, 54.1530],
  laxey:            [-4.3990, 54.2280],
  dhoon:            [-4.3830, 54.2540],
  peelA:            [-4.7020, 54.2250],
  peelB:            [-4.6900, 54.2320],
  ramseyA:          [-4.3860, 54.3230],
  ramseyB:          [-4.3700, 54.3300],
  // Open moorland well away from any way: the snap has a long way to travel,
  // which is where a location index and a bespoke nearest-edge search part company.
  openSpace:        [-4.5600, 54.2100],
  castletown:       [-4.6540, 54.0740],
} as const satisfies Record<string, LngLat>

type Fixture = { name: string; body: ReturnType<typeof body> }
const fixtures: Fixture[] = []
const add = (name: string, points: LngLat[], customModel?: unknown) =>
  fixtures.push({ name, body: body(points, customModel) })

// --- A to B -------------------------------------------------------------
add('ab-douglas-short',   [P.douglasSeafront, P.douglasInland])
add('ab-douglas-onchan',  [P.douglasSeafront, P.onchan])
add('ab-promenade',       [P.douglasSeafront, P.promenadeEast])
add('ab-laxey-dhoon',     [P.laxey, P.dhoon])
add('ab-peel',            [P.peelA, P.peelB])
add('ab-ramsey',          [P.ramseyA, P.ramseyB])
add('ab-open-space-snap', [P.openSpace, P.laxey])
add('ab-long-island',     [P.douglasSeafront, P.peelA])

// --- via routes ---------------------------------------------------------
add('via-3pt', [P.douglasSeafront, P.douglasInland, P.onchan])
add('via-4pt', [P.douglasSeafront, P.douglasInland, P.onchan, P.douglasNorth])
add('via-5pt-loopish', [P.douglasSeafront, P.douglasInland, P.onchan, P.douglasNorth, P.douglasSeafront])

// --- the lower-bound model ----------------------------------------------
add('cm-distance-influence', [P.douglasSeafront, P.onchan], shortestPathCustomModel())

// --- avoidance, drawn round real routed legs ----------------------------
const post = async (b: unknown) => {
  const r = await fetch(`${BASE}/route`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(b) })
  const j: any = await r.json()
  if (!r.ok) throw new Error(`${r.status} ${JSON.stringify(j).slice(0, 300)}`)
  return j
}

const corridorFor = async (points: LngLat[]) => {
  const legs: LngLat[][] = []
  for (let i = 1; i < points.length; i++) {
    const j = await post(body([points[i - 1], points[i]]))
    legs.push(j.paths[0].points.coordinates as LngLat[])
  }
  return buildAvoidanceAreas(legs, points[0])
}

// One walked leg avoided, at both strengths — the ordinary retry pair.
const oneLeg = await corridorFor([P.douglasSeafront, P.onchan])
add('avoid-1leg-strong',  [P.douglasSeafront, P.onchan], avoidanceCustomModel(oneLeg))
add('avoid-1leg-relaxed', [P.douglasSeafront, P.onchan], avoidanceCustomModel(oneLeg, 0.2))

// Three walked legs: the polygon count a mid-generation candidate really carries.
const threeLegs = await corridorFor([P.douglasSeafront, P.douglasInland, P.onchan, P.douglasNorth])
add('avoid-3leg-strong', [P.douglasSeafront, P.onchan], avoidanceCustomModel(threeLegs))
add('avoid-3leg-via',    [P.douglasSeafront, P.douglasNorth, P.onchan], avoidanceCustomModel(threeLegs))

// Avoidance across a longer, rural leg, where corridors are sparser.
const ruralLegs = await corridorFor([P.laxey, P.dhoon])
add('avoid-rural', [P.laxey, P.dhoon], avoidanceCustomModel(ruralLegs))

const counts = fixtures.map(f => {
  const cm = (f.body as any).custom_model
  return `${f.name}${cm?.areas ? ` (${cm.areas.features.length} areas)` : ''}`
})
writeFileSync(new URL('fixtures.json', import.meta.url), JSON.stringify(fixtures, null, 1))
console.log(`wrote ${fixtures.length} fixtures:\n  ${counts.join('\n  ')}`)
