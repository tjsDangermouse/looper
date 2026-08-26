import { describe, expect, it } from 'vitest'
import booleanPointInPolygon from '@turf/boolean-point-in-polygon'
import { AVOID_PRIORITY, RELAXED_AVOID_PRIORITY } from '../src/loops/avoidance.js'
import { buildRouteBody, GraphHopperError, parseLeg, maneuverName, isUTurnSign, type GraphHopperLeg } from '../src/graphhopper.js'
import { LEG_BUDGET_SHARE, buildLoopIncrementally, joinLegGeometries, routeLegAttempt } from '../src/loops/routing.js'
import type { LngLat } from '../src/loops/geo.js'
import { FIXTURE_ORIGIN, at, polyline } from './fixtures/routes.js'

const START: LngLat = FIXTURE_ORIGIN
const TARGET = 5000

/** A router that answers every leg with a straight line between its points. */
function straightRouter(record: Array<{ points: LngLat[]; model: any }> = []) {
  const route = async (points: LngLat[], model: any): Promise<GraphHopperLeg> => {
    record.push({ points, model })
    const coordinates = densify(points[0], points[1])
    const distanceMeters = metres(points[0], points[1])
    return {
      coordinates,
      distanceMeters,
      durationSeconds: distanceMeters / (5000 / 3600),
      steps: [
        { instruction: 'Continue', distanceMeters, durationSeconds: distanceMeters / 1.39, sign: 0, startIndex: 0, endIndex: coordinates.length - 1 },
        { instruction: 'Arrive at destination', distanceMeters: 0, durationSeconds: 0, sign: 4, startIndex: coordinates.length - 1, endIndex: coordinates.length - 1 },
      ],
    }
  }
  return { route, record }
}

const metres = (a: LngLat, b: LngLat) => {
  const dy = (b[1] - a[1]) * 111195
  const dx = (b[0] - a[0]) * 111195 * Math.cos((a[1] * Math.PI) / 180)
  return Math.hypot(dx, dy)
}
function densify(a: LngLat, b: LngLat): LngLat[] {
  const steps = Math.max(2, Math.round(metres(a, b) / 25))
  return Array.from({ length: steps + 1 }, (_, i) => [a[0] + (b[0] - a[0]) * (i / steps), a[1] + (b[1] - a[1]) * (i / steps)] as LngLat)
}

const same = (a: LngLat, b: LngLat) => Math.abs(a[0] - b[0]) < 1e-9 && Math.abs(a[1] - b[1]) < 1e-9

describe('the request sent to the routing engine', () => {
  it('asks for one ordinary leg, not a round trip', () => {
    const body = buildRouteBody([START, at(500, 500)], { profile: 'foot' })
    expect(body.points).toHaveLength(2)
    expect(JSON.stringify(body)).not.toContain('round_trip')
    expect(body.profile).toBe('foot')
  })
  it('turns off contraction hierarchies, which a per-request custom model needs', () => {
    expect(buildRouteBody([START, at(1, 1)], { profile: 'foot' })['ch.disable']).toBe(true)
  })
  it('asks for plain coordinates and turn instructions the walk screen can use', () => {
    const body = buildRouteBody([START, at(1, 1)], { profile: 'foot' })
    expect(body.points_encoded).toBe(false)
    expect(body.instructions).toBe(true)
    expect(body.details).toContain('street_name')
  })
  it('carries the custom model only when there is something to avoid', () => {
    expect(buildRouteBody([START, at(1, 1)], { profile: 'foot' }).custom_model).toBeUndefined()
    const model = { priority: [{ if: 'in_looper_avoid_0', multiply_by: '0.05' }] }
    expect(buildRouteBody([START, at(1, 1)], { profile: 'foot', customModel: model }).custom_model).toBe(model)
  })
})

