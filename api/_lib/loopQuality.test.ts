import { describe, expect, it } from 'vitest'
import { loadFixture } from './fixtures.js'
import { bearingDelta, destination, haversine, orientedExtent, pathLength, project, resample } from './geo.js'
import {
  DISTANCE_TOLERANCE, MAX_EXTENT_RATIO, MAX_LEG_SHARE, MAX_RETRACE_FRACTION, MAX_SPUR_METRES, START_EXCLUSION,
  departureBearing, describeDirection, dominantBearing, nameLoops, qualityCues, scoreLoopRoute, selectLoops,
  selfOverlap, sharedFraction, tooSimilar, type Point, type RouteInput, type Target,
} from './loopQuality.js'
import { RADIUS_BAND, generateCandidates, metresFromMinutes, minutesFromMetres, radiusFor, ringWaypoints, routeCoordinates, seedFor, seededRandom } from './waypoints.js'

const START: Point = [-4.4816, 54.1506] // Douglas, Isle of Man
const distanceTarget = (metres: number): Target => ({ metres, mode: 'distance' })
const timeTarget = (minutes: number): Target => ({ metres: metresFromMinutes(minutes), seconds: minutes * 60, mode: 'time' })

const clean = loadFixture('clean-loop')
const outAndBack = loadFixture('out-and-back')
const crossing = loadFixture('self-crossing')
const repeated = loadFixture('repeated-segment')
const narrow = loadFixture('narrow-loop')
/** Score a fixture against its own length, so only shape is under test. */
const assess = (route: RouteInput, target = distanceTarget(route.distanceMeters)) => scoreLoopRoute(route, target)

describe('geodesic waypoint generation', () => {
  it('places a point the asked-for distance away', () => expect(haversine(START, destination(START, 500, 90))).toBeCloseTo(500, 0))
  it('goes north for bearing 0 and east for bearing 90', () => {
    expect(destination(START, 500, 0)[1]).toBeGreaterThan(START[1])
    expect(destination(START, 500, 0)[0]).toBeCloseTo(START[0], 6)
    expect(destination(START, 500, 90)[0]).toBeGreaterThan(START[0])
  })
  it('does not use naive degree arithmetic: a degree of longitude is shorter at 54°N', () => {
    const east = destination(START, 1000, 90), north = destination(START, 1000, 0)
    // Same ground distance, but ~1.7× the longitude change of the latitude change.
    expect(Math.abs(east[0] - START[0]) / Math.abs(north[1] - START[1])).toBeGreaterThan(1.5)
  })
  it('spaces the ring at 120°', () => {
    const [a, b, c] = ringWaypoints(START, 500, 0, [1, 1, 1])
    expect(haversine(a, b)).toBeCloseTo(haversine(b, c), -1)
    expect(haversine(START, a)).toBeCloseTo(500, 0)
  })
  it('applies the per-waypoint radius jitter', () => {
    const [a, , c] = ringWaypoints(START, 500, 0, [.85, 1, 1.15])
    expect(haversine(START, a)).toBeCloseTo(425, 0)
    expect(haversine(START, c)).toBeCloseTo(575, 0)
  })
  it('sizes the ring from the target length', () => expect(radiusFor(5000)).toBeCloseTo(5000 / 8.3))
})

describe('candidate waypoint order', () => {
  const candidates = generateCandidates(START, 5000)
  it('generates the full pool', () => expect(candidates).toHaveLength(18))
  it('sends start, three waypoints, then start again', () => {
    const coordinates = routeCoordinates(START, candidates[0].waypoints)
    expect(coordinates).toHaveLength(5)
    expect(coordinates[0]).toEqual(START)
    expect(coordinates[4]).toEqual(START)
  })
  it('keeps the ring in walking order, turning consistently one way', () => {
    for (const candidate of candidates) {
      const angles = candidate.waypoints.map(w => (Math.atan2(w[0] - START[0], w[1] - START[1]) * 180 / Math.PI + 360) % 360)
      const steps = [0, 1].map(i => (angles[i + 1] - angles[i] + 360) % 360)
      for (const step of steps) expect(step).toBeGreaterThan(60)
      for (const step of steps) expect(step).toBeLessThan(190)
    }
  })
  it('stays inside the allowed radius band', () => {
    const base = radiusFor(5000)
    for (const candidate of candidates) {
      expect(candidate.radiusMetres).toBeGreaterThanOrEqual(base * RADIUS_BAND[0])
      expect(candidate.radiusMetres).toBeLessThanOrEqual(base * RADIUS_BAND[1])
    }
  })
  it('spreads candidates around the compass', () => {
    const quadrants = new Set(candidates.map(c => Math.floor(c.baseAngle / 90)))
    expect(quadrants.size).toBe(4)
  })
  it('is deterministic for the same start and target', () =>
    expect(generateCandidates(START, 5000)).toEqual(generateCandidates(START, 5000)))
  it('gives a different set for a different target', () =>
    expect(generateCandidates(START, 5000)[0].waypoints).not.toEqual(generateCandidates(START, 6000)[0].waypoints))
  it('ignores GPS jitter below the rounding step', () => expect(seedFor(START, 5000)).toBe(seedFor([START[0] + .00001, START[1]], 5000)))
  it('produces an even spread of randoms', () => {
    const random = seededRandom(1), values = Array.from({ length: 500 }, random)
    expect(Math.min(...values)).toBeGreaterThanOrEqual(0)
    expect(Math.max(...values)).toBeLessThan(1)
    expect(values.reduce((a, b) => a + b) / values.length).toBeCloseTo(.5, 1)
  })
})

