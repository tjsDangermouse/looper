import type { Feature, Polygon } from 'geojson'
import { AVOID_PRIORITY, RELAXED_AVOID_PRIORITY, avoidanceCustomModel, buildAvoidanceAreas } from './avoidance.js'
import { shapeToLegPoints, type CandidateShape } from './candidates.js'
import { bearingBetween, destination, haversine, normaliseBearing, type LngLat } from './geo.js'
import { GraphHopperError, type GraphHopperLeg, type GraphHopperStep } from '../graphhopper.js'

/**
 * Routing one candidate, a leg at a time.
 *
 * Each leg is an ordinary point-to-point request. What makes the result a loop
 * rather than a there-and-back is that every leg after the first is handed the
 * ground the earlier legs already covered, weighted twenty times against.
 */

/**
 * No single leg of a four-leg ring should be half the whole walk. Past that,
 * the avoidance penalty is no longer nudging the route round a corner — it is
 * sending the walk somewhere else entirely.
 */
export const LEG_BUDGET_SHARE = 0.5

/**
 * A candidate waypoint is just a point dropped on a circle, with no idea what
 * street layout is underneath it. Where it lands inside a cul-de-sac, the leg
 * arriving there and the leg leaving it are forced back down the same short
 * stub to reach it — not because the ring is a bad shape, but because that
 * one point happens to sit somewhere only reachable one way. The tell is at
 * the join: the walk arrives heading one way and immediately leaves heading
 * almost the opposite way, at the same spot. A corner in open country never
 * looks like this; a cul-de-sac suburb produces it constantly.
 */
export const JOIN_TURN_THRESHOLD_DEGREES = 150
/** How far to pull a dead-ending waypoint back toward the start, once, before giving up on it. */
export const WAYPOINT_PULLBACK_SCALE = 0.65
/** How far from a leg's own end to sample its direction of travel there. */
const EDGE_BEARING_WINDOW_METRES = 30

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
  /**
   * The length beyond which a single leg is no longer shaping a loop but being
   * dictated to by the avoidance penalty. See the retry below.
   */
  legBudgetMetres?: number
  /** See JOIN_TURN_THRESHOLD_DEGREES. Overridable for the tuning panel only. */
  joinTurnThresholdDegrees?: number
  /** See WAYPOINT_PULLBACK_SCALE. Overridable for the tuning panel only. */
  waypointPullbackScale?: number
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

    // GraphHopper never *refuses* a penalised corridor — it walks round it. In a
    // dense grid "round it" is the next street; on a single road up a valley it
    // can be six kilometres to dodge nine hundred metres, and the loop comes
    // back at twice the length asked for and is thrown away for it. So the one
    // retry each leg gets is spent here too, not only on an outright failure.
    if (!relaxed && areas.length && options.legBudgetMetres && leg.distanceMeters > options.legBudgetMetres) {
      try {
        const cheaper = await route(pair, avoidanceCustomModel(areas, options.relaxedPriority ?? RELAXED_AVOID_PRIORITY))
        if (cheaper.distanceMeters < leg.distanceMeters) {
          leg = cheaper
          relaxed = true
        }
      } catch (error) {
        if (!(error instanceof GraphHopperError) || error.kind === 'transport') throw error
        // Keep the strongly penalised leg: it routed, it is just a long way round.
      }
    }

    // The join this leg's *start* sits on is the previous leg's arrival, which
    // is already routed and committed. Catching a dead end here means undoing
    // that leg too: both legs meeting at the bad waypoint get re-routed around
    // a version of it pulled back toward the start, once. A waypoint used only
    // as this leg's destination is caught on the next iteration instead, by the
    // same check running on the leg after it — every waypoint but the first and
    // last is somebody's arrival and somebody's departure.
    if (index > 0) {
      const previous = legs[legs.length - 1]
      const turn = turnAngleDegrees(edgeBearing(previous.coordinates, false), edgeBearing(leg.coordinates, true))
      if (turn > (options.joinTurnThresholdDegrees ?? JOIN_TURN_THRESHOLD_DEGREES)) {
        const original = points[index]
        const pullbackScale = options.waypointPullbackScale ?? WAYPOINT_PULLBACK_SCALE
        const pulledIn = destination(start, haversine(start, original) * pullbackScale, bearingBetween(start, original))
        const areasBeforePrevious = buildAvoidanceAreas(walked.slice(0, -1), start, {
          halfWidthMetres: options.corridorHalfWidthMetres,
          startExclusionMetres: options.startExclusionMetres,
        })
        try {
          const redonePrevious = await route(
            [points[index - 1], pulledIn],
            avoidanceCustomModel(areasBeforePrevious, previous.relaxed ? (options.relaxedPriority ?? RELAXED_AVOID_PRIORITY) : (options.strongPriority ?? AVOID_PRIORITY)),
          )
          const walkedWithRedone = [...walked.slice(0, -1), redonePrevious.coordinates]
          const areasForCurrent = buildAvoidanceAreas(walkedWithRedone, start, {
            halfWidthMetres: options.corridorHalfWidthMetres,
            startExclusionMetres: options.startExclusionMetres,
          })
          const redoneCurrent = await route(
            [pulledIn, points[index + 1]],
            avoidanceCustomModel(areasForCurrent, relaxed ? (options.relaxedPriority ?? RELAXED_AVOID_PRIORITY) : (options.strongPriority ?? AVOID_PRIORITY)),
          )
          const redoneTurn = turnAngleDegrees(edgeBearing(redonePrevious.coordinates, false), edgeBearing(redoneCurrent.coordinates, true))
          // Only keep the pulled-in point if it actually straightened the join;
          // a still-sharp turn would only be trading one dead end for another,
          // for the price of two extra requests.
          if (redoneTurn < turn) {
            running -= previous.distanceMeters
            legs.pop()
            walked.pop()
            legs.push({ ...redonePrevious, relaxed: previous.relaxed, avoidanceAreaCount: areasBeforePrevious.length })
            walked.push(redonePrevious.coordinates)
            running += redonePrevious.distanceMeters
            points[index] = pulledIn
            leg = redoneCurrent
          }
        } catch (error) {
          if (!(error instanceof GraphHopperError) || error.kind === 'transport') throw error
          // Keep the dead-ending join: pulling the waypoint in found no way round either.
        }
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

/**
 * The direction a leg is travelling right at one end of it — the last stretch
 * before it arrives, or the first stretch after it departs — rather than the
 * bearing of the whole leg, which a winding street would blur into something
 * meaningless.
 */
function edgeBearing(coordinates: LngLat[], atStart: boolean, windowMetres = EDGE_BEARING_WINDOW_METRES): number {
  if (coordinates.length < 2) return 0
  if (atStart) {
    let index = 1
    while (index < coordinates.length - 1 && haversine(coordinates[0], coordinates[index]) < windowMetres) index++
    return bearingBetween(coordinates[0], coordinates[index])
  }
  let index = coordinates.length - 2
  while (index > 0 && haversine(coordinates[coordinates.length - 1], coordinates[index]) < windowMetres) index--
  return bearingBetween(coordinates[index], coordinates[coordinates.length - 1])
}

/** The angle between two bearings, 0-180 degrees either way round the compass. */
function turnAngleDegrees(a: number, b: number): number {
  const diff = Math.abs(normaliseBearing(a) - normaliseBearing(b))
  return diff > 180 ? 360 - diff : diff
}
