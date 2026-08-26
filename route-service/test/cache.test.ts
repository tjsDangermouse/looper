import { describe, expect, it } from 'vitest'
import { DEFAULT_CACHE_LIMITS, RouteCache, cacheKeyFor, type CacheContext } from '../src/loops/cache.js'
import { DEFAULT_FLAGS } from '../src/loops/flags.js'
import type { LoopRequest, LoopResponse } from '../src/loops/generate.js'

const context: CacheContext = {
  graphVersion: '11.0:-4.9000,54.0000,-4.2500,54.5000',
  region: 'isle-of-man',
  profile: 'foot',
  profileVersion: 'looper-foot-1',
  flags: DEFAULT_FLAGS,
  generation: { candidateCount: 24, concurrency: 6 },
}

const request = (overrides: Partial<LoopRequest> = {}): LoopRequest => ({
  start: { lng: -4.4816, lat: 54.1506 },
  mode: 'distance',
  distanceKm: 5,
  units: 'km',
  variation: 0,
  ...overrides,
})

const key = (overrides: Partial<LoopRequest> = {}, ctx: Partial<CacheContext> = {}) =>
  cacheKeyFor(request(overrides), { ...context, ...ctx })

describe('what makes two requests the same request', () => {
  it('the same request twice', () => {
    expect(key()).toBe(key())
  })

  it('a different start point is a different request, however close', () => {
    expect(key({ start: { lng: -4.4816, lat: 54.1506 } }))
      .not.toBe(key({ start: { lng: -4.48161, lat: 54.1506 } }))
    // Eleven metres is a different front door, and rounding to it is how a
    // cache serves a walk starting from the next street over.
    expect(key({ start: { lng: -4.4816, lat: 54.1506 } }))
      .not.toBe(key({ start: { lng: -4.4817, lat: 54.1506 } }))
  })

  it('a different length or duration is a different request', () => {
    expect(key({ distanceKm: 5 })).not.toBe(key({ distanceKm: 5.5 }))
    expect(key({ mode: 'time', distanceKm: undefined, durationMinutes: 45 }))
      .not.toBe(key({ mode: 'time', distanceKm: undefined, durationMinutes: 60 }))
  })

  it('distance mode and time mode are different requests', () => {
    expect(key({ mode: 'distance', distanceKm: 5 })).not.toBe(key({ mode: 'time', durationMinutes: 60 }))
  })

  it('a different variation is a different request, which is what refresh means', () => {
    expect(key({ variation: 0 })).not.toBe(key({ variation: 1 }))
  })

  it('waypoints in a different order are a different request', () => {
    const a = { lng: -4.47, lat: 54.16 }
    const b = { lng: -4.49, lat: 54.15 }
    expect(key({ waypoints: [a, b] })).not.toBe(key({ waypoints: [b, a] }))
  })

  it('a different set of waypoints is a different request', () => {
    const a = { lng: -4.47, lat: 54.16 }
    const b = { lng: -4.49, lat: 54.15 }
    expect(key({ waypoints: [a] })).not.toBe(key({ waypoints: [a, b] }))
    expect(key({ waypoints: [a] })).not.toBe(key())
  })

  it('a different set of already-shown loops is a different request', () => {
    expect(key({ exclude: [[[0, 0], [0.01, 0]]] })).not.toBe(key({ exclude: [[[0, 0], [0.02, 0]]] }))
    expect(key({ exclude: [[[0, 0], [0.01, 0]]] })).not.toBe(key())
  })

  it('a different pace or activity is a different request', () => {
    expect(key({ walkingPaceMinutesPerKm: 12 })).not.toBe(key({ walkingPaceMinutesPerKm: 9 }))
    expect(key({ activity: 'running' })).not.toBe(key({ activity: 'walking' }))
  })

  it('different tuning-panel thresholds are a different request', () => {
    expect(key({ overrides: { quality: { maxDistanceError: 0.12 } } }))
      .not.toBe(key({ overrides: { quality: { maxDistanceError: 0.2 } } }))
  })

  it('does not care what order the overrides were written in', () => {
    expect(key({ overrides: { quality: { maxDistanceError: 0.2, maxUTurns: 1 } } }))
      .toBe(key({ overrides: { quality: { maxUTurns: 1, maxDistanceError: 0.2 } } }))
  })

  it('a rebuilt graph invalidates every answer taken from the old one', () => {
    expect(key({}, { graphVersion: 'a' })).not.toBe(key({}, { graphVersion: 'b' }))
  })

  it('a retuned walking profile invalidates them too', () => {
    expect(key({}, { profileVersion: 'looper-foot-1' })).not.toBe(key({}, { profileVersion: 'looper-foot-2' }))
    expect(key({}, { profile: 'foot' })).not.toBe(key({}, { profile: 'hike' }))
  })

  it('a different region is a different request even at the same coordinates', () => {
    expect(key({}, { region: 'isle-of-man' })).not.toBe(key({}, { region: 'england' }))
  })

  it('a different algorithm is a different request', () => {
    expect(key({}, { flags: { ...DEFAULT_FLAGS, localRepair: true } }))
      .not.toBe(key({}, { flags: { ...DEFAULT_FLAGS, localRepair: false } }))
  })

  it('different generation settings are a different request', () => {
    expect(key({}, { generation: { candidateCount: 24 } })).not.toBe(key({}, { generation: { candidateCount: 32 } }))
  })
})