describe('distance conversion', () => {
  it('converts an hour to 5 km at walking pace', () => expect(metresFromMinutes(60)).toBeCloseTo(5000))
  it('round-trips', () => expect(minutesFromMetres(metresFromMinutes(37))).toBeCloseTo(37))
  it('matches the client-side estimate of minutes ÷ 12 km', () => expect(metresFromMinutes(48) / 1000).toBeCloseTo(48 / 12))
})

describe('resampling and shape measurement', () => {
  it('lays samples down at an even spacing', () => {
    const samples = resample(project(clean.coordinates), 15)
    expect(samples.length).toBeCloseTo(clean.distanceMeters / 15, -1)
    for (let i = 1; i < samples.length; i++) expect(samples[i].along - samples[i - 1].along).toBeCloseTo(15, 6)
  })
  it('measures a fixture at the length it was drawn to', () => expect(pathLength(project(clean.coordinates))).toBeCloseTo(clean.distanceMeters, -1))
  it('reads a circle as square-ish in extent', () => expect(orientedExtent(project(clean.coordinates)).ratio).toBeLessThan(1.1))
  it('reads a 1500×120 m sliver as narrow', () => expect(orientedExtent(project(narrow.coordinates)).ratio).toBeGreaterThan(MAX_EXTENT_RATIO))
  it('ignores which way round two bearings are compared', () => expect(bearingDelta(350, 10)).toBe(20))
})

describe('continuous overlap detection', () => {
  it('finds no retracing on a clean circular loop', () => expect(selfOverlap(clean.coordinates).retraceFraction).toBe(0))
  it('finds a path crossing itself once is not retracing', () => expect(selfOverlap(crossing.coordinates).retraceFraction).toBeLessThan(.02))
  it('counts an out-and-back as almost entirely retraced', () => expect(selfOverlap(outAndBack.coordinates).retraceFraction).toBeGreaterThan(.85))
  it('finds the repeated bridge corridor and nothing else', () => {
    const overlap = selfOverlap(repeated.coordinates)
    // ~600 m walked twice out of ~3.4 km, so both passes are ~35% of the walk.
    expect(overlap.retraceFraction).toBeGreaterThan(.2)
    expect(overlap.retraceFraction).toBeLessThan(.45)
    expect(overlap.longestReverseRun).toBeGreaterThan(MAX_SPUR_METRES)
  })
  it('marks a doubled-back corridor as reversed, not as a same-way brush', () =>
    expect(selfOverlap(repeated.coordinates).runs.every(run => run.reversed)).toBe(true))
  it('ignores a corridor shorter than a junction crossing', () => {
    // Two arms of a loop that touch for ~20 m and part again.
    const flat: Point[] = [[0, 0], [0, .0009], [.0004, .0018], [.0008, .0009], [.00081, 0], [0, 0]]
    expect(selfOverlap(flat).retracedMetres).toBe(0)
  })
})

describe('the allowed shared start and end corridor', () => {
  /** A clean ring reached by a `stub`-metre lane walked out and back. */
  const withStub = (stub: number): Point[] => {
    const lane = Array.from({ length: 21 }, (_, i) => destination(START, stub * i / 20, 0))
    // The ring is entered at its nearest point, so the lane is the only shared ground.
    const ring = Array.from({ length: 49 }, (_, i) => destination(destination(START, stub + 250, 0), 250, 180 + i * 360 / 48))
    return [...lane, ...ring, ...[...lane].reverse()]
  }
  it('forgives a short shared departure and arrival', () => expect(selfOverlap(withStub(60)).retracedMetres).toBe(0))
  it('still catches a lane longer than the allowance', () => {
    const overlap = selfOverlap(withStub(400))
    expect(overlap.retracedMetres).toBeGreaterThan(2 * (400 - START_EXCLUSION) * .8)
    expect(overlap.longestReverseRun).toBeGreaterThan(MAX_SPUR_METRES)
  })
})

