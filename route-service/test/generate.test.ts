import { describe, expect, it } from 'vitest'
import { GraphHopperError, type GraphHopperLeg } from '../src/graphhopper.js'
import { NO_CLEAN_LOOP_WARNING, RETRACES_WARNING, generateLoops, mapWithConcurrency, type LoopRequest } from '../src/loops/generate.js'
import { haversine, type LngLat } from '../src/loops/geo.js'
import { RequestMetrics } from '../src/loops/metrics.js'

const START = { lng: -4.4816, lat: 54.1506 }

/**
 * A stand-in engine. Its paths are straight lines, but the distance it reports
 * carries the detour a real street network adds — which is the whole reason the
 * ring radius is a target distance over 8.3 rather than over 2π.
 */
function fakeEngine(options: {
  detour?: number | ((points: LngLat[]) => number)
  fail?: (points: LngLat[]) => boolean
  /** Milliseconds this call takes, so completion order can be shuffled on purpose. */
  delayMs?: (points: LngLat[]) => number
} = {}) {
  const detourFor = typeof options.detour === 'function' ? options.detour : () => options.detour ?? 1.52
  return async (points: LngLat[]): Promise<GraphHopperLeg> => {
    if (options.delayMs) await new Promise(resolve => setTimeout(resolve, options.delayMs!(points)))
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

  it('explores fresh batches when the first candidate set cannot fill three choices', async () => {
    let calls = 0
    const counting = async (points: LngLat[]) => { calls++; return fakeEngine()(points) }
    const result = await generateLoops(request(), { route: counting, candidateCount: 2 })
    // Two candidates take four legs each. More calls prove the generator did
    // not make the walker press refresh after the first under-filled batch.
    expect(calls).toBeGreaterThan(8)
    expect(result.routes).toHaveLength(3)
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

  it('stops dispatching new attempts once enough have already passed', async () => {
    let calls = 0
    const counting = async (points: LngLat[]) => { calls++; return fakeEngine()(points) }
    const full = await generateLoops(request(), { route: counting, candidateCount: 24 })
    expect(full.routes).toHaveLength(3)
    // Running every one of the 24 attempts to exhaustion against this fixture
    // costs 648 calls; stopping once enough loops pass should cut that sharply.
    expect(calls).toBeLessThan(250)
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

  it('returns three loops that pass through every requested waypoint', async () => {
    const waypoint: LngLat = [START.lng + 0.004, START.lat + 0.004]
    const result = await generateLoops(request({ waypoints: [{ lng: waypoint[0], lat: waypoint[1] }] }), { route: fakeEngine() })
    expect(result.routes).toHaveLength(3)
    for (const route of result.routes) {
      expect(route.geometry.coordinates).toContainEqual(waypoint)
      expect(route.geometry.coordinates[0]).toEqual([START.lng, START.lat])
      expect(route.geometry.coordinates.at(-1)).toEqual([START.lng, START.lat])
      expect(route.targetDifferencePercent).toBeLessThanOrEqual(25)
      expect(route.quality.repeatedPercent).toBeLessThanOrEqual(12)
      expect(route.quality.compactness).toBeGreaterThanOrEqual(0.2)
    }
    expect(new Set(result.routes.map(route => JSON.stringify(route.geometry.coordinates))).size).toBe(3)
  })

  it('penalises walked ground on every waypoint-loop return leg', async () => {
    const models: any[] = []
    const recording = async (points: LngLat[], model: any) => {
      models.push(model)
      return fakeEngine()(points)
    }
    await generateLoops(request({ waypoints: [{ lng: START.lng + 0.004, lat: START.lat + 0.004 }] }), { route: recording })
    expect(models.some(model => model?.priority?.length > 0)).toBe(true)
  })

  it('keeps clean standard loops when they already pass the waypoint', async () => {
    const result = await generateLoops(request({ waypoints: [{ lng: START.lng, lat: START.lat }] }), { route: fakeEngine() })
    expect(result.routes).toHaveLength(3)
    expect(result.warning).toBeUndefined()
    for (const route of result.routes) expect(route.quality.repeatedPercent).toBeLessThanOrEqual(12)
  })

  it('uses the waypoint itself to split a loop without requiring an extra guide', async () => {
    const start: LngLat = [START.lng, START.lat]
    const waypoint: LngLat = [START.lng + 0.01, START.lat]
    const returnCorner: LngLat = [START.lng, START.lat + 0.012]
    const same = (left: LngLat, right: LngLat) => left[0] === right[0] && left[1] === right[1]
    const leg = (coordinates: LngLat[], distanceMeters: number): GraphHopperLeg => ({
      coordinates,
      distanceMeters,
      durationSeconds: distanceMeters / (5000 / 3600),
      steps: [
        { instruction: 'Continue', distanceMeters, durationSeconds: distanceMeters / 1.39, sign: 0, maneuver: 'continue', startIndex: 0, endIndex: coordinates.length - 1 },
        { instruction: 'Arrive at destination', distanceMeters: 0, durationSeconds: 0, sign: 4, maneuver: 'finish', startIndex: coordinates.length - 1, endIndex: coordinates.length - 1 },
      ],
    })
    const twoWays = async (points: LngLat[], model: any): Promise<GraphHopperLeg> => {
      const outward = same(points[0], start) && same(points[1], waypoint)
      const home = same(points[0], waypoint) && same(points[1], start)
      if (!outward && !home) throw new GraphHopperError('Connection between locations not found', 400, 'unreachable')
      if (outward) return leg([start, waypoint], 2000)
      return model?.priority?.length
        ? leg([waypoint, returnCorner, start], 3000)
        : leg([waypoint, start], 2000)
    }

    const result = await generateLoops(
      request({ waypoints: [{ lng: waypoint[0], lat: waypoint[1] }] }),
      { route: twoWays },
    )

    expect(result.routes).toHaveLength(1)
    expect(result.routes[0].geometry.coordinates).toContainEqual(waypoint)
    expect(result.routes[0].geometry.coordinates.at(-1)).toEqual(start)
    expect(result.routes[0].quality.repeatedPercent).toBe(0)
  })

  it('asks the walker to change a plan that waypoints necessarily exceed by over 25%', async () => {
    const farAway = { lng: START.lng, lat: START.lat + 0.03 }
    const result = await generateLoops(request({ distanceKm: 1, waypoints: [farAway] }), { route: fakeEngine() })
    expect(result.routes).toHaveLength(0)
    expect(result.expectationExceeded).toBe(true)
    expect(result.warning).toMatch(/more than 25%|increase|remove/i)
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

/**
 * The generator can stop before it has tried everything. Which walks a walker
 * is offered must not then depend on which routing calls happened to be quick:
 * the same request on a busy afternoon and a quiet one is the same request.
 */
describe('stopping early without letting timing decide', () => {
  const flags = { spreadCandidateBearings: true, diversityAwareEarlyStop: true }

  it('offers the same walks however slowly individual calls came back', async () => {
    const runs = await Promise.all([
      () => 0,
      // Later bearings answer first, which is the order that would bias a
      // rule looking at whatever has finished so far.
      (points: LngLat[]) => (points[0][0] > -4.4816 ? 0 : 4),
      (points: LngLat[]) => Math.round(Math.abs(points[1][1] - 54.1506) * 2000) % 5,
    ].map(delayMs => generateLoops(request(), { route: fakeEngine({ delayMs }), flags, concurrency: 6 })))

    const shape = (result: Awaited<ReturnType<typeof generateLoops>>) =>
      result.routes.map(route => [route.label, route.distanceMeters, route.geometry.coordinates.length])
    expect(shape(runs[1])).toEqual(shape(runs[0]))
    expect(shape(runs[2])).toEqual(shape(runs[0]))
  })

  it('offers the same walks whatever the concurrency is set to', async () => {
    const delayMs = (points: LngLat[]) => Math.round(Math.abs(points[1][0] + 4.4816) * 3000) % 4
    const [one, six] = await Promise.all([
      generateLoops(request(), { route: fakeEngine({ delayMs }), flags, concurrency: 1 }),
      generateLoops(request(), { route: fakeEngine({ delayMs }), flags, concurrency: 6 }),
    ])
    expect(six.routes.map(r => r.distanceMeters)).toEqual(one.routes.map(r => r.distanceMeters))
  })

  it('says why it stopped', async () => {
    const result = await generateLoops(request(), { route: fakeEngine(), flags, metrics: new RequestMetrics() })
    expect(['diversity-satisfied', 'passing-quota', 'exhausted']).toContain(result.diagnostics!.metrics!.earlyStop)
  })
})

describe('measuring overlap on the network', () => {
  it('falls back to geometry when the engine reports no edge ids, and says so', async () => {
    const result = await generateLoops(request(), {
      route: fakeEngine(),
      flags: { edgeOverlap: true },
      metrics: new RequestMetrics(),
    })
    const metrics = result.diagnostics!.metrics!
    expect(metrics.overlapFromEdges).toBe(0)
    expect(metrics.overlapFromGeometry).toBeGreaterThan(0)
    expect(result.routes.length).toBeGreaterThan(0)
  })

  it('changes nothing at all when it is switched off', async () => {
    const off = await generateLoops(request(), { route: fakeEngine() })
    const on = await generateLoops(request(), { route: fakeEngine(), flags: { edgeOverlap: true } })
    expect(on.routes.map(r => r.geometry)).toEqual(off.routes.map(r => r.geometry))
  })
})

describe('repairing a candidate that was nearly right', () => {
  it('spends engine calls on repairs and says how many it made', async () => {
    const metrics = new RequestMetrics()
    // A network that stretches a ring further than the generator expects,
    // producing candidates that are only wrong about their length.
    const uneven = fakeEngine({ detour: 1.66 })
    const result = await generateLoops(request(), { route: uneven, flags: { localRepair: true }, metrics })
    const cost = result.diagnostics!.metrics!
    expect(cost.repairsAttempted).toBeGreaterThan(0)
    expect(cost.callsByPurpose.repair).toBeGreaterThan(0)
    expect(cost.repairsSucceeded).toBeLessThanOrEqual(cost.repairsAttempted)
  })

  it('never spends more on repairs than it was given', async () => {
    const metrics = new RequestMetrics()
    const uneven = fakeEngine({ detour: 1.66 })
    await generateLoops(request(), {
      route: uneven,
      flags: { localRepair: true },
      metrics,
      repairBudget: { callsPerRequest: 6, attemptsPerRequest: 2, attemptsPerCandidate: 1 },
    })
    const cost = metrics.snapshot()
    expect(cost.callsByPurpose.repair).toBeLessThanOrEqual(6)
    expect(cost.repairsAttempted).toBeLessThanOrEqual(2)
  })

  it('spends nothing at all when it is switched off', async () => {
    const metrics = new RequestMetrics()
    const uneven = fakeEngine({ detour: 1.66 })
    await generateLoops(request(), { route: uneven, metrics, flags: { localRepair: false } })
    expect(metrics.snapshot().callsByPurpose.repair).toBe(0)
    expect(metrics.snapshot().repairsAttempted).toBe(0)
  })

  it('gives the same answer twice, repairs and all', async () => {
    const uneven = () => fakeEngine({ detour: 1.66 })
    const one = await generateLoops(request(), { route: uneven(), flags: { localRepair: true } })
    const two = await generateLoops(request(), { route: uneven(), flags: { localRepair: true } })
    expect(two.routes.map(route => route.geometry)).toEqual(one.routes.map(route => route.geometry))
  })
})

/**
 * A waypoint is a place the walker chose. Every generated corner in this
 * system is the generator's own guess and may be moved; a waypoint may not,
 * whatever else is switched on.
 */
describe('places the walker chose', () => {
  const pins = [{ lng: -4.4746, lat: 54.1546 }, { lng: -4.4886, lat: 54.1566 }]
  const everything = { edgeOverlap: true, spreadCandidateBearings: true, localRepair: true, paretoArchive: true }

  it('never moves or reorders them, whatever the algorithm is doing', async () => {
    const asked = pins.map(pin => ({ ...pin }))
    const result = await generateLoops(request({ waypoints: asked, distanceKm: 6 }), {
      route: fakeEngine(),
      flags: everything,
    })
    // The request object itself is untouched...
    expect(asked).toEqual(pins)
    // ...and every walk offered still passes them, in the order they were added.
    for (const route of result.routes) {
      const line = route.geometry.coordinates as LngLat[]
      let reachedAt = -1
      for (const pin of pins) {
        const nearest = line.reduce(
          (best, point, index) => {
            const away = haversine(point, [pin.lng, pin.lat])
            return away < best.away ? { away, index } : best
          },
          { away: Infinity, index: -1 },
        )
        expect(nearest.away).toBeLessThan(120)
        expect(nearest.index).toBeGreaterThan(reachedAt)
        reachedAt = nearest.index
      }
    }
  })
})

describe('asking the network which way to look first', () => {
  const flags = { networkAwareSeeds: true }

  it('carries on exactly as before when the engine cannot answer', async () => {
    const metrics = new RequestMetrics()
    const withProbe = await generateLoops(request(), {
      route: fakeEngine(),
      reachFrom: async () => undefined,
      flags,
      metrics,
    })
    const without = await generateLoops(request(), { route: fakeEngine() })
    expect(withProbe.routes.map(route => route.geometry)).toEqual(without.routes.map(route => route.geometry))
    expect(metrics.snapshot().callsByPurpose['network-summary']).toBe(1)
  })

  it('carries on exactly as before when there is no probe to ask', async () => {
    const withFlag = await generateLoops(request(), { route: fakeEngine(), flags })
    const without = await generateLoops(request(), { route: fakeEngine() })
    expect(withFlag.routes.map(route => route.geometry)).toEqual(without.routes.map(route => route.geometry))
  })

  it('counts the probe as the engine call it is', async () => {
    const metrics = new RequestMetrics()
    await generateLoops(request(), {
      route: fakeEngine(),
      reachFrom: async (start: LngLat) => [{ point: [start[0] + 0.02, start[1]] as LngLat, networkMetres: 1500 }],
      flags,
      metrics,
    })
    expect(metrics.snapshot().callsByPurpose['network-summary']).toBe(1)
  })

  it('does not ask at all when it is switched off', async () => {
    let asked = 0
    await generateLoops(request(), {
      route: fakeEngine(),
      reachFrom: async () => { asked++; return undefined },
    })
    expect(asked).toBe(0)
  })

  it('gives the same answer twice', async () => {
    const reachFrom = async (start: LngLat) => Array.from({ length: 40 }, (_, index) => ({
      point: [start[0] + 0.001 * (index % 8), start[1] + 0.001 * Math.floor(index / 8)] as LngLat,
      networkMetres: 300 + index * 40,
    }))
    const one = await generateLoops(request(), { route: fakeEngine(), reachFrom, flags })
    const two = await generateLoops(request(), { route: fakeEngine(), reachFrom, flags })
    expect(two.routes.map(route => route.geometry)).toEqual(one.routes.map(route => route.geometry))
  })
})

describe('waypoint walks built from the backbone out', () => {
  const flags = { waypointBackbone: true }
  const pins = [{ lng: -4.4746, lat: 54.1546 }, { lng: -4.4886, lat: 54.1566 }]

  it('visits every pin, in order, and never moves one', async () => {
    const asked = pins.map(pin => ({ ...pin }))
    const result = await generateLoops(request({ waypoints: asked, distanceKm: 6 }), { route: fakeEngine(), flags })
    expect(asked).toEqual(pins)
    expect(result.routes.length).toBeGreaterThan(0)
    for (const route of result.routes) {
      const line = route.geometry.coordinates as LngLat[]
      let reachedAt = -1
      for (const pin of pins) {
        const nearest = line.reduce((best, point, index) => {
          const away = haversine(point, [pin.lng, pin.lat])
          return away < best.away ? { away, index } : best
        }, { away: Infinity, index: -1 })
        expect(nearest.away).toBeLessThan(80)
        expect(nearest.index).toBeGreaterThan(reachedAt)
        reachedAt = nearest.index
      }
    }
  })

  it('starts and finishes at the walker’s own start point', async () => {
    const result = await generateLoops(request({ waypoints: pins, distanceKm: 6 }), { route: fakeEngine(), flags })
    for (const route of result.routes) {
      const line = route.geometry.coordinates as LngLat[]
      expect(haversine(line[0], line[line.length - 1])).toBeLessThan(40)
    }
  })

  it('costs far less than routing a batch of shaped candidates', async () => {
    const before = new RequestMetrics()
    const after = new RequestMetrics()
    await generateLoops(request({ waypoints: pins, distanceKm: 6 }), {
      route: fakeEngine(),
      metrics: before,
      flags: { waypointBackbone: false },
    })
    await generateLoops(request({ waypoints: pins, distanceKm: 6 }), { route: fakeEngine(), metrics: after, flags })
    expect(after.snapshot().graphhopperCalls).toBeLessThan(before.snapshot().graphhopperCalls)
  })

  it('refuses a pin that is plainly out of reach, and says why', async () => {
    const faraway = [{ lng: -4.4816, lat: 54.2206 }]
    const result = await generateLoops(request({ waypoints: faraway, distanceKm: 2 }), { route: fakeEngine(), flags })
    expect(result.routes).toHaveLength(0)
    expect(result.expectationExceeded).toBe(true)
    expect(result.warning).toMatch(/more than 25% over/)
  })

  it('checks a real floor before refusing, not just the route it prefers', async () => {
    const asked: Array<Record<string, unknown> | undefined> = []
    const route = async (points: LngLat[], customModel: any) => {
      asked.push(customModel)
      return fakeEngine()(points)
    }
    const faraway = [{ lng: -4.4816, lat: 54.2206 }]
    await generateLoops(request({ waypoints: faraway, distanceKm: 2 }), { route, flags })
    // The profile's preferred route can be longer than the shortest one, so a
    // refusal has to be checked against a model that asks for the shortest.
    expect(asked.some(model => typeof model?.distance_influence === 'number')).toBe(true)
  })

  it('never asks for a shortest-path model when the walk plainly fits', async () => {
    const asked: Array<Record<string, unknown> | undefined> = []
    const route = async (points: LngLat[], customModel: any) => {
      asked.push(customModel)
      return fakeEngine()(points)
    }
    await generateLoops(request({ waypoints: pins, distanceKm: 6 }), { route, flags })
    expect(asked.every(model => model?.distance_influence === undefined)).toBe(true)
  })

  it('gives the same walks for the same request', async () => {
    const one = await generateLoops(request({ waypoints: pins, distanceKm: 6 }), { route: fakeEngine(), flags })
    const two = await generateLoops(request({ waypoints: pins, distanceKm: 6 }), { route: fakeEngine(), flags })
    expect(two.routes.map(route => route.geometry)).toEqual(one.routes.map(route => route.geometry))
  })

  it('answers the length that was asked for', async () => {
    const result = await generateLoops(request({ waypoints: pins, distanceKm: 6 }), { route: fakeEngine(), flags })
    for (const route of result.routes) expect(Math.abs(route.targetDifferencePercent)).toBeLessThanOrEqual(25)
  })
})

  it('leaves a pin on the doorstep to the ordinary loop generator', async () => {
    // A pin where the walker is standing constrains nothing. Treating it as a
    // route through somewhere would turn an ordinary five-kilometre loop into
    // a zero-length backbone and all slack, which is not a route problem.
    const onTheDoorstep = [{ lng: START.lng, lat: START.lat }]
    const result = await generateLoops(request({ waypoints: onTheDoorstep }), {
      route: fakeEngine(),
      flags: { waypointBackbone: true },
    })
    expect(result.routes).toHaveLength(3)
    expect(result.warning).toBeUndefined()
  })

describe('not undoing two legs for a branch that gets trimmed anyway', () => {
  it('leaves the offered walks alone while doing less work', async () => {
    const before = new RequestMetrics()
    const after = new RequestMetrics()
    const full = await generateLoops(request(), {
      route: fakeEngine(), metrics: before, flags: { pullbackTurnOnly: false },
    })
    const lean = await generateLoops(request(), {
      route: fakeEngine(), metrics: after, flags: { pullbackTurnOnly: true },
    })
    // Never more work, and the walk quality gates are unchanged either way.
    expect(after.snapshot().graphhopperCalls).toBeLessThanOrEqual(before.snapshot().graphhopperCalls)
    for (const route of lean.routes) {
      expect(route.quality.uTurnCount).toBeLessThanOrEqual(1)
      expect(route.quality.repeatedPercent).toBeLessThanOrEqual(12)
    }
    expect(lean.routes.length).toBeGreaterThan(0)
    expect(full.routes.length).toBeGreaterThan(0)
  })

  it('counts every fix-up it attempts and whether it kept the answer', async () => {
    const metrics = new RequestMetrics()
    await generateLoops(request(), { route: fakeEngine({ detour: 1.66 }), metrics })
    const fixups = metrics.snapshot().fixups
    for (const kind of ['join-pullback', 'leg-budget', 'spike'] as const) {
      expect(fixups[kind].kept).toBeLessThanOrEqual(fixups[kind].attempted)
    }
  })
})

/**
 * Waypoint mode has several ways of giving up and they all reach the walker as
 * the same sentence. Which one happened is the only thing that makes a failure
 * in production debuggable, so every exit has to say.
 */
describe('waypoint mode saying where it got to', () => {
  const pins = [{ lng: -4.4746, lat: 54.1546 }]

  const stageOf = async (overrides: Partial<LoopRequest>, flags = {}) => {
    const result = await generateLoops(request({ waypoints: pins, ...overrides }), { route: fakeEngine(), flags })
    return { result, diagnostics: result.diagnostics }
  }

  it('reports a stage on a successful waypoint walk', async () => {
    const { result, diagnostics } = await stageOf({ distanceKm: 6 })
    expect(diagnostics).toBeDefined()
    expect(diagnostics!.stage).toBeDefined()
    expect(result.routes.length).toBeGreaterThan(0)
  })

  it('says the plan was too short rather than just refusing', async () => {
    const faraway = [{ lng: -4.4816, lat: 54.2206 }]
    const { result, diagnostics } = await stageOf({ waypoints: faraway, distanceKm: 2 })
    expect(result.expectationExceeded).toBe(true)
    expect(diagnostics!.stage).toBe('over-plan')
  })

  it('says when a pin on the doorstep was handed to the ordinary generator', async () => {
    const { diagnostics } = await stageOf({ waypoints: [{ lng: START.lng, lat: START.lat }] })
    expect(diagnostics!.stage).toBe('reused-natural')
  })

  it('says which gate killed the walks it assembled', async () => {
    const { diagnostics } = await stageOf({ distanceKm: 6 })
    // Whatever the outcome, a rejection tally is the thing that explains it.
    expect(diagnostics!.rejections).toBeDefined()
    expect(diagnostics!.candidates).toBeGreaterThanOrEqual(diagnostics!.passed)
  })

  it('says a waypoint could not be reached at all', async () => {
    const unreachable = async () => { throw new GraphHopperError('Connection between locations not found', 400, 'unreachable') }
    const result = await generateLoops(request({ waypoints: pins, distanceKm: 6 }), { route: unreachable })
    expect(result.routes).toHaveLength(0)
    expect(result.diagnostics!.stage).toBe('unreachable')
  })

  it('carries the cost of a waypoint request, which used to be invisible', async () => {
    const metrics = new RequestMetrics()
    const result = await generateLoops(request({ waypoints: pins, distanceKm: 6 }), { route: fakeEngine(), metrics })
    expect(result.diagnostics!.metrics!.graphhopperCalls).toBeGreaterThan(0)
  })
})

/**
 * A guide point is the generator's own invisible shaping point and may be
 * moved when it lands somewhere only reachable one way. A waypoint is a place
 * the walker chose and may not be moved for any reason at all.
 */
describe('repairing a guide point that landed in a dead end', () => {
  const pins = [{ lng: -4.4746, lat: 54.1546 }, { lng: -4.4886, lat: 54.1566 }]
  const on = { guidePointPullback: true, waypointBackbone: true }

  it('still visits every pin, in order, at the exact coordinates given', async () => {
    const asked = pins.map(pin => ({ ...pin }))
    const result = await generateLoops(request({ waypoints: asked, distanceKm: 6 }), { route: fakeEngine(), flags: on })
    expect(asked).toEqual(pins)
    expect(result.routes.length).toBeGreaterThan(0)
    for (const route of result.routes) {
      const line = route.geometry.coordinates as LngLat[]
      let reachedAt = -1
      for (const pin of pins) {
        const nearest = line.reduce((best, point, index) => {
          const away = haversine(point, [pin.lng, pin.lat])
          return away < best.away ? { away, index } : best
        }, { away: Infinity, index: -1 })
        expect(nearest.away).toBeLessThan(80)
        expect(nearest.index).toBeGreaterThan(reachedAt)
        reachedAt = nearest.index
      }
    }
  })

  it('never asks the engine to route through a moved pin', async () => {
    const asked: LngLat[][] = []
    const route = async (points: LngLat[]) => {
      asked.push(points)
      return fakeEngine()(points)
    }
    await generateLoops(request({ waypoints: pins, distanceKm: 6 }), { route, flags: on })
    // Every pin the walker placed must appear in some request exactly as it
    // was given; a pulled-back version of one would be a different place.
    for (const pin of pins) {
      const exact = asked.some(points => points.some(point => point[0] === pin.lng && point[1] === pin.lat))
      expect(exact).toBe(true)
    }
  })

  it('costs nothing when it is switched off', async () => {
    const off = new RequestMetrics()
    await generateLoops(request({ waypoints: pins, distanceKm: 6 }), {
      route: fakeEngine(), metrics: off, flags: { waypointBackbone: true, guidePointPullback: false },
    })
    expect(off.snapshot().callsByPurpose['join-pullback']).toBe(0)
  })

  it('gives the same walks twice', async () => {
    const one = await generateLoops(request({ waypoints: pins, distanceKm: 6 }), { route: fakeEngine(), flags: on })
    const two = await generateLoops(request({ waypoints: pins, distanceKm: 6 }), { route: fakeEngine(), flags: on })
    expect(two.routes.map(route => route.geometry)).toEqual(one.routes.map(route => route.geometry))
  })
})