describe('reading the engine’s answer', () => {
  const payload = {
    paths: [{
      distance: 1200.5,
      time: 900000,
      points: { type: 'LineString', coordinates: [[-4.48, 54.15], [-4.47, 54.16]] },
      instructions: [
        { text: 'Turn left onto Quay Road', distance: 800, time: 600000, sign: -2, street_name: 'Quay Road', interval: [0, 1] },
        { text: 'Arrive at destination', distance: 0, time: 0, sign: 4, street_name: '', interval: [1, 1] },
      ],
      details: { street_name: [[0, 1, 'Quay Road']], road_class: [[0, 1, 'residential']] },
    }],
  }
  it('reads distance, duration and geometry', () => {
    const leg = parseLeg(payload)
    expect(leg.distanceMeters).toBe(1200.5)
    expect(leg.durationSeconds).toBe(900)
    expect(leg.coordinates).toHaveLength(2)
  })
  it('keeps the street name the walk screen reads aloud', () => {
    expect(parseLeg(payload).steps[0].road).toBe('Quay Road')
  })
  it('keeps the road class used to distinguish paths from roads', () => {
    expect(parseLeg(payload).steps[0].roadClass).toBe('residential')
  })
  it('names the manoeuvre without exposing the engine’s numbering', () => {
    expect(maneuverName(-2)).toBe('turn-left')
    expect(maneuverName(4)).toBe('finish')
    expect(isUTurnSign(-98)).toBe(true)
    expect(isUTurnSign(2)).toBe(false)
  })
  it('treats a pathless answer as a leg that cannot be walked', () => {
    expect(() => parseLeg({ paths: [] })).toThrow(GraphHopperError)
  })
})