describe('hard rejection checks', () => {
  it('accepts the clean loop', () => {
    const assessment = assess(clean)
    expect(assessment.rejections).toEqual([])
    expect(assessment.passed).toBe(true)
  })
  it('accepts a route that crosses itself once without retracing', () => expect(assess(crossing).passed).toBe(true))
  it('rejects an out-and-back for retracing', () => expect(assess(outAndBack).rejections.join()).toMatch(/retraces/))
  it('rejects an out-and-back for its spur as well', () => expect(assess(outAndBack).rejections.join()).toMatch(/out-and-back spur/))
  it('rejects the repeated bridge segment', () => expect(assess(repeated).passed).toBe(false))
  it('rejects a narrow elongated loop on shape', () => expect(assess(narrow).rejections.join()).toMatch(/longer than it is wide/))
  it('rejects a route outside the distance tolerance', () => {
    const overshoot = distanceTarget(clean.distanceMeters / (1 + DISTANCE_TOLERANCE + .05))
    expect(assess(clean, overshoot).rejections.join()).toMatch(/distance \d+% off target/)
  })
  it('accepts a route just inside the distance tolerance', () =>
    expect(assess(clean, distanceTarget(clean.distanceMeters / 1.1)).passed).toBe(true))
  it('judges time input on duration, allowing the wider 15% band', () => {
    const minutes = clean.durationSeconds / 60
    expect(assess(clean, timeTarget(minutes * 1.14)).passed).toBe(true)
    expect(assess(clean, timeTarget(minutes * 1.25)).rejections.join()).toMatch(/duration/)
  })
  it('rejects more than one U-turn but tolerates a single one', () => {
    expect(assess({ ...clean, maneuvers: [11, 9, 1, 10] }).passed).toBe(true)
    expect(assess({ ...clean, maneuvers: [11, 9, 9, 10] }).rejections.join()).toMatch(/2 U-turns/)
  })
  it('scores a single U-turn below a clean one', () =>
    expect(assess({ ...clean, maneuvers: [11, 9, 1, 10] }).score).toBeLessThan(assess(clean).score))
})

describe('leg balance rejection', () => {
  const legs = (shares: number[]) => ({ ...clean, legDistances: shares.map(share => clean.distanceMeters * share) })
  it('accepts four even legs', () => expect(assess(legs([.25, .25, .25, .25])).passed).toBe(true))
  it('accepts a mild imbalance', () => expect(assess(legs([.4, .2, .2, .2])).passed).toBe(true))
  it('rejects one leg dominating the walk', () => expect(assess(legs([.5, .2, .2, .1])).rejections.join()).toMatch(/one leg is 50%/))
  it('rejects a vanishing outer ring leg', () => expect(assess(legs([.4, .05, .35, .2])).rejections.join()).toMatch(/outer leg is only 5%/))
  it('does not count a short first or last spoke as a vanishing ring leg', () =>
    expect(assess(legs([.04, .44, .44, .08])).rejections.join()).not.toMatch(/outer leg/))
  it('holds the documented threshold', () => expect(MAX_LEG_SHARE).toBe(.45))
})

describe('ranking', () => {
  it('weights self-overlap above every other factor', () => {
    const { components, score } = assess(clean)
    const drop = (key: keyof typeof components) => {
      const worse = { ...components, [key]: 0 }
      return score - 100 * (.35 * worse.overlap + .25 * worse.accuracy + .2 * worse.shape + .1 * worse.balance + .1 * worse.turns)
    }
    for (const key of ['accuracy', 'shape', 'balance', 'turns'] as const) expect(drop('overlap')).toBeGreaterThan(drop(key))
  })
  it('ranks a clean loop above one that crosses itself', () => expect(assess(clean).score).toBeGreaterThan(assess(crossing).score))
  it('ranks a crossing above a repeated corridor', () => expect(assess(crossing).score).toBeGreaterThan(assess(repeated).score))
  it('ranks a repeated corridor above a pure out-and-back', () => expect(assess(repeated).score).toBeGreaterThan(assess(outAndBack).score))
  it('prefers the loop closest to the requested distance', () => {
    const target = distanceTarget(clean.distanceMeters)
    expect(scoreLoopRoute(clean, target).score).toBeGreaterThan(scoreLoopRoute({ ...clean, distanceMeters: clean.distanceMeters * 1.08 }, target).score)
  })
  it('offers the best candidate first', () => {
    const candidates = [repeated, clean, crossing].map(route => ({ coordinates: route.coordinates, assessment: assess(route) }))
    expect(selectLoops(candidates)[0].coordinates).toBe(clean.coordinates)
  })
})

