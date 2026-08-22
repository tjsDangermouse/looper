import { describe, expect, it } from 'vitest'
import { GraphHopperError, type GraphHopperLeg } from '../src/graphhopper.js'
import { NO_CLEAN_LOOP_WARNING, RETRACES_WARNING, generateLoops, mapWithConcurrency, type LoopRequest } from '../src/loops/generate.js'
import { haversine, type LngLat } from '../src/loops/geo.js'

const START = { lng: -4.4816, lat: 54.1506 }

/**
 * A stand-in engine. Its paths are straight lines, but the distance it reports
 * carries the detour a real street network adds — which is the whole reason the
 * ring radius is a target distance over 8.3 rather than over 2π.
 */
function fakeEngine(options: { detour?: number | ((points: LngLat[]) => number); fail?: (points: LngLat[]) => boolean } = {}) {
  const detourFor = typeof options.detour === 'function' ? options.detour : () => options.detour ?? 1.52
  return async (points: LngLat[]): Promise<GraphHopperLeg> => {
    if (options.fail?.(points)) throw new GraphHopperError('Connection between locations not found', 400, 'unreachable')
    const straight = haversine(points[0], points[1])
    const steps = Math.max(2, Math.round(straight / 30))
    const coordinates: LngLat[] = Array.from({ length: steps + 1 }, (_, i) => [
      points[0][0] + (points[1][0] - points[0][0]) * (i / steps),
      points[0][1] + (points[1][1] - points[0][1]) * (i / steps),
    ])
    const distanceMeters = straight * detourFor(points)
    return {
      coordinates,
      distanceMeters,
      durationSeconds: distanceMeters / (5000 / 3600),
      steps: [
        { instruction: 'Continue', distanceMeters, durationSeconds: distanceMeters / 1.39, sign: 0, maneuver: 'continue', startIndex: 0, endIndex: coordinates.length - 1 },
        { instruction: 'Arrive at destination', distanceMeters: 0, durationSeconds: 0, sign: 4, maneuver: 'finish', startIndex: coordinates.length - 1, endIndex: coordinates.length - 1 },
      ],
    }
  }
}

const request = (overrides: Partial<LoopRequest> = {}): LoopRequest =>
  ({ start: START, mode: 'distance', distanceKm: 5, units: 'km', ...overrides })

describe('generating loops', () => {
  it('offers at most three walks', async () => {
    const result = await generateLoops(request(), { route: fakeEngine() })
    expect(result.routes.length).toBeGreaterThan(0)
    expect(result.routes.length).toBeLessThanOrEqual(3)
    expect(result.warning).toBeUndefined()
  })

  it('gives the same walks for the same request', async () => {
    const one = await generateLoops(request(), { route: fakeEngine() })
    const two = await generateLoops(request(), { route: fakeEngine() })
    expect(two.routes.map(route => route.geometry)).toEqual(one.routes.map(route => route.geometry))
    expect(two.routes.map(route => route.label)).toEqual(one.routes.map(route => route.label))
  })

  it('gives different walks when the walker asks for another set', async () => {
    const first = await generateLoops(request(), { route: fakeEngine() })
    const second = await generateLoops(request({ variation: 1 }), { route: fakeEngine() })
    expect(second.routes[0].geometry).not.toEqual(first.routes[0].geometry)
  })

  it('returns a walk the app can draw and follow', async () => {
    const [route] = (await generateLoops(request(), { route: fakeEngine() })).routes
    expect(route.geometry.type).toBe('LineString')
    expect(route.geometry.coordinates.length).toBeGreaterThan(20)
    expect(route.steps.length).toBeGreaterThan(0)
    expect(route.steps[route.steps.length - 1].maneuver).toBe('finish')
    expect(route.distanceMeters).toBeGreaterThan(0)
    expect(route.durationSeconds).toBeGreaterThan(0)
    expect(route.label).toMatch(/loop$/i)
    expect(route.id).toMatch(/^[0-9a-f-]{36}$/)
  })

  it('reports how far each walk is from what was asked for', async () => {
    const result = await generateLoops(request({ distanceKm: 5 }), { route: fakeEngine() })
    for (const route of result.routes) expect(Math.abs(route.targetDifferencePercent)).toBeLessThanOrEqual(12)
  })

  it('carries the quality numbers behind each walk', async () => {
    const [route] = (await generateLoops(request(), { route: fakeEngine() })).routes
    expect(route.quality.score).toBeGreaterThan(0)
    expect(route.quality.repeatedPercent).toBeLessThanOrEqual(12)
    expect(route.quality.uTurnCount).toBeLessThanOrEqual(1)
    expect(route.quality.compactness).toBeGreaterThan(0)
  })

  it('says so plainly when the streets will not make the loop', async () => {
    const result = await generateLoops(request(), { route: fakeEngine({ fail: () => true }) })
    expect(result.routes).toHaveLength(0)
    expect(result.warning).toBe(NO_CLEAN_LOOP_WARNING)
    expect(result.warning).not.toMatch(/graphhopper|engine|http|error/i)
  })

  it('offers the one or two walks that are good when three are not there', async () => {
    // Only the northern quarter of the map is walkable.
    const northOnly = fakeEngine({ fail: points => points.some(point => point[1] < START.lat - 0.0005) })
    const result = await generateLoops(request(), { route: northOnly })
    expect(result.routes.length).toBeLessThanOrEqual(3)
    for (const route of result.routes) expect(route.quality.score).toBeGreaterThan(0)
  })

  it('takes the duration the router reports as the authority in time mode', async () => {
    const result = await generateLoops(request({ mode: 'time', distanceKm: undefined, durationMinutes: 60 }), { route: fakeEngine() })
    for (const route of result.routes) {
      expect(Math.abs(route.durationSeconds - 3600) / 3600).toBeLessThanOrEqual(.15)
    }
  })

  it('adjusts once and tries again when the time estimate was wrong for the terrain', async () => {
    // The engine walks at 3 km/h, so a 5 km/h estimate lands well over the hour.
    const slow = async (points: LngLat[]) => {
      const leg = await fakeEngine()(points)
      return { ...leg, durationSeconds: leg.distanceMeters / (3000 / 3600) }
    }
    let attempts = 0
    const counting = async (points: LngLat[]) => { attempts++; return slow(points) }
    const result = await generateLoops(
      { start: START, mode: 'time', durationMinutes: 60, units: 'km' },
      { route: counting },
    )
    // Two passes of candidates, and no more: a walker is not waiting for a search.
    expect(attempts).toBeGreaterThan(24)
    for (const route of result.routes) expect(Math.abs(route.durationSeconds - 3600) / 3600).toBeLessThanOrEqual(.15)
  })

  it('never asks the engine for a round trip', async () => {
    const seen: LngLat[][] = []
    await generateLoops(request(), { route: async points => { seen.push(points); return fakeEngine()(points) } })
    expect(seen.length).toBeGreaterThan(0)
    for (const points of seen) expect(points).toHaveLength(2)
  })

  it('lets the engine being down surface as a failure rather than an empty list', async () => {
    const down = async () => { throw new GraphHopperError('down', undefined, 'transport') }
    await expect(generateLoops(request(), { route: down })).rejects.toThrow(GraphHopperError)
  })
})

