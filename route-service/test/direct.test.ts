import { describe, expect, it, vi } from 'vitest'
import { DEFAULT_ROUTING_ENGINE, isRoutingEngine, resolveRoutingEngine } from '../src/loops/engine.js'
import { generateDirectLoops, isDeclined } from '../src/loops/direct.js'
import { parseLoopRequest } from '../src/http/validate.js'
import { GraphHopperError, type ClosedWalkSearch, type GraphHopperClient } from '../src/graphhopper.js'
import type { LngLat } from '../src/loops/geo.js'
import type { LoopRequest } from '../src/loops/generate.js'

/**
 * A ring of `count` walks around the start, each rotated a little, so the
 * diversity selector has genuinely different ground to choose between. Built
 * as a circle rather than as a fixture file because what these tests are about
 * is the plumbing — what is asked for, what is judged, what is handed back —
 * and a real walk is what the benchmark measures.
 */
function circleWalk(start: LngLat, radiusMetres: number, bearingRadians: number, points = 96) {
  // A circle tangent to the start: its centre sits one radius away along
  // `bearingRadians`, so the walk leaves the door heading that way and three
  // of them at different bearings barely touch each other's ground.
  const latScale = 1 / 111_320
  const lngScale = latScale / Math.cos((start[1] * Math.PI) / 180)
  const centre: LngLat = [
    start[0] + Math.sin(bearingRadians) * radiusMetres * lngScale,
    start[1] + Math.cos(bearingRadians) * radiusMetres * latScale,
  ]
  const from = bearingRadians + Math.PI
  const coordinates: number[][] = []
  for (let i = 0; i <= points; i++) {
    const angle = from + (i / points) * 2 * Math.PI
    coordinates.push([
      centre[0] + Math.sin(angle) * radiusMetres * lngScale,
      centre[1] + Math.cos(angle) * radiusMetres * latScale,
    ])
  }
  return coordinates
}

function walkPayload(start: LngLat, radiusMetres: number, bearingRadians: number, edgeBase: number) {
  const coordinates = circleWalk(start, radiusMetres, bearingRadians)
  const distance = 2 * Math.PI * radiusMetres
  return {
    paths: [{
      distance,
      time: (distance / 1.4) * 1000,
      points: { type: 'LineString', coordinates },
      instructions: [
        { text: 'Continue onto Quay Road', distance, time: (distance / 1.4) * 1000, sign: 0, interval: [0, coordinates.length - 1], street_name: 'Quay Road' },
      ],
      details: {
        // One edge id per quarter, distinct per walk, so the selector's own
        // network-overlap measure sees separate ground.
        edge_id: [0, 1, 2, 3].map(quarter => [
          Math.floor((quarter * (coordinates.length - 1)) / 4),
          Math.floor(((quarter + 1) * (coordinates.length - 1)) / 4),
          edgeBase + quarter,
        ]),
        street_name: [[0, coordinates.length - 1, 'Quay Road']],
        road_class: [[0, coordinates.length - 1, 'residential']],
      },
    }],
    looper: { searchedMetres: distance, compactness: 1, bboxRatio: 1, uTurns: 0, family: edgeBase % 8, rank: 1 },
  }
}

const START: LngLat = [-4.4816, 54.1506]

/** A radius whose circumference is the requested 5 km, so distance passes. */
const RADIUS = 5000 / (2 * Math.PI)

function searchResult(walks: unknown[], extra: Partial<ClosedWalkSearch> = {}): ClosedWalkSearch {
  return {
    walks: walks as ClosedWalkSearch['walks'],
    closedWalks: walks.length,
    rejectedShape: 0,
    rejectedTurns: 0,
    limitMetres: 2800,
    ...extra,
  }
}

const clientReturning = (result: ClosedWalkSearch | Error) => ({
  closedWalks: vi.fn(async () => {
    if (result instanceof Error) throw result
    return result
  }),
}) as unknown as GraphHopperClient & { closedWalks: ReturnType<typeof vi.fn> }

const request = (overrides: Partial<LoopRequest> = {}): LoopRequest => ({
  start: { lng: START[0], lat: START[1] },
  mode: 'distance',
  distanceKm: 5,
  units: 'km',
  variation: 0,
  ...overrides,
})

describe('choosing an engine', () => {
  it('ships pointed at the current one', () => {
    expect(DEFAULT_ROUTING_ENGINE).toBe('remote')
  })

  it('uses the server default when the request does not ask', () => {
    expect(resolveRoutingEngine({ serverDefault: 'direct', hasWaypoints: false, directAvailable: true }))
      .toEqual({ engine: 'direct', reason: 'server-default' })
  })

  it('lets an explicit request override a server default that says otherwise', () => {
    expect(resolveRoutingEngine({ requested: 'direct', serverDefault: 'remote', hasWaypoints: false, directAvailable: true }))
      .toEqual({ requested: 'direct', engine: 'direct', reason: 'requested' })
    expect(resolveRoutingEngine({ requested: 'remote', serverDefault: 'direct', hasWaypoints: false, directAvailable: true }))
      .toEqual({ requested: 'remote', engine: 'remote', reason: 'requested' })
  })

  it('sends an ordered waypoint request to the current engine whatever was asked for', () => {
    expect(resolveRoutingEngine({ requested: 'direct', serverDefault: 'direct', hasWaypoints: true, directAvailable: true }))
      .toEqual({ requested: 'direct', engine: 'remote', reason: 'waypoint-fallback' })
  })

  it('falls back where the facade cannot search walks', () => {
    expect(resolveRoutingEngine({ requested: 'direct', serverDefault: 'remote', hasWaypoints: false, directAvailable: false }))
      .toEqual({ requested: 'direct', engine: 'remote', reason: 'engine-unsupported' })
  })

  it('reads an engine off a request, and ignores one it does not know', () => {
    expect(parseLoopRequest({ ...request(), routingEngine: 'direct' }).routingEngine).toBe('direct')
    expect(parseLoopRequest({ ...request(), routingEngine: 'quantum' }).routingEngine).toBeUndefined()
    expect(isRoutingEngine('direct')).toBe(true)
    expect(isRoutingEngine('quantum')).toBe(false)
  })
})

