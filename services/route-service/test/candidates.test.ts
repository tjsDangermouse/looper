import { describe, expect, it } from 'vitest'
import { DEFAULT_CANDIDATE_COUNT, MAX_RADIUS_SCALE, MIN_RADIUS_SCALE, RING_RADIUS_DIVISOR, WAYPOINT_RADIUS_JITTER, generateCandidateShapes, ringRadiusMetres, shapeToLegPoints } from '../src/loops/candidates.js'
import { bearingBetween, haversine, normaliseBearing } from '../src/loops/geo.js'
import { hashString, mulberry32, seedFor } from '../src/loops/random.js'

const START: [number, number] = [-4.4816, 54.1506]
const TARGET = 5000

describe('seeded randomness', () => {
  it('gives the same stream for the same seed', () => {
    const a = mulberry32(42)
    const b = mulberry32(42)
    expect([a(), a(), a()]).toEqual([b(), b(), b()])
  })
  it('gives a different stream for a different seed', () => {
    expect(mulberry32(1)()).not.toBe(mulberry32(2)())
  })
  it('stays inside the unit interval', () => {
    const random = mulberry32(hashString('looper'))
    for (let i = 0; i < 500; i++) {
      const value = random()
      expect(value).toBeGreaterThanOrEqual(0)
      expect(value).toBeLessThan(1)
    }
  })
  it('ignores GPS drift of a few metres in the start point', () => {
    expect(seedFor([-4.48161, 54.15062], 5000, 0)).toBe(seedFor([-4.48163, 54.15061], 5000, 0))
  })
  it('moves when the walker asks for a different set', () => {
    expect(seedFor(START, 5000, 1)).not.toBe(seedFor(START, 5000, 0))
  })
  it('moves when the distance changes', () => {
    expect(seedFor(START, 6000, 0)).not.toBe(seedFor(START, 5000, 0))
  })
})

describe('candidate shapes', () => {
  const seed = seedFor(START, TARGET, 0)
  const shapes = generateCandidateShapes(START, TARGET, seed)

  it('makes twenty-four of them by default', () => {
    expect(DEFAULT_CANDIDATE_COUNT).toBe(24)
    expect(shapes).toHaveLength(24)
  })
  it('is deterministic for the same seed', () => {
    expect(generateCandidateShapes(START, TARGET, seed)).toEqual(shapes)
  })
  it('produces a different set for a different variation', () => {
    const other = generateCandidateShapes(START, TARGET, seedFor(START, TARGET, 1))
    expect(other[0].waypoints).not.toEqual(shapes[0].waypoints)
  })
  it('sizes the outer ring at a little over an eighth of the target', () => {
    expect(RING_RADIUS_DIVISOR).toBe(8.3)
    expect(ringRadiusMetres(5000)).toBeCloseTo(602.4, 1)
  })
  it('keeps every waypoint within the stated radius bounds', () => {
    const base = ringRadiusMetres(TARGET)
    for (const shape of shapes) {
      for (const waypoint of shape.waypoints) {
        const radius = haversine(START, waypoint)
        expect(radius).toBeGreaterThan(base * MIN_RADIUS_SCALE * (1 - WAYPOINT_RADIUS_JITTER) - 1)
        expect(radius).toBeLessThan(base * MAX_RADIUS_SCALE * (1 + WAYPOINT_RADIUS_JITTER) + 1)
      }
    }
  })
  it('places the three waypoints 120° apart', () => {
    for (const shape of shapes) {
      const bearings = shape.waypoints.map(waypoint => bearingBetween(START, waypoint))
      const turn = shape.direction === 'clockwise' ? 1 : -1
      expect(normaliseBearing(bearings[1])).toBeCloseTo(normaliseBearing(shape.baseBearing + turn * 120), 3)
      expect(normaliseBearing(bearings[2])).toBeCloseTo(normaliseBearing(shape.baseBearing + turn * 240), 3)
    }
  })
  it('pairs every clockwise shape with its mirror', () => {
    for (let i = 0; i < shapes.length; i += 2) {
      expect(shapes[i].direction).toBe('clockwise')
      expect(shapes[i + 1].direction).toBe('counter-clockwise')
      // Same first waypoint, same radii, opposite way round.
      expect(shapes[i + 1].waypoints[0]).toEqual(shapes[i].waypoints[0])
      expect(haversine(START, shapes[i + 1].waypoints[1])).toBeCloseTo(haversine(START, shapes[i].waypoints[1]), 6)
    }
  })
  it('spreads the candidates around the compass', () => {
    const octants = new Set(shapes.map(shape => Math.round(shape.baseBearing / 45) % 8))
    expect(octants.size).toBe(8)
  })
  it('refuses an odd candidate count, which would leave a shape without a mirror', () => {
    expect(() => generateCandidateShapes(START, TARGET, seed, 7)).toThrow()
  })
  it('routes start → A → B → C → start', () => {
    const points = shapeToLegPoints(START, shapes[0])
    expect(points).toHaveLength(5)
    expect(points[0]).toEqual(START)
    expect(points[4]).toEqual(START)
    expect(points.slice(1, 4)).toEqual(shapes[0].waypoints)
  })
})