describe('building a loop leg by leg', () => {
  it('routes four legs in order, closing back on the start', async () => {
    const { route, record } = straightRouter()
    const candidate = await buildLoopIncrementally(START, TARGET, 0, 'clockwise', route)
    expect(candidate).toBeDefined()
    expect(record).toHaveLength(4)
    expect(record[0].points[0]).toEqual(START)
    for (let i = 1; i < record.length; i++) expect(record[i].points[0]).toEqual(record[i - 1].points[1])
    expect(record[3].points[1]).toEqual(START)
  })
  it('sends no avoidance on the first leg and some on every leg after', async () => {
    const { route, record } = straightRouter()
    await buildLoopIncrementally(START, TARGET, 0, 'clockwise', route)
    expect(record[0].model).toBeUndefined()
    for (const call of record.slice(1)) {
      expect(call.model.priority.length).toBeGreaterThan(0)
      expect(call.model.priority[0].multiply_by).toBe(String(AVOID_PRIORITY))
    }
  })
  it('hands on the ground every earlier leg covered', async () => {
    const { route, record } = straightRouter()
    await buildLoopIncrementally(START, TARGET, 0, 'clockwise', route)
    const areas = record[3].model.areas.features
    const midpointOfLegOne = midpoint(record[0].points[0], record[0].points[1])
    const midpointOfLegTwo = midpoint(record[1].points[0], record[1].points[1])
    expect(areas.some((area: any) => booleanPointInPolygon(midpointOfLegOne, area))).toBe(true)
    expect(areas.some((area: any) => booleanPointInPolygon(midpointOfLegTwo, area))).toBe(true)
  })
  it('never penalises the streets on the doorstep', async () => {
    const { route, record } = straightRouter()
    await buildLoopIncrementally(START, TARGET, 0, 'clockwise', route)
    for (const call of record.slice(1)) {
      for (const area of call.model.areas.features) expect(booleanPointInPolygon(START, area)).toBe(false)
    }
  })
  it('turns a consistent way round the compass for the direction asked', async () => {
    // Mirrored attempts share a starting bearing — the same first corner,
    // opposite ways round — so the divergence only shows from the second leg.
    const cw = straightRouter()
    await buildLoopIncrementally(START, TARGET, 0, 'clockwise', cw.route)
    const ccw = straightRouter()
    await buildLoopIncrementally(START, TARGET, 0, 'counter-clockwise', ccw.route)
    expect(cw.record[0].points[1]).toEqual(ccw.record[0].points[1])
    expect(cw.record[1].points[1]).not.toEqual(ccw.record[1].points[1])
  })
  it('retries a blocked leg once, still penalised but less absolutely', async () => {
    const calls: any[] = []
    let refused = false
    const route = async (points: LngLat[], model: any) => {
      calls.push({ points, model })
      if (model && model.priority[0].multiply_by === String(AVOID_PRIORITY) && !refused) {
        refused = true
        throw new GraphHopperError('Connection between locations not found', 400, 'unreachable')
      }
      return straightRouter().route(points, model)
    }
    const candidate = await buildLoopIncrementally(START, TARGET, 0, 'clockwise', route)
    expect(candidate).toBeDefined()
    expect(calls[2].model.priority[0].multiply_by).toBe(String(RELAXED_AVOID_PRIORITY))
    expect(calls[2].points).toEqual(calls[1].points)
  })
  it('spends the retry when the penalty buys an absurd detour, not only on a refusal', async () => {
    // The real failure in open country: the engine never refuses a penalised
    // corridor, it walks six kilometres round it. Nothing throws, so a retry
    // that only fires on an exception never fires at all.
    const calls: any[] = []
    const route = async (points: LngLat[], model: any) => {
      calls.push({ points, model })
      const leg = await straightRouter().route(points, model)
      const heavilyPenalised = model?.priority?.[0]?.multiply_by === String(AVOID_PRIORITY)
      return heavilyPenalised ? { ...leg, distanceMeters: 9000 } : leg
    }
    const candidate = await buildLoopIncrementally(START, TARGET, 0, 'clockwise', route, { legBudgetMetres: 2500 })
    expect(candidate).toBeDefined()
    // Leg one is unpenalised; every leg after it gets a second, cheaper try.
    expect(calls.filter(call => call.model?.priority?.[0]?.multiply_by === String(RELAXED_AVOID_PRIORITY)).length).toBeGreaterThanOrEqual(3)
    expect(candidate!.legs.slice(1).every(leg => leg.relaxed)).toBe(true)
    expect(candidate!.distanceMeters).toBeLessThan(9000 * 4)
  })

  it('keeps the strongly penalised leg when relaxing it does not actually help', async () => {
    const route = async (points: LngLat[], model: any) => {
      const leg = await straightRouter().route(points, model)
      return model ? { ...leg, distanceMeters: 9000 } : leg
    }
    const candidate = await buildLoopIncrementally(START, TARGET, 0, 'clockwise', route, { legBudgetMetres: 2500 })
    expect(candidate!.legs.slice(1).every(leg => leg.relaxed)).toBe(false)
  })

  it('leaves a leg inside its budget alone', async () => {
    const { route, record } = straightRouter()
    await buildLoopIncrementally(START, TARGET, 0, 'clockwise', route, { legBudgetMetres: 50_000 })
    expect(record).toHaveLength(4)
  })

  it('holds one leg to half the walk before calling the penalty the problem', () => {
    expect(LEG_BUDGET_SHARE).toBe(0.5)
  })

  it('pulls a dead-ending waypoint back toward the start and re-routes both legs that meet there', async () => {
    // The first corner the builder aims for, found by watching an unrigged
    // run: only reachable via a spur through D, so the leg arriving there and
    // the leg leaving it both detour via D — the walk arrives at the corner
    // heading one way and immediately leaves heading back the way it came,
    // exactly what a cul-de-sac produces.
    const probe = straightRouter()
    await buildLoopIncrementally(START, TARGET, 0, 'clockwise', probe.route)
    const waypoint1 = probe.record[0].points[1]
    const D: LngLat = [START[0] + (waypoint1[0] - START[0]) * 0.4, START[1] + (waypoint1[1] - START[1]) * 0.4]
    const calls: Array<{ points: LngLat[] }> = []
    const route = async (legPoints: LngLat[], model: any): Promise<GraphHopperLeg> => {
      calls.push({ points: legPoints })
      const [a, b] = legPoints
      if (same(a, waypoint1) || same(b, waypoint1)) {
        const viaD = joinLegGeometries([await straightRouter().route([a, D], model), await straightRouter().route([D, b], model)])
        return { ...viaD, steps: [] }
      }
      return straightRouter().route(legPoints, model)
    }
    const candidate = await buildLoopIncrementally(START, TARGET, 0, 'clockwise', route)
    expect(candidate).toBeDefined()
    // The dead end was tried at least once, and both legs meeting there were
    // then routed a second time to or from some other point — the pulled-in
    // replacement, not the original waypoint.
    const toOrFromWaypoint1 = calls.filter(call => same(call.points[0], waypoint1) || same(call.points[1], waypoint1))
    expect(toOrFromWaypoint1.length).toBeGreaterThan(0)
    const avoidingWaypoint1 = calls.filter(call => !same(call.points[0], waypoint1) && !same(call.points[1], waypoint1))
    expect(avoidingWaypoint1.length).toBeGreaterThan(0)
    // The pulled-in point replaces the original in the final route: nothing in
    // the joined geometry sits exactly on the dead end any more.
    expect(candidate!.coordinates.some(point => same(point, waypoint1))).toBe(false)
  })

  it('tries a different aim for a corner leg that would retrace part of the one before it', async () => {
    // The second corner's first-choice target, found by watching an unrigged
    // run. Reaching it is rigged to require retracing 200 m back along the
    // first leg's own corridor first — short enough to be a dead end given up
    // on, not a promenade — before continuing on. Any other target routes
    // cleanly.
    const probe = straightRouter()
    await buildLoopIncrementally(START, TARGET, 0, 'clockwise', probe.route)
    const leg1Target = probe.record[0].points[1]
    const poisonedTarget = probe.record[1].points[1]
    const pointAt = (from: LngLat, to: LngLat, along: number): LngLat => {
      const t = along / metres(from, to)
      return [from[0] + (to[0] - from[0]) * t, from[1] + (to[1] - from[1]) * t]
    }
    const retracePoint = pointAt(leg1Target, START, 200)

    const calls: LngLat[][] = []
    const route = async (points: LngLat[], model: any): Promise<GraphHopperLeg> => {
      calls.push(points)
      const [a, b] = points
      if (same(a, leg1Target) && same(b, poisonedTarget)) {
        const coordinates = [...densify(a, retracePoint), ...densify(retracePoint, b).slice(1)]
        const distanceMeters = metres(a, retracePoint) + metres(retracePoint, b)
        return {
          coordinates,
          distanceMeters,
          durationSeconds: distanceMeters / (5000 / 3600),
          steps: [
            { instruction: 'Continue', distanceMeters, durationSeconds: distanceMeters / 1.39, sign: 0, startIndex: 0, endIndex: coordinates.length - 1 },
            { instruction: 'Arrive at destination', distanceMeters: 0, durationSeconds: 0, sign: 4, startIndex: coordinates.length - 1, endIndex: coordinates.length - 1 },
          ],
        }
      }
      return straightRouter().route(points, model)
    }
    const candidate = await buildLoopIncrementally(START, TARGET, 0, 'clockwise', route)
    expect(candidate).toBeDefined()
    // The poisoned target was tried at least once...
    expect(calls.some(call => same(call[0], leg1Target) && same(call[1], poisonedTarget))).toBe(true)
    // ...but the leg that was actually kept does not end there.
    const secondLeg = candidate!.legs[1]
    expect(same(secondLeg.coordinates[secondLeg.coordinates.length - 1], poisonedTarget)).toBe(false)
  })

  it('cuts a tiny spike that survives every attempt to route round it from the finished geometry', async () => {
    // Every leg — including any reroute the spike-avoidance logic tries —
    // comes back with an unavoidable 15 m out-and-back stitched into its
    // middle: the ground genuinely offers no other way for that one stretch.
    const tips: LngLat[] = []
    const withTinySpike = (leg: GraphHopperLeg): GraphHopperLeg => {
      const mid = Math.floor(leg.coordinates.length / 2)
      const [mx, my] = leg.coordinates[mid]
      const [nx, ny] = leg.coordinates[mid + 1] ?? leg.coordinates[mid - 1]
      const dx = nx - mx, dy = ny - my
      const len = Math.hypot(dx, dy) || 1e-9
      const spikeDegrees = 15 / 111195
      const tip: LngLat = [mx - (dy / len) * spikeDegrees, my + (dx / len) * spikeDegrees]
      tips.push(tip)
      const coordinates = [...leg.coordinates.slice(0, mid + 1), tip, leg.coordinates[mid], ...leg.coordinates.slice(mid + 1)]
      const spikeDistance = metres(leg.coordinates[mid], tip) * 2
      return {
        ...leg,
        coordinates,
        distanceMeters: leg.distanceMeters + spikeDistance,
        steps: [
          { instruction: 'Continue', distanceMeters: leg.distanceMeters + spikeDistance, durationSeconds: 1, sign: 0, startIndex: 0, endIndex: coordinates.length - 1 },
          { instruction: 'Arrive at destination', distanceMeters: 0, durationSeconds: 0, sign: 4, startIndex: coordinates.length - 1, endIndex: coordinates.length - 1 },
        ],
      }
    }
    const route = async (points: LngLat[], model: any): Promise<GraphHopperLeg> => withTinySpike(await straightRouter().route(points, model))
    const candidate = await buildLoopIncrementally(START, TARGET, 0, 'clockwise', route)
    expect(candidate).toBeDefined()
    // None of the injected spike tips survive in the finished geometry.
    const closeToAnyTip = (point: LngLat) => tips.some(tip => metres(point, tip) < 1)
    expect(candidate!.coordinates.some(closeToAnyTip)).toBe(false)
    // The steps still describe a walkable, in-order route.
    for (const step of candidate!.steps) {
      expect(step.startIndex!).toBeGreaterThanOrEqual(0)
      expect(step.endIndex!).toBeLessThan(candidate!.coordinates.length)
      expect(step.endIndex!).toBeGreaterThanOrEqual(step.startIndex!)
    }
  })

  it('gives the candidate up rather than routing it without any penalty at all', async () => {
    const attempts: any[] = []
    const route = async (points: LngLat[], model: any) => {
      attempts.push(model)
      if (model) throw new GraphHopperError('no path', 400, 'unreachable')
      return straightRouter().route(points, model)
    }
    const candidate = await buildLoopIncrementally(START, TARGET, 0, 'clockwise', route)
    expect(candidate).toBeUndefined()
    // Leg one unpenalised; every attempt after that carried some avoidance
    // penalty — it never falls back to routing without one, however many
    // locally-adjusted retries it spends trying to find a way through.
    expect(attempts.filter(model => model === undefined)).toHaveLength(1)
    expect(attempts.length).toBeGreaterThan(1)
  })
  it('lets the engine being unreachable surface rather than swallowing it', async () => {
    const route = async () => { throw new GraphHopperError('down', undefined, 'transport') }
    await expect(buildLoopIncrementally(START, TARGET, 0, 'clockwise', route)).rejects.toThrow(GraphHopperError)
  })
  it('abandons a candidate that has already overshot', async () => {
    const { route } = straightRouter()
    const candidate = await buildLoopIncrementally(START, TARGET, 0, 'clockwise', route, { abandonAboveMetres: 100 })
    expect(candidate).toBeUndefined()
  })
})

