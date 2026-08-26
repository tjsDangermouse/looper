import type { LoopRequest } from '../src/loops/generate.js'
import { BENCH_ORIGIN, NETWORKS, pointAt, type Network } from './network.js'

/**
 * The benchmark matrix.
 *
 * One case per thing that can go wrong, not one case per code path. A change
 * that makes dense-grid loops one percent tidier and stops finding anything at
 * all on a coastal start has not improved the generator, and the only way to
 * see that is to keep the awkward ground in the table next to the easy ground.
 *
 * Every case is deterministic: same network, same seed, same request, same
 * answer, run to run and machine to machine.
 */

export type Scenario = {
  id: string
  /** One line, so the results table can be read without opening this file. */
  about: string
  network: keyof typeof NETWORKS
  request: LoopRequest
  /**
   * Cases we expect to yield nothing — an impossible waypoint set, ground with
   * no loop at the requested length. A run that starts returning routes here
   * is a regression in honesty, not an improvement in coverage.
   */
  expectsNoRoutes?: boolean
}

const start = { lng: BENCH_ORIGIN[0], lat: BENCH_ORIGIN[1] }

/** A point `east`/`north` metres from the benchmark origin, as a waypoint. */
const near = (eastMetres: number, northMetres: number) => {
  const [lng, lat] = pointAt(BENCH_ORIGIN, eastMetres, northMetres)
  return { lng, lat }
}

const base: LoopRequest = { start, mode: 'distance', distanceKm: 5, units: 'km', variation: 0 }

export const SCENARIOS: Scenario[] = [
  {
    id: 'urban-5km',
    about: 'Dense town grid, 5 km, no waypoints — the easy case everything else is measured against',
    network: 'dense-grid',
    request: { ...base },
  },
  {
    id: 'urban-2km-short',
    about: 'Dense town grid, 2 km — short loops have less room to absorb a bad corner',
    network: 'dense-grid',
    request: { ...base, distanceKm: 2 },
  },
  {
    id: 'urban-12km-long',
    about: 'Dense town grid, 12 km — long loops cost the most engine calls per candidate',
    network: 'dense-grid',
    request: { ...base, distanceKm: 12 },
  },
  {
    id: 'urban-time-60min',
    about: 'Dense town grid, duration mode, 60 minutes at the default pace',
    network: 'dense-grid',
    request: { start, mode: 'time', durationMinutes: 60, units: 'km', variation: 0 },
  },
  {
    id: 'urban-time-paced',
    about: 'Duration mode with a walker-supplied pace, which moves the distance target',
    network: 'dense-grid',
    request: { start, mode: 'time', durationMinutes: 45, units: 'km', variation: 0, walkingPaceMinutesPerKm: 9 },
  },
  {
    id: 'urban-variation-3',
    about: 'Same request, third refresh — a different deterministic candidate set',
    network: 'dense-grid',
    request: { ...base, variation: 3 },
  },
  {
    id: 'suburban-5km',
    about: 'Suburban lattice with cul-de-sacs, 5 km — where spurs and join pullbacks come from',
    network: 'suburban',
    request: { ...base },
  },
  {
    id: 'suburban-8km',
    about: 'Suburban lattice, 8 km',
    network: 'suburban',
    request: { ...base, distanceKm: 8 },
  },
  {
    id: 'rural-6km',
    about: 'Sparse rural lanes, 6 km — few circuits exist and they have to be found',
    network: 'sparse-rural',
    request: { ...base, distanceKm: 6 },
  },
  {
    id: 'rural-3km-tight',
    about: 'Sparse rural lanes, 3 km — often genuinely has no clean loop at this length',
    network: 'sparse-rural',
    request: { ...base, distanceKm: 3 },
  },
  {
    id: 'coastal-5km',
    about: 'Seafront start: half the compass is sea, so half the candidate bearings are wasted',
    network: 'coastal',
    request: { ...base },
  },
  {
    id: 'bridge-4km',
    about: 'Two banks, one bridge — any loop using both banks walks the bridge twice',
    network: 'bridge-chokepoint',
    request: { ...base, distanceKm: 4 },
  },
  {
    id: 'urban-exclusions',
    about: 'Refresh that must avoid the three loops already on screen',
    network: 'dense-grid',
    request: {
      ...base,
      variation: 1,
      exclude: [
        [[start.lng, start.lat], [pointAt(BENCH_ORIGIN, 800, 0)[0], pointAt(BENCH_ORIGIN, 800, 0)[1]], [start.lng, start.lat]],
      ],
    },
  },
  {
    id: 'waypoint-one-urban',
    about: 'One pin, dense grid, comfortably inside the plan',
    network: 'dense-grid',
    request: { ...base, waypoints: [near(700, 500)] },
  },
  {
    id: 'waypoint-two-ordered',
    about: 'Two ordered pins that must be visited in the order they were added',
    network: 'dense-grid',
    request: { ...base, distanceKm: 6, waypoints: [near(900, 200), near(300, 900)] },
  },
  {
    id: 'waypoint-three-ordered',
    about: 'Three ordered pins — the case a single global guide point handles worst',
    network: 'dense-grid',
    request: { ...base, distanceKm: 8, waypoints: [near(1100, 0), near(700, 900), near(-500, 600)] },
  },
  {
    id: 'waypoint-suburban',
    about: 'A pin in suburbia, where it may well land in a cul-de-sac',
    network: 'suburban',
    request: { ...base, distanceKm: 6, waypoints: [near(1200, 800)] },
  },
  {
    id: 'waypoint-across-bridge',
    about: 'A pin on the far bank: the out-and-back over the bridge is structural, not sloppy',
    network: 'bridge-chokepoint',
    request: { ...base, distanceKm: 5, waypoints: [near(400, 900)] },
  },
  {
    id: 'waypoint-narrow-spur',
    about: 'A coastal pin at the end of a promenade, forcing a there-and-back section',
    network: 'coastal',
    request: { ...base, distanceKm: 5, waypoints: [near(2600, 100)] },
  },
  {
    id: 'waypoint-impossible',
    about: 'A pin far beyond the plan — must refuse with expectationExceeded, not invent a walk',
    network: 'dense-grid',
    request: { start, mode: 'distance', distanceKm: 2, units: 'km', variation: 0, waypoints: [near(2500, 2000)] },
    expectsNoRoutes: true,
  },
]

export const networkFor = (scenario: Scenario): Network => NETWORKS[scenario.network]()
