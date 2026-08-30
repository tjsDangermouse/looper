import { describe, expect, it, vi } from 'vitest'
import { GenerationScope, createBoundary, identify } from '../src/boundary.js'
import { avoidanceCustomModel, buildSpikeAvoidanceArea, shortestPathCustomModel } from '../src/loops/avoidance.js'
import { GraphHopperError, type GraphHopperClient } from '../src/graphhopper.js'
import type { LngLat } from '../src/loops/geo.js'

const corridor = (lng: number) => buildSpikeAvoidanceArea([lng, 54.15], 25)
const model = (lngs: number[], priority = 0.05) => avoidanceCustomModel(lngs.map(corridor), priority)!

const A: LngLat = [-4.4816, 54.1506]
const B: LngLat = [-4.4746, 54.1566]

describe('what names a corridor set', () => {
  it('the same corridors at the same strength are the same model, freshly built', () => {
    expect(identify(model([-4.48]))!.id).toBe(identify(model([-4.48]))!.id)
  })

  it('the same corridors at the two strengths are two models over one set of corridors', () => {
    const strong = identify(model([-4.48, -4.47], 0.05))!
    const relaxed = identify(model([-4.48, -4.47], 0.2))!
    expect(strong.id).not.toBe(relaxed.id)
    // The point of separating them: a retry at the weaker penalty describes no
    // polygon the strong attempt has not already described.
    expect(relaxed.areaIds).toEqual(strong.areaIds)
  })

  it('a different corridor is a different model', () => {
    expect(identify(model([-4.48]))!.id).not.toBe(identify(model([-4.47]))!.id)
  })

  it('corridor order is part of the model, because the rule names them in order', () => {
    expect(identify(model([-4.48, -4.47]))!.id).not.toBe(identify(model([-4.47, -4.48]))!.id)
  })

  it('the lower-bound model has no corridors and still has a name', () => {
    const identity = identify(shortestPathCustomModel())!
    expect(identity.areaIds).toEqual([])
    expect(identity.distanceInfluence).toBe(2000)
  })

  it('no model is no handle', () => {
    expect(identify(undefined)).toBeNull()
  })

  it('a model shaped in a way the far side was not told how to rebuild travels whole', () => {
    // Two rules, rather than the single rule naming every corridor.
    expect(identify({ priority: [{ if: 'in_a', multiply_by: '0.05' }, { if: 'in_b', multiply_by: '0.05' }] } as never)).toBeNull()
    // The right number of rules, naming something else.
    expect(identify({
      priority: [{ if: 'road_class == PRIMARY', multiply_by: '0.05' }],
      areas: model([-4.48]).areas,
    } as never)).toBeNull()
  })
})

const scopeOver = (client: Partial<GraphHopperClient>) =>
  GenerationScope.begin({ beginGeneration: async () => 'g1', ...client } as GraphHopperClient)