describe('joining the legs into one walk', () => {
  const leg = (from: LngLat, to: LngLat, instruction: string): GraphHopperLeg => {
    const coordinates = densify(from, to)
    return {
      coordinates,
      distanceMeters: metres(from, to),
      durationSeconds: 100,
      steps: [
        { instruction, distanceMeters: metres(from, to), durationSeconds: 100, sign: 0, startIndex: 0, endIndex: coordinates.length - 1 },
        { instruction: 'Arrive at destination', distanceMeters: 0, durationSeconds: 0, sign: 4, startIndex: coordinates.length - 1, endIndex: coordinates.length - 1 },
      ],
    }
  }
  const a = at(0, 0), b = at(600, 0), c = at(600, 600)
  const joined = joinLegGeometries([leg(a, b, 'Head east'), leg(b, c, 'Turn left')])

  it('does not repeat the point where two legs meet', () => {
    const seam = joined.coordinates.filter(point => point[0] === b[0] && point[1] === b[1])
    expect(seam).toHaveLength(1)
  })
  it('drops the arrival at every waypoint but the last', () => {
    const arrivals = joined.steps.filter(step => step.sign === 4)
    expect(arrivals).toHaveLength(1)
    expect(joined.steps[joined.steps.length - 1].sign).toBe(4)
  })
  it('adds up the distance and the time', () => {
    expect(joined.distanceMeters).toBeCloseTo(1200, 0)
    expect(joined.durationSeconds).toBe(200)
  })
  it('rebases each step onto the joined line', () => {
    for (const step of joined.steps) {
      expect(step.startIndex!).toBeGreaterThanOrEqual(0)
      expect(step.endIndex!).toBeLessThan(joined.coordinates.length)
    }
    expect(joined.steps[1].startIndex).toBeGreaterThan(joined.steps[0].endIndex! - 1)
  })
})

