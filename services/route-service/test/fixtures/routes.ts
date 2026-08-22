import { EARTH_RADIUS_METRES, toRadians, type LngLat } from '../../src/loops/geo.js'

/**
 * Fixture walks, built in metres and converted to coordinates at the end.
 *
 * Every shape here is one the quality engine has to get right: the loops that
 * should be offered, and the four or five ways a "loop" can really be something
 * else. They sit on the Isle of Man so that a fixture and a live route are
 * being measured at the same latitude.
 */
export const FIXTURE_ORIGIN: LngLat = [-4.4816, 54.1506]

/** Exact inverse of the projection the quality engine measures in. */
export function at(eastMetres: number, northMetres: number, origin: LngLat = FIXTURE_ORIGIN): LngLat {
  const lat = origin[1] + (northMetres / EARTH_RADIUS_METRES) / toRadians(1)
  const lng = origin[0] + (eastMetres / (EARTH_RADIUS_METRES * Math.cos(toRadians(origin[1])))) / toRadians(1)
  return [lng, lat]
}

type Metric = [number, number]

/** GraphHopper emits a vertex every few metres; fixtures should too. */
export function polyline(corners: Metric[], spacingMetres = 8): LngLat[] {
  const points: Metric[] = []
  for (let i = 1; i < corners.length; i++) {
    const [ax, ay] = corners[i - 1]
    const [bx, by] = corners[i]
    const length = Math.hypot(bx - ax, by - ay)
    const steps = Math.max(1, Math.round(length / spacingMetres))
    for (let step = 0; step < steps; step++) {
      const t = step / steps
      points.push([ax + (bx - ax) * t, ay + (by - ay) * t])
    }
  }
  points.push(corners[corners.length - 1])
  return points.map(([x, y]) => at(x, y))
}

function ring(radius: number, points = 96, centre: Metric = [0, 0]): Metric[] {
  return Array.from({ length: points + 1 }, (_, i) => {
    const angle = (i / points) * Math.PI * 2
    return [centre[0] + radius * Math.sin(angle), centre[1] + radius * Math.cos(angle)] as Metric
  })
}

/** A clean circular loop of about 3.1 km. Nothing wrong with it. */
export const cleanLoop = polyline(ring(500))

/**
 * The same loop reached down a 60 m lane and returned along it. A shared
 * doorstep is normal and must not read as retracing.
 */
export const sharedStartLoop = polyline([
  [0, -560],
  [0, -500],
  ...ring(500, 96, [0, 0]).slice(48).concat(ring(500, 96, [0, 0]).slice(1, 49)),
  [0, -500],
  [0, -560],
])

/** Out 1.5 km along one path and straight back. The failure this all exists for. */
export const longOutAndBack = polyline([[0, 0], [1500, 0], [0, 0]])

/**
 * Two lobes joined by a 500 m section that has to be walked both ways — the
 * river bridge with no second crossing. Honest, and still not a clean loop.
 */
export const repeatedBridge = polyline([
  ...ring(175, 64, [0, 175]).slice(32).concat(ring(175, 64, [0, 175]).slice(1, 33)),
  [0, -500],
  ...ring(175, 64, [0, -675]),
  [0, -500],
  [0, 0],
])

/** A figure of eight: the route touches itself once, at a crossroads. */
export const simpleCrossing = polyline([
  [0, 0], [400, 400], [800, 0], [400, -400],
  [0, 0], [-400, 400], [-800, 0], [-400, -400], [0, 0],
])

/** 2 km long, 200 m wide: technically a loop, in practice a there-and-back. */
export const narrowElongated = polyline([[0, 0], [2000, 0], [2000, 200], [0, 200], [0, 0]])

/** Two offered loops that are really the same walk eight metres apart. */
export const twinA = polyline(ring(500))
export const twinB = polyline(ring(508))
