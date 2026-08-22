import type { Feature, Polygon } from 'geojson'
import { AVOID_PRIORITY, RELAXED_AVOID_PRIORITY, avoidanceCustomModel, buildAvoidanceAreas } from './avoidance.js'
import { shapeToLegPoints, type CandidateShape } from './candidates.js'
import type { LngLat } from './geo.js'
import { GraphHopperError, type GraphHopperLeg, type GraphHopperStep } from '../graphhopper.js'

/**
 * Routing one candidate, a leg at a time.
 *
 * Each leg is an ordinary point-to-point request. What makes the result a loop
 * rather than a there-and-back is that every leg after the first is handed the
 * ground the earlier legs already covered, weighted twenty times against.
 */

export type LegRouter = (points: LngLat[], customModel: ReturnType<typeof avoidanceCustomModel>) => Promise<GraphHopperLeg>

export type RoutedLeg = GraphHopperLeg & {
  /** True when the leg was routed under the reduced penalty after a failure. */
  relaxed: boolean
  avoidanceAreaCount: number
}

export type RoutedCandidate = {
  shape: CandidateShape
  legs: RoutedLeg[]
  coordinates: LngLat[]
  steps: GraphHopperStep[]
  distanceMeters: number
  durationSeconds: number
  legDistances: number[]
}

export type SequentialRoutingOptions = {
  corridorHalfWidthMetres?: number
  startExclusionMetres?: number
  strongPriority?: number
  relaxedPriority?: number
  /**
   * Abandon a candidate as soon as it is hopeless, rather than paying for the
   * remaining legs. Distance overshoot is the cheapest signal we have.
   */
  abandonAboveMetres?: number
  signal?: AbortSignal
}

/**
 * Returns undefined when the candidate cannot be made into a loop. It never
 * falls back to routing without avoidance: a route that ignores the corridors
 * is exactly the out-and-back this whole design exists to refuse.
 */
export async function routeCandidateSequentially(
  start: LngLat,
  shape: CandidateShape,
  route: LegRouter,
  options: SequentialRoutingOptions = {},
): Promise<RoutedCandidate | undefined> {
  const points = shapeToLegPoints(start, shape)
  const walked: LngLat[][] = []
  const legs: RoutedLeg[] = []
  let running = 0

  for (let index = 0; index + 1 < points.length; index++) {
    options.signal?.throwIfAborted()
    const areas: Feature<Polygon>[] = walked.length
      ? buildAvoidanceAreas(walked, start, {
          halfWidthMetres: options.corridorHalfWidthMetres,
          startExclusionMetres: options.startExclusionMetres,
        })
      : []
    const pair: LngLat[] = [points[index], points[index + 1]]

    let leg: GraphHopperLeg | undefined
    let relaxed = false
    try {
      leg = await route(pair, avoidanceCustomModel(areas, options.strongPriority ?? AVOID_PRIORITY))
    } catch (error) {
      if (!(error instanceof GraphHopperError) || error.kind === 'transport') throw error
      // One retry for this leg only, still penalised, just less absolutely.
      if (!areas.length) return undefined
      relaxed = true
      try {
        leg = await route(pair, avoidanceCustomModel(areas, options.relaxedPriority ?? RELAXED_AVOID_PRIORITY))
      } catch (retryError) {
        if (!(retryError instanceof GraphHopperError) || retryError.kind === 'transport') throw retryError
        return undefined
      }
    }

    running += leg.distanceMeters
    if (options.abandonAboveMetres && running > options.abandonAboveMetres) return undefined
    legs.push({ ...leg, relaxed, avoidanceAreaCount: areas.length })
    walked.push(leg.coordinates)
  }

  const joined = joinLegGeometries(legs)
  return {
    shape,
    legs,
    ...joined,
    legDistances: legs.map(leg => leg.distanceMeters),
  }
}

/**
 * Stitch the legs into one walk.
 *
 * Consecutive legs meet at the same snapped point, so the duplicate is dropped;
 * the "arrive at destination" each leg ends with is dropped too, except on the
 * last, where arriving is the point. Step point indices are rebased onto the
 * joined line so the walk screen can still find a turn's position.
 */
export function joinLegGeometries(legs: Array<Pick<GraphHopperLeg, 'coordinates' | 'steps' | 'distanceMeters' | 'durationSeconds'>>): {
  coordinates: LngLat[]
  steps: GraphHopperStep[]
  distanceMeters: number
  durationSeconds: number
} {
  const coordinates: LngLat[] = []
  const steps: GraphHopperStep[] = []
  let distanceMeters = 0
  let durationSeconds = 0

  legs.forEach((leg, legIndex) => {
    const joins = coordinates.length > 0 && samePoint(coordinates[coordinates.length - 1], leg.coordinates[0])
    // Index of this leg's first point once it is in the joined line.
    const offset = joins ? coordinates.length - 1 : coordinates.length
    coordinates.push(...(joins ? leg.coordinates.slice(1) : leg.coordinates))

    const last = legIndex === legs.length - 1
    for (const step of leg.steps) {
      const arrival = step.sign === 4 || step.sign === 5
      if (arrival && !last) continue
      steps.push({
        ...step,
        startIndex: step.startIndex === undefined ? undefined : step.startIndex + offset,
        endIndex: step.endIndex === undefined ? undefined : step.endIndex + offset,
      })
    }
    distanceMeters += leg.distanceMeters
    durationSeconds += leg.durationSeconds
  })

  return { coordinates, steps, distanceMeters, durationSeconds }
}

const samePoint = (a: LngLat, b: LngLat) => Math.abs(a[0] - b[0]) < 1e-9 && Math.abs(a[1] - b[1]) < 1e-9