const midpoint = (a: LngLat, b: LngLat): LngLat => [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]
void polyline

/**
 * Edge spans index into the line they came from. Every operation that changes
 * the line has to move them with it, or the retrace measurement is being taken
 * against a walk that no longer exists.
 */
describe('carrying edge ids through a joined walk', () => {
  const leg = (coordinates: LngLat[], edges: Array<[number, number, number]>) => ({
    coordinates,
    distanceMeters: 100 * (coordinates.length - 1),
    durationSeconds: 72 * (coordinates.length - 1),
    steps: [],
    edges: edges.map(([startIndex, endIndex, id]) => ({ id, startIndex, endIndex })),
  })

  it('rebases every span onto the joined line', () => {
    const first = leg([at(0, 0), at(100, 0), at(200, 0)], [[0, 1, 10], [1, 2, 11]])
    const second = leg([at(200, 0), at(300, 0)], [[0, 1, 12]])
    const joined = joinLegGeometries([first, second])
    // The shared point at the seam is dropped, so the second leg starts at 2.
    expect(joined.edges).toEqual([
      { id: 10, startIndex: 0, endIndex: 1 },
      { id: 11, startIndex: 1, endIndex: 2 },
      { id: 12, startIndex: 2, endIndex: 3 },
    ])
  })

  it('reports no edges at all when any one leg could not report its own', () => {
    const withEdges = leg([at(0, 0), at(100, 0)], [[0, 1, 10]])
    const without = { ...leg([at(100, 0), at(200, 0)], []), edges: undefined }
    // Half a picture of which edges were walked would under-report retracing,
    // which is worse than falling back to geometry for the whole walk.
    expect(joinLegGeometries([withEdges, without]).edges).toBeUndefined()
  })

  it('leaves the joined walk without edges when no leg had any', () => {
    const plain = { ...leg([at(0, 0), at(100, 0)], []), edges: undefined }
    expect(joinLegGeometries([plain, plain]).edges).toBeUndefined()
  })
})