describe('diversity', () => {
  const shift = (coordinates: Point[], metres: number, bearingDegrees: number) => {
    const moved = destination(coordinates[0], metres, bearingDegrees)
    const [dx, dy] = [moved[0] - coordinates[0][0], moved[1] - coordinates[0][1]]
    return coordinates.map(([lng, lat]) => [lng + dx, lat + dy] as Point)
  }
  const mirrored = [...clean.coordinates].reverse() as Point[]

  it('sees a loop as entirely shared with itself', () => expect(sharedFraction(clean.coordinates, clean.coordinates)).toBeCloseTo(1, 1))
  it('sees nothing shared between loops a mile apart', () => expect(sharedFraction(clean.coordinates, shift(clean.coordinates, 3000, 90))).toBe(0))
  it('treats the same circuit walked the other way as the same walk', () => expect(tooSimilar(clean.coordinates, mirrored)).toBe(true))
  it('treats loops in opposite directions as different walks', () => expect(tooSimilar(clean.coordinates, shift(clean.coordinates, 1500, 180))).toBe(false))
  it('never offers two versions of the same walk', () => {
    const candidates = [clean.coordinates, mirrored, shift(clean.coordinates, 2500, 90)]
      .map(coordinates => ({ coordinates, assessment: assess({ ...clean, coordinates }) }))
    const chosen = selectLoops(candidates)
    expect(chosen).toHaveLength(2)
  })
  it('offers at most three', () => {
    const candidates = [0, 90, 180, 270].map(angle => shift(clean.coordinates, 3000, angle))
      .map(coordinates => ({ coordinates, assessment: assess({ ...clean, coordinates }) }))
    expect(selectLoops(candidates)).toHaveLength(3)
  })
})

describe('the no-clean-route state', () => {
  it('offers nothing rather than a bad walk', () => {
    const candidates = [outAndBack, narrow, repeated].map(route => ({ coordinates: route.coordinates, assessment: assess(route) }))
    expect(selectLoops(candidates)).toEqual([])
  })
  it('offers one good walk rather than padding to three', () => {
    const candidates = [clean, outAndBack, narrow].map(route => ({ coordinates: route.coordinates, assessment: assess(route) }))
    expect(selectLoops(candidates)).toHaveLength(1)
  })
  it('says why each rejected candidate was rejected', () => {
    for (const route of [outAndBack, narrow, repeated]) expect(assess(route).rejections.length).toBeGreaterThan(0)
  })
})

describe('labels', () => {
  const at = (bearingDegrees: number) => {
    const centre = destination(START, 600, bearingDegrees)
    // Entered at the near side, so the walk really does set off on `bearingDegrees`.
    return [START, ...Array.from({ length: 41 }, (_, i) => destination(centre, 300, bearingDegrees + 180 + i * 9)), START] as Point[]
  }
  it('labels a loop by the way it heads out', () => {
    expect(describeDirection(dominantBearing(at(0)))).toBe('North loop')
    expect(describeDirection(dominantBearing(at(135)))).toBe('South-east loop')
    expect(describeDirection(dominantBearing(at(270)))).toBe('West loop')
  })
  it('reads the departure bearing from the opening stretch', () => expect(departureBearing(at(90))).toBeCloseTo(90, -1))
  it('tells two loops heading the same way apart by length', () =>
    expect(nameLoops([{ distanceMeters: 4000, direction: 'North loop' }, { distanceMeters: 2000, direction: 'North loop' }])).toEqual(['Longer north loop', 'Shorter north loop']))
  it('leaves distinct directions alone', () =>
    expect(nameLoops([{ distanceMeters: 1000, direction: 'North loop' }, { distanceMeters: 2000, direction: 'West loop' }])).toEqual(['North loop', 'West loop']))
})

describe('quality cues', () => {
  it('calls a spotless loop clean', () => expect(qualityCues([assess(clean)])[0]).toBe('Clean loop'))
  it('marks the closest to target when another route is cleaner', () => {
    const closer = { ...clean, distanceMeters: clean.distanceMeters * 1.09, coordinates: crossing.coordinates }
    const cues = qualityCues([assess(clean, distanceTarget(clean.distanceMeters * 1.09)), assess(closer, distanceTarget(closer.distanceMeters))])
    expect(cues).toContain('Clean loop')
    expect(cues).toContain('Closest to your target')
  })
  it('stays silent when it has nothing true to say', () =>
    expect(qualityCues([assess(narrow)]).filter(Boolean)).toEqual([]))
})

describe('retrace threshold', () => {
  it('holds the documented limits', () => {
    expect(MAX_RETRACE_FRACTION).toBe(.12)
    expect(MAX_SPUR_METRES).toBe(150)
    expect(START_EXCLUSION).toBe(75)
  })
})