describe('the store itself', () => {
  const response = (routes: number): LoopResponse => ({
    routes: Array.from({ length: routes }, (_, index) => ({ id: `r${index}` })) as LoopResponse['routes'],
  })

  it('gives back what it was given', () => {
    const cache = new RouteCache(DEFAULT_CACHE_LIMITS, () => 1000)
    cache.set('a', response(3))
    expect(cache.get('a')?.value.routes).toHaveLength(3)
    expect(cache.get('a')?.ageMs).toBe(0)
  })

  it('knows nothing it was never told', () => {
    expect(new RouteCache().get('missing')).toBeUndefined()
  })

  it('forgets an answer once it is stale', () => {
    let now = 0
    const cache = new RouteCache({ ...DEFAULT_CACHE_LIMITS, ttlMs: 1000 }, () => now)
    cache.set('a', response(3))
    now = 999
    expect(cache.get('a')).toBeDefined()
    now = 1000
    expect(cache.get('a')).toBeUndefined()
  })

  it('forgets a refusal sooner than an answer', () => {
    let now = 0
    const cache = new RouteCache({ maxEntries: 10, ttlMs: 10_000, emptyTtlMs: 1000 }, () => now)
    cache.set('walks', response(3))
    cache.set('nothing', response(0))
    now = 1500
    expect(cache.get('walks')).toBeDefined()
    // "No clean loop here" is about a moment as much as a place.
    expect(cache.get('nothing')).toBeUndefined()
  })

  it('says how old an answer is', () => {
    let now = 0
    const cache = new RouteCache(DEFAULT_CACHE_LIMITS, () => now)
    cache.set('a', response(3))
    now = 4321
    expect(cache.get('a')?.ageMs).toBe(4321)
  })

  it('never grows past its limit', () => {
    const cache = new RouteCache({ ...DEFAULT_CACHE_LIMITS, maxEntries: 3 })
    for (let index = 0; index < 50; index++) cache.set(`key${index}`, response(3))
    expect(cache.size).toBe(3)
  })

  it('forgets what has not been asked for lately, not what has', () => {
    const cache = new RouteCache({ ...DEFAULT_CACHE_LIMITS, maxEntries: 2 })
    cache.set('busy', response(3))
    cache.set('quiet', response(3))
    cache.get('busy')
    cache.set('new', response(3))
    expect(cache.get('busy')).toBeDefined()
    expect(cache.get('quiet')).toBeUndefined()
  })

  it('replaces an answer rather than keeping two of it', () => {
    const cache = new RouteCache()
    cache.set('a', response(3))
    cache.set('a', response(1))
    expect(cache.size).toBe(1)
    expect(cache.get('a')?.value.routes).toHaveLength(1)
  })

  it('drops what has expired when asked to tidy up', () => {
    let now = 0
    const cache = new RouteCache({ ...DEFAULT_CACHE_LIMITS, ttlMs: 100 }, () => now)
    cache.set('a', response(3))
    cache.set('b', response(3))
    now = 200
    cache.prune()
    expect(cache.size).toBe(0)
  })
})