/**
 * Each leg can pay for a speculative reroute and throw the answer away. On
 * real ground those retries are 43% of every engine call the service makes, so
 * what decides whether one is worth attempting is worth testing directly.
 */
describe('paying for a reroute only when it can help', () => {
  /** Records every pair routed, and answers with a leg of a chosen length. */
  const recordingRouter = (metresFor: (points: LngLat[], attempt: number) => number) => {
    const asked: Array<{ points: LngLat[]; priority?: string }> = []
    let attempt = 0
    const route = async (points: LngLat[], model: any): Promise<GraphHopperLeg> => {
      asked.push({ points, priority: model?.priority?.[0]?.multiply_by })
      const metres = metresFor(points, attempt++)
      const coordinates = [points[0], points[1]] as LngLat[]
      return {
        coordinates,
        distanceMeters: metres,
        durationSeconds: metres / 1.39,
        steps: [{ instruction: 'Continue', distanceMeters: metres, durationSeconds: metres / 1.39, sign: 0, startIndex: 0, endIndex: 1 }],
      }
    }
    return { route, asked }
  }

  const walked = [polyline([[0, 0], [0, 600]])]
  const from: LngLat = at(0, 0)
  const to: LngLat = at(600, 0)

  it('reroutes an over-long leg that clearly went round something', async () => {
    // Six hundred metres apart, two kilometres walked: it went round something.
    const { route, asked } = recordingRouter(() => 2000)
    await routeLegAttempt(route, START, walked, from, to, { legBudgetMetres: 1000, budgetDetourGate: true })
    expect(asked).toHaveLength(2)
    expect(asked[1].priority).toBe(String(RELAXED_AVOID_PRIORITY))
  })

  it('does not reroute a leg that is long simply because its target is far', async () => {
    // Long against the budget, but barely longer than the straight line — the
    // penalty is not what made it long, so a weaker one will not shorten it.
    const { route, asked } = recordingRouter(() => 700)
    await routeLegAttempt(route, START, walked, from, to, { legBudgetMetres: 500, budgetDetourGate: true })
    expect(asked).toHaveLength(1)
  })

  it('still reroutes it when the gate is off, exactly as before', async () => {
    const { route, asked } = recordingRouter(() => 700)
    await routeLegAttempt(route, START, walked, from, to, { legBudgetMetres: 500, budgetDetourGate: false })
    expect(asked).toHaveLength(2)
  })

  it('says whether the reroute was worth keeping', async () => {
    const outcomes: Array<[string, boolean]> = []
    const { route } = recordingRouter((_, attempt) => (attempt === 0 ? 2000 : 1200))
    await routeLegAttempt(route, START, walked, from, to, {
      legBudgetMetres: 1000,
      budgetDetourGate: true,
      onFixup: (kind, kept) => outcomes.push([kind, kept]),
    })
    expect(outcomes).toEqual([['leg-budget', true]])
  })

  it('says so when it was not', async () => {
    const outcomes: Array<[string, boolean]> = []
    const { route } = recordingRouter((_, attempt) => (attempt === 0 ? 2000 : 2400))
    await routeLegAttempt(route, START, walked, from, to, {
      legBudgetMetres: 1000,
      budgetDetourGate: true,
      onFixup: (kind, kept) => outcomes.push([kind, kept]),
    })
    expect(outcomes).toEqual([['leg-budget', false]])
  })
})