describe('describing a corridor once', () => {
  it('carries the model the first time and only its name once it has landed', async () => {
    const scope = (await scopeOver({}))!
    const identity = identify(model([-4.48, -4.47]))!
    const first = scope.handleFor(identity)
    expect(first.define).toBeDefined()
    expect(Object.keys(first.register ?? {})).toEqual(identity.areaIds)

    // Still unacknowledged, so a second leg dispatched alongside the first
    // describes the corridors too rather than referencing what may not have
    // arrived. Registration is idempotent, so that costs bytes and nothing else.
    expect(scope.handleFor(identity).define).toBeDefined()

    scope.acknowledge(identity)
    expect(scope.handleFor(identity)).toEqual({ generation: 'g1', id: identity.id })
    expect(scope.modelReferences).toBe(3)
  })

  it('a retry at the weaker penalty describes no polygon twice', async () => {
    const scope = (await scopeOver({}))!
    const strong = identify(model([-4.48, -4.47], 0.05))!
    scope.handleFor(strong)
    scope.acknowledge(strong)
    const relaxed = scope.handleFor(identify(model([-4.48, -4.47], 0.2))!)
    // A new model, because the strength is part of it; no new geometry.
    expect(relaxed.define).toBeDefined()
    expect(relaxed.register).toBeUndefined()
    expect(scope.areaRegistrations).toBe(2)
    expect(scope.modelDefinitions).toBe(2)
  })

  it('says all of it again when asked to', async () => {
    const scope = (await scopeOver({}))!
    const identity = identify(model([-4.48]))!
    scope.handleFor(identity)
    scope.acknowledge(identity)
    const again = scope.handleFor(identity, true)
    expect(again.define).toBeDefined()
    expect(Object.keys(again.register ?? {})).toEqual(identity.areaIds)
  })

  it('an engine that does not keep corridors is routed against the old way', async () => {
    expect(await scopeOver({ beginGeneration: async () => undefined })).toBeUndefined()
    expect(await scopeOver({ beginGeneration: async () => { throw new Error('nope') } })).toBeUndefined()
  })
})

const leg = (distance: number) => ({
  paths: [{
    distance,
    time: 1000,
    points: { coordinates: [[-4.4816, 54.1506], [-4.4746, 54.1566]] },
    instructions: [{ text: 'go', distance, time: 1000, sign: 0, interval: [0, 1] }],
    details: { edge_id: [[0, 1, 42]] },
  }],
})

const clientReturning = (payloads: unknown[]) => {
  const route = vi.fn(async () => ({
    payload: payloads[Math.min(route.mock.calls.length, payloads.length) - 1],
    requestBytes: 10, responseBytes: 20, transportMs: 1, parseMs: 0.1,
    timing: { dispatchMs: 0, routeMs: 0.5, serializeMs: 0.1 },
  }))
  return route
}

const boundaryOver = (route: ReturnType<typeof clientReturning>, memo: boolean, scope?: GenerationScope) =>
  createBoundary({ client: { route } as unknown as GraphHopperClient, scope, memo, run: call => call() })

describe('asking the same question twice', () => {
  it('asks the engine once and answers both', async () => {
    const route = clientReturning([leg(100)])
    const boundary = boundaryOver(route, true)
    const first = await boundary.route([A, B], undefined)
    const second = await boundary.route([A, B], undefined)
    expect(route).toHaveBeenCalledTimes(1)
    expect(second.distanceMeters).toBe(first.distanceMeters)
    expect(boundary.stats().memoHits).toBe(1)
  })

  it('hands out its own copy, so trimming one walk cannot reach another', async () => {
    const boundary = boundaryOver(clientReturning([leg(100)]), true)
    const first = await boundary.route([A, B], undefined)
    first.coordinates.pop()
    const second = await boundary.route([A, B], undefined)
    expect(second.coordinates).toHaveLength(2)
  })

  it('two identical questions in flight at once wait on one search', async () => {
    let release = () => {}
    const gate = new Promise<void>(resolve => { release = resolve })
    const route = vi.fn(async () => {
      await gate
      return { payload: leg(100), requestBytes: 10, responseBytes: 20, transportMs: 1, parseMs: 0, timing: { dispatchMs: 0, routeMs: 0, serializeMs: 0 } }
    })
    const boundary = boundaryOver(route as never, true)
    const both = Promise.all([boundary.route([A, B], undefined), boundary.route([A, B], undefined)])
    release()
    await both
    expect(route).toHaveBeenCalledTimes(1)
    expect(boundary.stats().memoJoins).toBe(1)
  })

  it('different points are a different question', async () => {
    const route = clientReturning([leg(100), leg(200)])
    const boundary = boundaryOver(route, true)
    await boundary.route([A, B], undefined)
    await boundary.route([B, A], undefined)
    expect(route).toHaveBeenCalledTimes(2)
  })

  it('the same points under a different corridor set are a different question', async () => {
    const route = clientReturning([leg(100), leg(200)])
    const boundary = boundaryOver(route, true)
    await boundary.route([A, B], model([-4.48]))
    await boundary.route([A, B], model([-4.47]))
    expect(route).toHaveBeenCalledTimes(2)
  })

  it('a failure is not an answer, and is not remembered as one', async () => {
    let attempts = 0
    const route = vi.fn(async () => {
      if (++attempts === 1) throw new GraphHopperError('boom', undefined, 'transport')
      return { payload: leg(100), requestBytes: 10, responseBytes: 20, transportMs: 1, parseMs: 0, timing: { dispatchMs: 0, routeMs: 0, serializeMs: 0 } }
    })
    const boundary = boundaryOver(route as never, true)
    await expect(boundary.route([A, B], undefined)).rejects.toThrow('boom')
    await expect(boundary.route([A, B], undefined)).resolves.toBeDefined()
  })

  it('asks every time when it is switched off', async () => {
    const route = clientReturning([leg(100), leg(100)])
    const boundary = boundaryOver(route, false)
    await boundary.route([A, B], undefined)
    await boundary.route([A, B], undefined)
    expect(route).toHaveBeenCalledTimes(2)
  })
})

