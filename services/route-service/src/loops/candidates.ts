import { destination, normaliseBearing, type LngLat } from './geo.js'
import { mulberry32 } from './random.js'

/**
 * Candidate loop shapes.
 *
 * A loop is described up-front as a triangle of outer waypoints around the
 * walker; the router is then asked for the four legs between them separately.
 * Nothing here asks any engine for a "round trip" — the shape is Looper's, and
 * the engine only answers "how do I walk from this point to that one".
 *
 * Three waypoints at 120° is the smallest ring that cannot be satisfied by
 * walking out and back: any path through all three encloses area. More
 * waypoints would tighten the shape but leave less room for the street layout
 * to disagree, and the street layout always wins.
 */
export type LoopDirection = 'clockwise' | 'counter-clockwise'

export type CandidateShape = {
  id: string
  /** Position within the deterministic set, 0-based. */
  index: number
  direction: LoopDirection
  /** Bearing of the first outer waypoint, degrees clockwise from north. */
  baseBearing: number
  /** The un-jittered ring radius this candidate was built from. */
  radiusMetres: number
  waypoints: [LngLat, LngLat, LngLat]
}

/**
 * A triangle whose corners sit on a circle of radius r has a perimeter near
 * 5.2r, and the walk also runs out to the ring and back, so a target distance
 * of d wants a ring of roughly d/8.3. Street networks stretch that in practice,
 * which is what the 0.78–1.20 overall scaling is there to cover.
 */
export const RING_RADIUS_DIVISOR = 8.3
/** Per-waypoint radius jitter, so the ring is a rough triangle and not a stencil. */
export const WAYPOINT_RADIUS_JITTER = 0.15
export const MIN_RADIUS_SCALE = 0.78
export const MAX_RADIUS_SCALE = 1.20
/** Spread of the first waypoint around its slot, in degrees. */
export const BEARING_JITTER_DEGREES = 12
export const DEFAULT_CANDIDATE_COUNT = 24

export const ringRadiusMetres = (targetDistanceMetres: number) => targetDistanceMetres / RING_RADIUS_DIVISOR

/**
 * Deterministic for a given seed. Candidates come in mirrored pairs that share
 * a bearing and radii but run opposite ways round: the same three streets can
 * make a good loop one way and an awkward one the other, and which is which
 * depends on one-way paths, stairs and crossings we cannot see from here.
 */
export function generateCandidateShapes(
  start: LngLat,
  targetDistanceMetres: number,
  seed: number,
  count: number = DEFAULT_CANDIDATE_COUNT,
  /**
   * Applied on top of the estimate above. The divisor is a rule of thumb about
   * how much longer a street network is than the crow-flies ring, and how much
   * longer varies: a dense suburb of 80 m blocks costs far more per metre of
   * radius than an open seafront. The generator measures what the first pass
   * actually returned and may resize the ring once. The distance the walk is
   * judged against never moves — that is what the walker asked for.
   */
  radiusScale = 1,
): CandidateShape[] {
  if (count < 2 || count % 2 !== 0) throw new Error('Candidate count must be a positive even number so every shape has a mirror.')
  const random = mulberry32(seed)
  const baseRadius = ringRadiusMetres(targetDistanceMetres) * radiusScale
  const pairs = count / 2
  const shapes: CandidateShape[] = []

  for (let pair = 0; pair < pairs; pair++) {
    // Slots evenly around the compass, nudged so two runs never look stencilled.
    const jitter = (random() - 0.5) * 2 * BEARING_JITTER_DEGREES
    const baseBearing = normaliseBearing((pair * 360) / pairs + jitter)
    const overallScale = MIN_RADIUS_SCALE + random() * (MAX_RADIUS_SCALE - MIN_RADIUS_SCALE)
    const radii = [0, 1, 2].map(() => baseRadius * overallScale * (1 + (random() - 0.5) * 2 * WAYPOINT_RADIUS_JITTER))

    for (const direction of ['clockwise', 'counter-clockwise'] as const) {
      const turn = direction === 'clockwise' ? 1 : -1
      const waypoints = [0, 1, 2].map(corner =>
        destination(start, radii[corner], normaliseBearing(baseBearing + turn * 120 * corner)),
      ) as [LngLat, LngLat, LngLat]
      shapes.push({
        id: `${pair}-${direction === 'clockwise' ? 'cw' : 'ccw'}`,
        index: shapes.length,
        direction,
        baseBearing,
        radiusMetres: baseRadius * overallScale,
        waypoints,
      })
    }
  }
  return shapes
}

/** start → A → B → C → start, the sequence the legs are routed along. */
export const shapeToLegPoints = (start: LngLat, shape: CandidateShape): LngLat[] =>
  [start, ...shape.waypoints, start]
