import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import type { AddressInfo } from 'node:net'
import { MAX_DISTANCE_KM, MIN_DURATION_MINUTES, ValidationError, parseLoopRequest } from '../src/http/validate.js'
import { createRateLimiter } from '../src/http/rateLimit.js'
import { createApp } from '../src/server.js'
import { GraphHopperClient } from '../src/graphhopper.js'

describe('input validation', () => {
  const valid = { start: { lng: -4.4816, lat: 54.1506 }, mode: 'distance', distanceKm: 5, units: 'km' }

  it('accepts a well-formed distance request', () => {
    expect(parseLoopRequest(valid)).toEqual({ start: { lng: -4.4816, lat: 54.1506 }, mode: 'distance', distanceKm: 5, durationMinutes: undefined, units: 'km', variation: 0 })
  })
  it('accepts a time request', () => {
    const parsed = parseLoopRequest({ ...valid, mode: 'time', distanceKm: undefined, durationMinutes: 45 })
    expect(parsed.mode).toBe('time')
    expect(parsed.durationMinutes).toBe(45)
  })
  it('normalises a walking pace in miles to minutes per kilometre', () => {
    const parsed = parseLoopRequest({ ...valid, walkingPaceMinutes: 16, walkingPaceUnit: 'mi' })
    expect(parsed.walkingPaceMinutesPerKm).toBeCloseTo(25.75, 2)
  })
  it('accepts a running request and its quicker pace', () => {
    const parsed = parseLoopRequest({ ...valid, activity: 'running', walkingPaceMinutes: 3, walkingPaceUnit: 'km' })
    expect(parsed.activity).toBe('running')
    expect(parsed.walkingPaceMinutesPerKm).toBe(3)
  })
  it('defaults the variation to zero', () => expect(parseLoopRequest(valid).variation).toBe(0))
  it('keeps a variation it is given', () => expect(parseLoopRequest({ ...valid, variation: 3 }).variation).toBe(3))
  it('keeps previously offered routes out of a refresh', () => {
    expect(parseLoopRequest({ ...valid, exclude: [[[0, 0], [0.001, 0]]] }).exclude).toEqual([[[0, 0], [0.001, 0]]])
  })
  it('refuses malformed previous routes', () => {
    expect(() => parseLoopRequest({ ...valid, exclude: [[['no', 'route']]] })).toThrow(ValidationError)
  })
  it('refuses a start point off the globe', () => {
    expect(() => parseLoopRequest({ ...valid, start: { lng: 400, lat: 0 } })).toThrow(ValidationError)
    expect(() => parseLoopRequest({ ...valid, start: undefined })).toThrow(ValidationError)
  })
  it('refuses a distance nobody would walk', () => {
    expect(() => parseLoopRequest({ ...valid, distanceKm: 0 })).toThrow(ValidationError)
    expect(() => parseLoopRequest({ ...valid, distanceKm: MAX_DISTANCE_KM + 1 })).toThrow(ValidationError)
  })
  it('refuses a duration nobody would walk', () => {
    expect(() => parseLoopRequest({ ...valid, mode: 'time', durationMinutes: MIN_DURATION_MINUTES - 1 })).toThrow(ValidationError)
  })
  it('refuses an unknown mode or unit', () => {
    expect(() => parseLoopRequest({ ...valid, mode: 'vibes' })).toThrow(ValidationError)
    expect(() => parseLoopRequest({ ...valid, units: 'furlongs' })).toThrow(ValidationError)
  })
  it('explains itself in words a walker would understand', () => {
    try {
      parseLoopRequest({ ...valid, distanceKm: 900 })
      throw new Error('should have thrown')
    } catch (error) {
      expect((error as Error).message).toBe('Choose a loop between 0.5 and 30 km.')
      expect((error as Error).message).not.toMatch(/graphhopper|json|null|undefined/i)
    }
  })
})

describe('rate limiting', () => {
  it('lets a walker through and then asks them to wait', () => {
    const limiter = createRateLimiter(3)
    expect([1, 2, 3].map(() => limiter.take('a'))).toEqual([true, true, true])
    expect(limiter.take('a')).toBe(false)
  })
  it('counts each client separately', () => {
    const limiter = createRateLimiter(1)
    expect(limiter.take('a')).toBe(true)
    expect(limiter.take('b')).toBe(true)
  })
  it('forgives after the window passes', () => {
    const limiter = createRateLimiter(1)
    expect(limiter.take('a', 0)).toBe(true)
    expect(limiter.take('a', 30_000)).toBe(false)
    expect(limiter.take('a', 61_000)).toBe(true)
  })
})

describe('the HTTP surface', () => {
  let base: string
  const server = createApp({
    // No engine behind it: these tests are about the API's own manners.
    graphhopper: new GraphHopperClient('http://127.0.0.1:1', 'foot', 50),
  })

  beforeAll(async () => {
    await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
    base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
  })
  afterAll(() => new Promise<void>(resolve => { server.close(() => resolve()) }))

  const post = (body: unknown) => fetch(`${base}/v1/loops`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })

  it('reports its health, and the engine’s', async () => {
    const response = await fetch(`${base}/health`)
    const body = await response.json()
    expect(response.status).toBe(503)
    expect(body.engine.reachable).toBe(false)
  })
  it('answers a preflight', async () => {
    const response = await fetch(`${base}/v1/loops`, { method: 'OPTIONS' })
    expect(response.status).toBe(204)
    expect(response.headers.get('access-control-allow-methods')).toContain('POST')
  })
  it('refuses the wrong method', async () => {
    expect((await fetch(`${base}/v1/loops`)).status).toBe(405)
  })
  it('has nothing at any other path', async () => {
    expect((await fetch(`${base}/v2/loops`)).status).toBe(404)
  })
  it('rejects a malformed body without saying how the sausage is made', async () => {
    const response = await fetch(`${base}/v1/loops`, { method: 'POST', body: 'not json' })
    expect(response.status).toBe(400)
    expect((await response.json()).error).toBe('Send a valid route request.')
  })
  it('rejects an invalid request with advice', async () => {
    const response = await post({ start: { lng: 0, lat: 0 }, mode: 'distance', distanceKm: 900, units: 'km' })
    expect(response.status).toBe(400)
    expect((await response.json()).error).toMatch(/Choose a loop/)
  })
  it('never names the routing engine when it is unreachable', async () => {
    const response = await post({ start: { lng: -4.4816, lat: 54.1506 }, mode: 'distance', distanceKm: 4, units: 'km' })
    expect(response.status).toBe(503)
    const text = JSON.stringify(await response.json())
    expect(text).not.toMatch(/graphhopper|openrouteservice|ors|127\.0\.0\.1/i)
  })
  it('never lets a route answer be cached', async () => {
    const response = await post({ start: { lng: 0, lat: 0 }, mode: 'distance', distanceKm: 900, units: 'km' })
    expect(response.headers.get('cache-control')).toBe('no-store')
  })
})