describe('the direct closed-walk engine', () => {
  it('asks the facade for the target the walker requested', async () => {
    const client = clientReturning(searchResult([
      walkPayload(START, RADIUS, 0, 100),
      walkPayload(START, RADIUS, (2 * Math.PI) / 3, 200),
      walkPayload(START, RADIUS, (4 * Math.PI) / 3, 300),
    ]))
    const result = await generateDirectLoops(request(), { client, candidateWalks: 12 })
    expect(client.closedWalks).toHaveBeenCalledWith(START, 5000, expect.objectContaining({ wanted: 12 }))
    expect(isDeclined(result)).toBe(false)
  })

  it('offers three walks with their instructions and duration intact', async () => {
    const client = clientReturning(searchResult([
      walkPayload(START, RADIUS, 0, 100),
      walkPayload(START, RADIUS, (2 * Math.PI) / 3, 200),
      walkPayload(START, RADIUS, (4 * Math.PI) / 3, 300),
    ]))
    const result = await generateDirectLoops(request(), { client })
    if (isDeclined(result)) throw new Error(`declined: ${result.reason}`)
    expect(result.response.routes).toHaveLength(3)
    for (const route of result.response.routes) {
      expect(route.durationSeconds).toBeGreaterThan(0)
      expect(route.steps.length).toBeGreaterThan(0)
      expect(route.steps[0].instruction).toBe('Continue onto Quay Road')
      expect(route.geometry.coordinates.length).toBeGreaterThan(2)
      // The searched walk is what is returned; nothing re-routes it.
      expect(route.distanceMeters).toBe(5000)
    }
    expect(result.diagnostics.searchClosedWalks).toBe(3)
  })

  it('hands a waypoint request straight back rather than answering it', async () => {
    const client = clientReturning(searchResult([walkPayload(START, RADIUS, 0, 100)]))
    const result = await generateDirectLoops(request({ waypoints: [{ lng: -4.47, lat: 54.16 }] }), { client })
    expect(isDeclined(result) && result.reason).toBe('waypoints')
    expect(client.closedWalks).not.toHaveBeenCalled()
  })

  it('hands back rather than offering fewer walks than a whole answer', async () => {
    const client = clientReturning(searchResult([walkPayload(START, RADIUS, 0, 100)]))
    const result = await generateDirectLoops(request(), { client })
    expect(isDeclined(result) && result.reason).toBe('too-few-diverse')
    expect(isDeclined(result) && result.offered).toBe(1)
  })

  it('hands back when the gate rejects everything the search found', async () => {
    // Circumference far outside the ±12% band: the walks exist, the gate says no.
    const client = clientReturning(searchResult([
      walkPayload(START, RADIUS * 2, 0, 100),
      walkPayload(START, RADIUS * 2, (2 * Math.PI) / 3, 200),
      walkPayload(START, RADIUS * 2, (4 * Math.PI) / 3, 300),
    ]))
    const result = await generateDirectLoops(request(), { client })
    expect(isDeclined(result) && result.reason).toBe('gate-rejected-all')
  })

  it('hands back when the search finds nothing at all', async () => {
    const result = await generateDirectLoops(request(), { client: clientReturning(searchResult([])) })
    expect(isDeclined(result) && result.reason).toBe('no-closed-walk')
  })

  it('hands back when the facade cannot answer', async () => {
    const client = clientReturning(new GraphHopperError('Not found', 404, 'server'))
    const result = await generateDirectLoops(request(), { client })
    expect(isDeclined(result) && result.reason).toBe('search-server')
  })

  it('hands back when the search itself reported a failure', async () => {
    const client = clientReturning(searchResult([], { failure: 'no-circuit' }))
    const result = await generateDirectLoops(request(), { client })
    expect(isDeclined(result) && result.reason).toBe('search-no-circuit')
  })

  it('keeps a refresh off the walks already on screen', async () => {
    const walks = [
      walkPayload(START, RADIUS, 0, 100),
      walkPayload(START, RADIUS, (2 * Math.PI) / 3, 200),
      walkPayload(START, RADIUS, (4 * Math.PI) / 3, 300),
    ]
    const client = clientReturning(searchResult(walks))
    const excluded = circleWalk(START, RADIUS, 0).map(([lng, lat]) => [lng, lat] as LngLat)
    const result = await generateDirectLoops(request({ exclude: [excluded] }), { client })
    // One of the three is the walk already shown, so a whole answer is no
    // longer available and the request goes back to the current engine.
    expect(isDeclined(result) && result.reason).toBe('too-few-diverse')
    expect(isDeclined(result) && result.offered).toBe(2)
  })
})