describe('when the engine has lost a handle', () => {
  it('says the whole model again rather than routing under another one', async () => {
    const scope = (await scopeOver({}))!
    const seen: any[] = []
    const route = vi.fn(async (_points: LngLat[], options: any) => {
      seen.push(options.modelHandle)
      if (seen.length === 1) throw new GraphHopperError('unknown model handle', 409, 'handle')
      return { payload: leg(100), requestBytes: 10, responseBytes: 20, transportMs: 1, parseMs: 0, timing: { dispatchMs: 0, routeMs: 0, serializeMs: 0 } }
    })
    const boundary = createBoundary({ client: { route } as unknown as GraphHopperClient, scope, memo: false, run: call => call() })
    const avoidance = model([-4.48])

    // The scope believes the facade has these corridors — it said so — and
    // the facade has since lost them.
    scope.acknowledge(identify(avoidance)!)
    await boundary.route([A, B], avoidance)

    expect(seen).toHaveLength(2)
    expect(seen[0].define).toBeUndefined()
    expect(seen[1].define).toBeDefined()
    expect(seen[1].register).toBeDefined()
    expect(boundary.stats().rediscoveries).toBe(1)
  })

  it('a failure that is not a lost handle is not retried', async () => {
    const scope = (await scopeOver({}))!
    const route = vi.fn(async () => { throw new GraphHopperError('no path', 400, 'unreachable') })
    const boundary = createBoundary({ client: { route } as unknown as GraphHopperClient, scope, memo: false, run: call => call() })
    await expect(boundary.route([A, B], model([-4.48]))).rejects.toThrow('no path')
    expect(route).toHaveBeenCalledTimes(1)
  })

  it('a refusal still means the facade kept the corridors; a dead socket does not', async () => {
    const identity = identify(model([-4.48]))!
    const refusing = (await scopeOver({}))!
    const noPath = createBoundary({
      client: { route: async () => { throw new GraphHopperError('no path', 400, 'unreachable') } } as unknown as GraphHopperClient,
      scope: refusing, memo: false, run: call => call(),
    })
    await expect(noPath.route([A, B], model([-4.48]))).rejects.toThrow('no path')
    expect(refusing.handleFor(identity).define).toBeUndefined()

    const unreachable = (await scopeOver({}))!
    const dead = createBoundary({
      client: { route: async () => { throw new GraphHopperError('gone', undefined, 'transport') } } as unknown as GraphHopperClient,
      scope: unreachable, memo: false, run: call => call(),
    })
    await expect(dead.route([A, B], model([-4.48]))).rejects.toThrow('gone')
    expect(unreachable.handleFor(identity).define).toBeDefined()
  })
})