describe('falling back where no clean loop exists', () => {
  /**
   * A single road up a valley: the engine will route along it and nowhere else,
   * so every candidate is a walk out and back. The right length is still
   * reachable — half out, half back.
   */
  function valleyEngine(targetMetres: number) {
    return async (): Promise<GraphHopperLeg> => {
      const out = targetMetres / 8
      const along = (metres: number): LngLat => [START.lng, START.lat + metres / 111195]
      // Every leg is dragged onto the one road, so legs run up and back down it.
      const from = along(0)
      const to = along(out)
      const coordinates: LngLat[] = []
      const steps = 40
      for (let i = 0; i <= steps; i++) coordinates.push([from[0], from[1] + (to[1] - from[1]) * (i / steps)])
      for (let i = 1; i <= steps; i++) coordinates.push([to[0], to[1] + (from[1] - to[1]) * (i / steps)])
      const distanceMeters = out * 2
      return {
        coordinates,
        distanceMeters,
        durationSeconds: distanceMeters / (5000 / 3600),
        steps: [
          { instruction: 'Continue', distanceMeters, durationSeconds: distanceMeters / 1.39, sign: 0, maneuver: 'continue', startIndex: 0, endIndex: coordinates.length - 1 },
          { instruction: 'Arrive at destination', distanceMeters: 0, durationSeconds: 0, sign: 4, maneuver: 'finish', startIndex: coordinates.length - 1, endIndex: coordinates.length - 1 },
        ],
      }
    }
  }

  it('offers a walk that doubles back rather than nothing at all', async () => {
    const result = await generateLoops(request(), { route: valleyEngine(5000) })
    expect(result.routes.length).toBeGreaterThan(0)
    expect(result.warning).toBe(RETRACES_WARNING)
  })

  it('says plainly that these walks retrace, without blaming the map', async () => {
    const result = await generateLoops(request(), { route: valleyEngine(5000) })
    expect(result.warning).toMatch(/retrace/i)
    expect(result.warning).not.toMatch(/graphhopper|osm|engine|candidate|score/i)
  })

  it('still holds the walk to the length that was asked for', async () => {
    const result = await generateLoops(request({ distanceKm: 5 }), { route: valleyEngine(5000) })
    for (const route of result.routes) expect(Math.abs(route.targetDifferencePercent)).toBeLessThanOrEqual(12)
  })

  it('never mixes a doubling-back walk in with a clean loop', async () => {
    const result = await generateLoops(request(), { route: fakeEngine() })
    expect(result.warning).toBeUndefined()
    for (const route of result.routes) expect(route.quality.repeatedPercent).toBeLessThanOrEqual(12)
  })

  it('still offers nothing when even the length is out of reach', async () => {
    const result = await generateLoops(request(), { route: valleyEngine(20000) })
    expect(result.routes).toHaveLength(0)
    expect(result.warning).toBe(NO_CLEAN_LOOP_WARNING)
  })
})

describe('concurrency', () => {
  it('keeps results in order and never runs more than the limit at once', async () => {
    let running = 0
    let peak = 0
    const items = Array.from({ length: 20 }, (_, i) => i)
    const results = await mapWithConcurrency(items, 4, async item => {
      running++
      peak = Math.max(peak, running)
      await new Promise(resolve => setTimeout(resolve, 1))
      running--
      return item * 2
    })
    expect(results).toEqual(items.map(item => item * 2))
    expect(peak).toBeLessThanOrEqual(4)
  })
})
