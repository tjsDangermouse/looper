import { describe, expect, it } from 'vitest'
import { MAX_SHARED_FRACTION, bearingLabel, bearingOctant, initialBearing, labelRoutes, selectDiverseRoutes } from '../src/loops/diversity.js'
import type { LngLat } from '../src/loops/geo.js'
import { FIXTURE_ORIGIN, polyline, twinA, twinB } from './fixtures/routes.js'

const START: LngLat = FIXTURE_ORIGIN
/** A square loop leaving the start in a given direction. */
const loopTowards = (east: number, north: number) =>
  polyline([[0, 0], [east, north], [east + north, north - east], [north, -east], [0, 0]])

describe('naming a loop for the way it heads', () => {
  it('reads the bearing a few hundred metres in, not off the first pavement', () => {
    // Twenty metres west, then firmly north for a kilometre.
    const dogleg = polyline([[0, 0], [-20, 0], [-20, 1000], [400, 1000], [400, 0], [0, 0]])
    expect(bearingLabel(initialBearing(dogleg, START))).toBe('North loop')
  })
  it('names each octant', () => {
    expect(bearingLabel(0)).toBe('North loop')
    expect(bearingLabel(45)).toBe('North-east loop')
    expect(bearingLabel(90)).toBe('East loop')
    expect(bearingLabel(135)).toBe('South-east loop')
    expect(bearingLabel(180)).toBe('South loop')
    expect(bearingLabel(225)).toBe('South-west loop')
    expect(bearingLabel(270)).toBe('West loop')
    expect(bearingLabel(315)).toBe('North-west loop')
  })
  it('rounds to the nearest octant and wraps past north', () => {
    expect(bearingOctant(359)).toBe(0)
    expect(bearingLabel(350)).toBe('North loop')
  })
  it('tells two loops heading the same way apart by length', () => {
    expect(labelRoutes([
      { bearing: 0, distanceMeters: 5000 },
      { bearing: 5, distanceMeters: 3000 },
    ])).toEqual(['Longer north loop', 'Shorter north loop'])
  })
  it('leaves distinct directions alone', () => {
    expect(labelRoutes([
      { bearing: 0, distanceMeters: 5000 },
      { bearing: 90, distanceMeters: 3000 },
    ])).toEqual(['North loop', 'East loop'])
  })
})

describe('choosing which loops to offer', () => {
  const candidate = (coordinates: LngLat[], score: number, bearing: number) => ({ coordinates, quality: { score }, bearing })

  it('drops a near-identical alternative', () => {
    const chosen = selectDiverseRoutes([
      candidate(twinA, 90, 0),
      candidate(twinB, 88, 2),
    ])
    expect(chosen).toHaveLength(1)
    expect(chosen[0].coordinates).toBe(twinA)
  })
  it('keeps loops that go genuinely different ways', () => {
    const chosen = selectDiverseRoutes([
      candidate(loopTowards(0, 800), 90, 0),
      candidate(loopTowards(800, 0), 85, 90),
      candidate(loopTowards(0, -800), 80, 180),
    ])
    expect(chosen).toHaveLength(3)
  })
  it('offers the best loop first', () => {
    const best = candidate(loopTowards(800, 0), 95, 90)
    const chosen = selectDiverseRoutes([candidate(loopTowards(0, 800), 70, 0), best])
    expect(chosen[0]).toBe(best)
  })
  it('prefers a different way out of the door before a second loop heading the same way', () => {
    const north = candidate(loopTowards(0, 900), 95, 0)
    const alsoNorth = candidate(loopTowards(-200, 900), 90, 350)
    const east = candidate(loopTowards(900, 0), 60, 90)
    const chosen = selectDiverseRoutes([north, alsoNorth, east], 2)
    expect(chosen).toEqual([north, east])
  })
  it('will take a same-bearing loop rather than offer fewer walks', () => {
    const north = candidate(loopTowards(0, 900), 95, 0)
    const alsoNorth = candidate(loopTowards(-900, 200), 90, 350)
    const chosen = selectDiverseRoutes([north, alsoNorth], 3)
    expect(chosen).toHaveLength(2)
  })
  it('returns only what passed rather than padding the list', () => {
    expect(selectDiverseRoutes([candidate(twinA, 90, 0), candidate(twinB, 88, 1)], 3)).toHaveLength(1)
    expect(selectDiverseRoutes([], 3)).toHaveLength(0)
  })
  it('draws the line just over half the same ground', () => {
    expect(MAX_SHARED_FRACTION).toBe(.55)
  })
})
