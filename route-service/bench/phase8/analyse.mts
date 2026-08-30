/**
 * Phase 8 offline analysis: pairwise topological anchor compatibility.
 *
 * Nothing here is a production path. Sequences are chosen from cheap field,
 * tree and probe information; every candidate leg is still routed by
 * GraphHopper through the same Phase 3B leg/budget/pullback machinery the
 * production generator uses, so the repair and call columns are comparable.
 */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { GraphHopperClient, parseLeg, type GraphHopperLeg } from '../../src/graphhopper.js'
import { analyseRouteQuality } from '../../src/loops/quality.js'
import { applyJoinPullback, joinAndTrimLegs, routeLegAttempt, type RoutedLeg } from '../../src/loops/routing.js'
import { haversine, type LngLat } from '../../src/loops/geo.js'
import { measureTraversals } from '../../src/loops/edges.js'
import { initialBearing, mutualSharedFraction, selectDiverseRoutes } from '../../src/loops/diversity.js'
import type { RoutePurpose } from '../../src/loops/metrics.js'
import { compactness } from '../../src/loops/geo.js'
import { MAX_LEG_SHARE, MIN_COMPACTNESS, MIN_LEG_SHARE } from '../../src/loops/quality.js'
import { anchorPool, angleGap, loadFields, mean, median, pairFeatures, percentile, signedTurn, type Field, type Node } from './field.mjs'
import { buildCompatibility, searchSequences, type Compatibility, type Sequence } from './sequence.mjs'

const gh = new GraphHopperClient(process.env.GH_URL ?? 'http://localhost:8991', 'foot', 20000)
const fields = loadFields(new URL('network-fields.json', import.meta.url))
const PROBE_FILE = process.env.PROBE_FILE ?? 'results/probes-32.json'
const probeFile = JSON.parse(readFileSync(new URL(PROBE_FILE, import.meta.url), 'utf8')) as {
  calls: number; wallMs: number
  anchors: Array<{ fixture: string; node: number; fieldMetres: number; priorFieldMetres: number | null; crow: number; routed: number }>
  pairs: Array<{ fixture: string; a: number; b: number; crow: number; tree: number; sharedFraction: number; sharedMetres: number; sharedEdges: number; turn: number; routed: number; reverse: number }>
}
const POOL_SIZES = (process.env.POOL_SIZES ?? '8,12,16,20,24,32').split(',').map(Number)
const CHOSEN_POOL = Number(process.env.POOL ?? 32)
const FANOUT = Number(process.env.FANOUT ?? 6)
const PROBE_BUDGET = Number(process.env.PROBE_BUDGET ?? 16)
const PER_FAMILY = Number(process.env.PER_FAMILY ?? 2)
/**
 * With the anchors fixed, a candidate has no way to correct scale once it is
 * under way — the flaw Phase 7 hit from the other side. ADAPTIVE keeps the
 * first two anchors and re-picks the closing anchor from the same pool once
 * the first two legs have actually been routed, using the distance those legs
 * really cost. It spends no extra GraphHopper call.
 */
const ADAPTIVE = (process.env.ADAPTIVE ?? 'true') !== 'false'
/**
 * How the observed inflation is carried forward. `flat` applies what the first
 * legs cost to the remaining ones; `compounded` treats it as a per-avoided-leg
 * factor, because leg k avoids k previously walked corridors and the measured
 * inflation grows with that count rather than staying level.
 */
const INFLATION = process.env.INFLATION ?? 'flat'

const probedFor = (fixture: string) => {
  const map = new Map<string, number>()
  for (const pair of probeFile.pairs.filter(row => row.fixture === fixture)) {
    map.set(`${pair.a}:${pair.b}`, pair.routed)
    map.set(`${pair.b}:${pair.a}`, pair.reverse)
  }
  return map
}

// ------------------------------------------------------------------ routing

type Result = {
  fixture: string; family: string; rank: number; pass: boolean; outcome: string
  distance: number; predicted: number; error: number; calls: number
  routeWallMs: number; engineRouteMs: number; purposes: Record<string, number>
  guideMisses: number[]; trimRetention: number; quality: any; rejections: string[]
  coordinates: LngLat[]; traversals: ReturnType<typeof measureTraversals>
  bearing: number; legDistances: number[]; predictedLegs: number[]; probedEdges: number
  reselected: boolean; anchors: number[]
}

/**
 * Re-pick the closing anchor once the first two legs are routed.
 *
 * Two measured facts drive this. Legs the router actually returns run about a
 * tenth longer than a plain point-to-point estimate, because each leg avoids
 * the ground already walked; and that inflation varies by request rather than
 * being a constant. Both are observable from the legs already in hand, so the
 * remaining budget is compared against inflated estimates rather than raw ones.
 */
function chooseClosingAnchor(field: Field, graph: Compatibility, sequence: Sequence, legs: RoutedLeg[]): Node | undefined {
  const [a, b] = sequence.anchors
  const actual = legs.reduce((sum, leg) => sum + leg.distanceMeters, 0)
  const planned = sequence.legs.slice(0, legs.length).reduce((sum, value) => sum + value, 0)
  const observed = planned > 0 ? Math.min(1.6, Math.max(0.7, actual / planned)) : 1
  // Leg 0 avoids nothing and matches the field almost exactly, so the whole of
  // `observed` is attributable to the one corridor leg 1 had to avoid.
  const perArea = INFLATION === 'compounded' ? observed : 1
  const inflateSecond = INFLATION === 'compounded' ? observed * perArea : observed
  const inflateClosing = INFLATION === 'compounded' ? observed * perArea * perArea : observed
  const remaining = field.targetMetres - actual
  if (remaining <= 0) return undefined
  let best: Node | undefined, bestScore = Infinity
  for (const candidate of graph.pool) {
    if (candidate.node === a.node || candidate.node === b.node) continue
    const edge = graph.edges.get(`${b.node}:${candidate.node}`)
    if (!edge) continue
    if (signedTurn(field.bearing(b), field.bearing(candidate)) * sequence.direction <= 0) continue
    if (signedTurn(field.bearing(candidate), field.bearing(a)) * sequence.direction <= 0) continue
    if (haversine(field.point(a), field.point(candidate)) < field.targetMetres * 0.08) continue
    const shape = compactness([field.start, field.point(a), field.point(b), field.point(candidate), field.start])
    if (shape < MIN_COMPACTNESS) continue
    const predictedRest = edge.cost * inflateSecond + candidate.networkMetres * inflateClosing
    const total = actual + predictedRest
    const shares = [...legs.map(leg => leg.distanceMeters), edge.cost * inflateSecond, candidate.networkMetres * inflateClosing]
      .map(value => value / Math.max(1, total))
    if (Math.max(...shares) > MAX_LEG_SHARE || Math.min(...shares.slice(1, -1)) < MIN_LEG_SHARE) continue
    const score = Math.abs(predictedRest - remaining) / field.targetMetres
      + pairFeatures(field, b, candidate).sharedFraction * 0.05
    if (score < bestScore) { bestScore = score; best = candidate }
  }
  return best
}

async function build(field: Field, sequence: Sequence, graph: Compatibility): Promise<Result | undefined> {
  const start = field.start
  let calls = 0, routeWallMs = 0, engineRouteMs = 0
  const purposes: Record<string, number> = {}
  const route = async (points: LngLat[], customModel: any, purpose: RoutePurpose = 'leg'): Promise<GraphHopperLeg> => {
    calls++; purposes[purpose] = (purposes[purpose] ?? 0) + 1
    const began = performance.now(), response = await gh.route(points, { customModel })
    routeWallMs += performance.now() - began
    engineRouteMs += response.timing.routeMs
    return parseLeg(response.payload)
  }
  const chosenAnchors = [...sequence.anchors]
  let reselected = false
  const legs: RoutedLeg[] = [], walked: LngLat[][] = [], points = [start], guideMisses: number[] = []
  for (let index = 0; index < 4; index++) {
    if (ADAPTIVE && index === 2) {
      const replacement = chooseClosingAnchor(field, graph, sequence, legs)
      if (replacement && replacement.node !== chosenAnchors[2].node) { chosenAnchors[2] = replacement; reselected = true }
      else if (replacement) chosenAnchors[2] = replacement
    }
    const target = index < 3 ? field.point(chosenAnchors[index]) : start
    const from = points.at(-1)!
    const outcome = await routeLegAttempt(route, start, walked, from, target, {
      legBudgetMetres: field.targetMetres * .5, budgetDetourGate: true, pullbackTurnOnly: true,
      pullbackReusesPrevious: true, backtrackNeedsBudgetToo: true, budgetOncePerLeg: true,
    }).catch(() => undefined)
    if (!outcome) return undefined
    let leg = outcome.leg, relaxed = outcome.relaxed
    if (legs.length) {
      const previous = legs.at(-1)!
      const pulled = await applyJoinPullback(route, start, walked.slice(0, -1), points.at(-2)!, previous, from, target, leg, relaxed, {
        pullbackTurnOnly: true, pullbackReusesPrevious: true, backtrackNeedsBudgetToo: true, budgetOncePerLeg: true,
      }).catch(() => ({ leg, relaxed, revisedPrevious: undefined }))
      leg = pulled.leg; relaxed = pulled.relaxed
      if (pulled.revisedPrevious) {
        legs[legs.length - 1] = pulled.revisedPrevious.leg
        walked[walked.length - 1] = pulled.revisedPrevious.leg.coordinates
        points[points.length - 1] = pulled.revisedPrevious.point
      }
    }
    guideMisses.push(haversine(leg.coordinates.at(-1) ?? target, target))
    legs.push({ ...leg, relaxed, avoidanceAreaCount: walked.length }); walked.push(leg.coordinates); points.push(target)
  }
  const before = legs.reduce((sum, leg) => sum + leg.distanceMeters, 0)
  const candidate = joinAndTrimLegs(legs)
  const traversals = measureTraversals(candidate.coordinates, candidate.edges)
  const report = analyseRouteQuality({
    coordinates: candidate.coordinates, traversals, start, distanceMeters: candidate.distanceMeters,
    durationSeconds: candidate.durationSeconds, targetMetres: field.targetMetres,
    legDistances: legs.map(leg => leg.distanceMeters), maneuverSigns: candidate.steps.map(step => step.sign),
  })
  const outcome = report.pass ? 'PASS' : report.rejections.includes('distance')
    ? candidate.distanceMeters < field.targetMetres ? 'TOO_SHORT' : 'TOO_LONG' : 'OTHER_QUALITY_FAILURE'
  return {
    fixture: field.name, family: sequence.family, rank: sequence.rank, pass: report.pass, outcome,
    distance: candidate.distanceMeters, predicted: sequence.predicted, error: candidate.distanceMeters - field.targetMetres,
    calls, routeWallMs, engineRouteMs, purposes, guideMisses, trimRetention: candidate.distanceMeters / before,
    quality: report.quality, rejections: report.rejections, coordinates: candidate.coordinates, traversals,
    bearing: initialBearing(candidate.coordinates, start), legDistances: legs.map(leg => leg.distanceMeters),
    predictedLegs: sequence.legs, probedEdges: sequence.probedEdges, reselected,
    anchors: chosenAnchors.map(node => node.node),
  }
}

// ------------------------------------------------------------------ run

const lines: string[] = [], say = (line = '') => { lines.push(line); console.log(line) }
const pools = new Map<string, Node[]>()
const compat = new Map<string, ReturnType<typeof buildCompatibility>>()
const selectionCosts: Array<{ fixture: string; poolMs: number; compatMs: number; searchMs: number; sequences: number }> = []
const sequences = new Map<string, Sequence[]>()
const poolSizeStudy: any[] = []
const results: Result[] = []
const routingCosts: Array<{ fixture: string; ms: number }> = []

for (const field of fields) {
  // P16: nested pools, so one probe capture serves every size.
  const full = anchorPool(field, { size: Math.max(...POOL_SIZES, CHOSEN_POOL) })
  for (const size of POOL_SIZES) {
    const pool = full.slice(0, size)
    if (pool.length < 3) continue
    const graph = buildCompatibility(field, pool, probedFor(field.name), { fanout: FANOUT, probeBudget: PROBE_BUDGET })
    const found = searchSequences(field, graph, { perFamily: PER_FAMILY })
    const errors = found.map(row => Math.abs(row.predicted - field.targetMetres))
    poolSizeStudy.push({
      fixture: field.name, size, anchors: pool.length, edges: graph.out.size ? [...graph.out.values()].flat().length : 0,
      probes: graph.probes.length, stretch: graph.stretch, families: new Set(found.map(row => row.family)).size,
      sequences: found.length, medianPredictedError: median(errors), bestPredictedError: Math.min(...errors, Infinity),
      inBand: found.filter(row => Math.abs(row.predicted - field.targetMetres) <= field.targetMetres * 0.12).length,
    })
  }
  const poolAt = performance.now()
  const pool = full.slice(0, CHOSEN_POOL)
  const poolMs = performance.now() - poolAt
  const compatAt = performance.now()
  const graph = buildCompatibility(field, pool, probedFor(field.name), { fanout: FANOUT, probeBudget: PROBE_BUDGET })
  const compatMs = performance.now() - compatAt
  const searchAt = performance.now()
  const found = searchSequences(field, graph, { perFamily: PER_FAMILY })
  selectionCosts.push({ fixture: field.name, poolMs, compatMs, searchMs: performance.now() - searchAt, sequences: found.length })
  pools.set(field.name, pool); compat.set(field.name, graph); sequences.set(field.name, found)

  const routedAt = performance.now()
  for (let offset = 0; offset < found.length; offset += 4) {
    const batch = await Promise.all(found.slice(offset, offset + 4).map(sequence => build(field, sequence, graph)))
    results.push(...batch.filter((row): row is Result => Boolean(row)))
  }
  routingCosts.push({ fixture: field.name, ms: performance.now() - routedAt })
  console.log(`${field.name}: ${found.length} sequences routed`)
}

// ------------------------------------------------------------------ tables

const P3B = {
  perFixture: {
    'douglas-5km': { completed: 24, passes: 5, calls: 238, rejected: 205, short: 5, long: 6, other: 8, offered: 3 },
    'douglas-3km': { completed: 12, passes: 4, calls: 96, rejected: 72, short: 4, long: 2, other: 2, offered: 3 },
    'peel-5km': { completed: 59, passes: 5, calls: 530, rejected: 492, short: 31, long: 6, other: 17, offered: 3 },
    'onchan-5km': { completed: 13, passes: 5, calls: 114, rejected: 80, short: 3, long: 3, other: 2, offered: 3 },
  } as Record<string, { completed: number; passes: number; calls: number; rejected: number; short: number; long: number; other: number; offered: number }>,
  total: { completed: 108, passes: 19, calls: 978, rejected: 849, short: 43, long: 17, other: 29, offered: 12 },
  fixups: { retries: 213, budget: 110, pullback: 205, spike: 45, relaxed: 2 },
}

say('# Phase 8 pairwise anchor compatibility — offline analysis')
say('')
say(`Pool ${CHOSEN_POOL}, fanout ${FANOUT}, probe budget ${PROBE_BUDGET}, ${PER_FAMILY} sequence per directional family.`)

say('\n## P1 — field seeding\n')
say('| fixture | nodes | edges | warm ms | median &#124;field − routed&#124; (P8 virtual-node seed) | same anchors, P7 tower-node seed | median routed/field |')
say('|---|---:|---:|---:|---:|---:|---:|')
for (const field of fields) {
  const rows = probeFile.anchors.filter(row => row.fixture === field.name)
  say(`| ${field.name} | ${field.nodesVisited} | ${field.edgesVisited} | ${field.wallMs.toFixed(2)} | ${median(rows.map(row => Math.abs(row.fieldMetres - row.routed))).toFixed(1)} m | ${median(rows.filter(row => row.priorFieldMetres !== null).map(row => Math.abs(row.priorFieldMetres! - row.routed))).toFixed(1)} m | ${median(rows.map(row => row.routed / Math.max(1, row.fieldMetres))).toFixed(3)} |`)
}

say('\n## P2 — anchor pool\n')
say('| fixture | pool | 15° sectors | largest angular gap | network distance p10/median/p90 | median degree | median crow separation |')
say('|---|---:|---:|---:|---:|---:|---:|')
for (const field of fields) {
  const pool = pools.get(field.name)!
  const sectors = new Set(pool.map(node => Math.floor(field.bearing(node) / 15)))
  const sorted = [...sectors].sort((a, b) => a - b)
  const gaps = sorted.map((value, index) => ((sorted[(index + 1) % sorted.length] + (index === sorted.length - 1 ? 24 : 0)) - value) * 15)
  const separations: number[] = []
  for (let a = 0; a < pool.length; a++) for (let b = a + 1; b < pool.length; b++) separations.push(haversine(field.point(pool[a]), field.point(pool[b])))
  say(`| ${field.name} | ${pool.length} | ${sectors.size}/24 | ${Math.max(...gaps, 0)}° | ${percentile(pool.map(n => n.networkMetres), .1).toFixed(0)} / ${median(pool.map(n => n.networkMetres)).toFixed(0)} / ${percentile(pool.map(n => n.networkMetres), .9).toFixed(0)} m | ${median(pool.map(n => n.degree)).toFixed(0)} | ${median(separations).toFixed(0)} m |`)
}

say('\n## P16 — pool size\n')
say('| fixture | pool | sparse edges | sequences | families | median predicted error | best predicted error | within ±12% band |')
say('|---|---:|---:|---:|---:|---:|---:|---:|')
for (const row of poolSizeStudy)
  say(`| ${row.fixture} | ${row.size} | ${row.edges} | ${row.sequences} | ${row.families} | ${row.medianPredictedError.toFixed(0)} m | ${Number.isFinite(row.bestPredictedError) ? row.bestPredictedError.toFixed(0) : '—'} m | ${row.inBand} |`)

say('\n## P3/P4 — start-tree ancestry against actual pair routes\n')
say('| shared fraction | pairs | median routed/crow | median routed/tree | median crow | median shared corridor edges |')
say('|---|---:|---:|---:|---:|---:|')
for (const [lo, hi] of [[0, .1], [.1, .25], [.25, .4], [.4, .6], [.6, 1.01]]) {
  const group = probeFile.pairs.filter(pair => pair.sharedFraction >= lo && pair.sharedFraction < hi)
  if (!group.length) continue
  say(`| [${lo}, ${hi}) | ${group.length} | ${median(group.map(p => p.routed / Math.max(1, p.crow))).toFixed(3)} | ${median(group.map(p => p.routed / Math.max(1, p.tree))).toFixed(3)} | ${median(group.map(p => p.crow)).toFixed(0)} m | ${median(group.map(p => p.sharedEdges)).toFixed(0)} |`)
}
say('')
say('| bearing separation | pairs | median routed/crow | median shared fraction |')
say('|---|---:|---:|---:|')
for (const [lo, hi] of [[0, 30], [30, 60], [60, 90], [90, 120], [120, 180.1]]) {
  const group = probeFile.pairs.filter(pair => Math.abs(pair.turn) >= lo && Math.abs(pair.turn) < hi)
  if (!group.length) continue
  say(`| [${lo}°, ${hi}°) | ${group.length} | ${median(group.map(p => p.routed / Math.max(1, p.crow))).toFixed(3)} | ${median(group.map(p => p.sharedFraction)).toFixed(3)} |`)
}
say('')
say(`Route symmetry: median |A→B − B→A| = ${median(probeFile.pairs.map(p => Math.abs(p.routed - p.reverse))).toFixed(1)} m.`)

say('\n## P5 — pairwise distance estimators\n')
say('| fixture | estimator | median abs error | p75 | p90 | median signed bias | median estimate/actual | Spearman rank ρ |')
say('|---|---|---:|---:|---:|---:|---:|---:|')
const spearman = (xs: number[], ys: number[]) => {
  const rank = (values: number[]) => {
    const order = values.map((value, index) => ({ value, index })).sort((a, b) => a.value - b.value)
    const out = new Array(values.length).fill(0)
    order.forEach((entry, position) => { out[entry.index] = position })
    return out
  }
  const rx = rank(xs), ry = rank(ys), n = xs.length
  const d2 = rx.reduce((sum, value, index) => sum + (value - ry[index]) ** 2, 0)
  return 1 - (6 * d2) / (n * (n * n - 1))
}
for (const field of fields) {
  const rows = probeFile.pairs.filter(pair => pair.fixture === field.name)
  const graph = compat.get(field.name)!
  const fieldStretchValue = median(pools.get(field.name)!.map(node => node.networkMetres / Math.max(1, field.crow(node))))
  const estimators: Array<[string, (p: typeof rows[number]) => number]> = [
    ['E0 crow', p => p.crow],
    ['E1 tree', p => p.tree],
    ['E2 bracket midpoint', p => (p.crow + Math.max(p.crow, p.tree)) / 2],
    ['E2g bracket geometric mean', p => Math.sqrt(p.crow * Math.max(p.crow, p.tree))],
    ['E3 crow × field stretch', p => p.crow * fieldStretchValue],
    [`E6 crow × probed stretch (${graph.probes.length} probes)`, p => p.crow * graph.stretch],
  ]
  for (const [name, estimator] of estimators) {
    const errors = rows.map(row => estimator(row) - row.routed)
    const absolute = errors.map(Math.abs)
    say(`| ${field.name} | ${name} | ${median(absolute).toFixed(1)} | ${percentile(absolute, .75).toFixed(1)} | ${percentile(absolute, .9).toFixed(1)} | ${median(errors).toFixed(1)} | ${median(rows.map(row => estimator(row) / Math.max(1, row.routed))).toFixed(3)} | ${spearman(rows.map(estimator), rows.map(row => row.routed)).toFixed(3)} |`)
  }
}

say('\n## P6/P15 — probe economics\n')
say('| fixture | pool | pool pairs | probes used | probed stretch | field stretch | oracle capture calls |')
say('|---|---:|---:|---:|---:|---:|---:|')
for (const field of fields) {
  const graph = compat.get(field.name)!
  const pool = pools.get(field.name)!
  say(`| ${field.name} | ${pool.length} | ${pool.length * (pool.length - 1) / 2} | ${graph.probes.length} | ${graph.stretch.toFixed(3)} | ${median(pool.map(node => node.networkMetres / Math.max(1, field.crow(node)))).toFixed(3)} | ${probeFile.pairs.filter(row => row.fixture === field.name).length * 2 + probeFile.anchors.filter(row => row.fixture === field.name).length} |`)
}

say('\n## P10 — predicted vs actual candidate distance\n')
say('| fixture | routed | median predicted | median actual | median abs error | p75 | p90 | signed bias | median actual/predicted | in ±12% predicted / in band actual |')
say('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
for (const field of fields) {
  const rows = results.filter(row => row.fixture === field.name)
  if (!rows.length) continue
  const errors = rows.map(row => row.predicted - row.distance)
  const absolute = errors.map(Math.abs)
  say(`| ${field.name} | ${rows.length} | ${median(rows.map(r => r.predicted)).toFixed(0)} | ${median(rows.map(r => r.distance)).toFixed(0)} | ${median(absolute).toFixed(0)} | ${percentile(absolute, .75).toFixed(0)} | ${percentile(absolute, .9).toFixed(0)} | ${median(errors).toFixed(0)} | ${median(rows.map(r => r.distance / Math.max(1, r.predicted))).toFixed(3)} | ${rows.filter(r => Math.abs(r.predicted - field.targetMetres) <= field.targetMetres * .12).length} / ${rows.filter(r => Math.abs(r.error) <= field.targetMetres * .12).length} |`)
}

say('\n## P11/P17 — candidate outcomes against Phase 3B\n')
say('| fixture | generator | built | pass | pass rate | short | long | other | median abs error | calls | calls/pass | calls on rejected |')
say('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
const totals = { built: 0, pass: 0, short: 0, long: 0, other: 0, calls: 0, rejected: 0 }
for (const field of fields) {
  const rows = results.filter(row => row.fixture === field.name)
  const base = P3B.perFixture[field.name]
  const calls = rows.reduce((sum, row) => sum + row.calls, 0)
  const passes = rows.filter(row => row.pass).length
  const rejected = rows.filter(row => !row.pass).reduce((sum, row) => sum + row.calls, 0)
  totals.built += rows.length; totals.pass += passes; totals.calls += calls; totals.rejected += rejected
  totals.short += rows.filter(row => row.outcome === 'TOO_SHORT').length
  totals.long += rows.filter(row => row.outcome === 'TOO_LONG').length
  totals.other += rows.filter(row => row.outcome === 'OTHER_QUALITY_FAILURE').length
  say(`| ${field.name} | Phase 3B | ${base.completed} | ${base.passes} | ${(100 * base.passes / base.completed).toFixed(1)}% | ${base.short} | ${base.long} | ${base.other} | — | ${base.calls} | ${(base.calls / Math.max(1, base.passes)).toFixed(1)} | ${base.rejected} |`)
  say(`| ${field.name} | Phase 8 | ${rows.length} | ${passes} | ${(100 * passes / Math.max(1, rows.length)).toFixed(1)}% | ${rows.filter(r => r.outcome === 'TOO_SHORT').length} | ${rows.filter(r => r.outcome === 'TOO_LONG').length} | ${rows.filter(r => r.outcome === 'OTHER_QUALITY_FAILURE').length} | ${median(rows.map(r => Math.abs(r.error))).toFixed(0)} m | ${calls} | ${(calls / Math.max(1, passes)).toFixed(1)} | ${rejected} |`)
}
say(`| **total** | Phase 3B | ${P3B.total.completed} | ${P3B.total.passes} | ${(100 * P3B.total.passes / P3B.total.completed).toFixed(1)}% | ${P3B.total.short} | ${P3B.total.long} | ${P3B.total.other} | — | ${P3B.total.calls} | ${(P3B.total.calls / P3B.total.passes).toFixed(1)} | ${P3B.total.rejected} |`)
say(`| **total** | Phase 8 | ${totals.built} | ${totals.pass} | ${(100 * totals.pass / Math.max(1, totals.built)).toFixed(1)}% | ${totals.short} | ${totals.long} | ${totals.other} | ${median(results.map(r => Math.abs(r.error))).toFixed(0)} m | ${totals.calls} | ${(totals.calls / Math.max(1, totals.pass)).toFixed(1)} | ${totals.rejected} |`)

say('\n## P12 — repair work\n')
say('| generator | candidates | calls/candidate | geometric retries | leg-budget | join-pullback | spike | relaxed | pullback/candidate |')
say('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
const purpose = (name: string) => results.reduce((sum, row) => sum + (row.purposes[name] ?? 0), 0)
say(`| Phase 3B normal | ${P3B.total.completed} | ${(P3B.total.calls / P3B.total.completed).toFixed(2)} | ${P3B.fixups.retries} | ${P3B.fixups.budget} | ${P3B.fixups.pullback} | ${P3B.fixups.spike} | ${P3B.fixups.relaxed} | ${(P3B.fixups.pullback / P3B.total.completed).toFixed(2)} |`)
say(`| Phase 8 | ${results.length} | ${(totals.calls / Math.max(1, results.length)).toFixed(2)} | 0 | ${purpose('leg-budget')} | ${purpose('join-pullback')} | ${purpose('spike')} | ${purpose('leg-relaxed')} | ${(purpose('join-pullback') / Math.max(1, results.length)).toFixed(2)} |`)
say('')
say(`Median endpoint (guide) miss: ${median(results.flatMap(row => row.guideMisses)).toFixed(1)} m. Median trim retention: ${median(results.map(row => row.trimRetention)).toFixed(3)}.`)

say('\n## P13/P17 — offered routes, quality and diversity\n')
say('| fixture | Phase 3B offered | Phase 8 offered | mean abs error | mean quality | mean repeated | u-turns | worst geometric overlap | worst physical overlap |')
say('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
let offeredTotal = 0
const offeredAll: Result[] = []
for (const field of fields) {
  const passing = results.filter(row => row.fixture === field.name && row.pass)
  const offered = selectDiverseRoutes(passing.map(row => ({ ...row, totalMetres: row.distance }))) as unknown as Result[]
  offeredTotal += offered.length
  offeredAll.push(...offered)
  const pairs: Array<[Result, Result]> = []
  for (let a = 0; a < offered.length; a++) for (let b = a + 1; b < offered.length; b++) pairs.push([offered[a], offered[b]])
  const geometric = pairs.map(([a, b]) => mutualSharedFraction({ ...a, traversals: undefined, totalMetres: a.distance }, { ...b, traversals: undefined, totalMetres: b.distance }))
  const physical = pairs.map(([a, b]) => mutualSharedFraction({ ...a, totalMetres: a.distance }, { ...b, totalMetres: b.distance }))
  say(`| ${field.name} | ${P3B.perFixture[field.name].offered} | ${offered.length} | ${mean(offered.map(r => Math.abs(r.error))).toFixed(0)} m | ${mean(offered.map(r => r.quality.score)).toFixed(1)} | ${mean(offered.map(r => r.quality.repeatedPercent)).toFixed(2)}% | ${offered.reduce((s, r) => s + r.quality.uTurnCount, 0)} | ${(100 * Math.max(0, ...geometric)).toFixed(1)}% | ${(100 * Math.max(0, ...physical)).toFixed(1)}% |`)
}
say(`| **total** | ${P3B.total.offered} | ${offeredTotal} | ${mean(offeredAll.map(r => Math.abs(r.error))).toFixed(0)} m | ${mean(offeredAll.map(r => r.quality.score)).toFixed(1)} | ${mean(offeredAll.map(r => r.quality.repeatedPercent)).toFixed(2)}% | ${offeredAll.reduce((s, r) => s + r.quality.uTurnCount, 0)} | — | — |`)

say('\n## P14 — Peel topology\n')
const peel = fields.find(field => field.name === 'peel-5km')
if (peel) {
  const pool = pools.get(peel.name)!, graph = compat.get(peel.name)!, found = sequences.get(peel.name)!
  const admissible = [...graph.out.values()].flat()
  say(`Pool ${pool.length} of a requested ${CHOSEN_POOL}. Sparse edges ${admissible.length}; sequences ${found.length} across ${new Set(found.map(row => row.family)).size} of a possible 24 directional families, against 22–24 on the Douglas and Onchan fixtures.`)
  say(`Median pair shared-tree fraction ${median(probeFile.pairs.filter(p => p.fixture === peel.name).map(p => p.sharedFraction)).toFixed(3)}; median routed/crow ${median(probeFile.pairs.filter(p => p.fixture === peel.name).map(p => p.routed / Math.max(1, p.crow))).toFixed(3)}, the highest of the four fixtures.`)
  say('')
  say('| fixture | routed candidates | median planned polygon compactness | median realised compactness | shapeless | out-and-back-spur |')
  say('|---|---:|---:|---:|---:|---:|')
  for (const field of fields) {
    const all = results.filter(row => row.fixture === field.name)
    const plans = sequences.get(field.name)!
    say(`| ${field.name} | ${all.length} | ${median(plans.map(row => row.shape)).toFixed(3)} | ${median(all.map(row => row.quality.compactness ?? 0)).toFixed(3)} | ${all.filter(row => row.rejections.includes('shapeless')).length} | ${all.filter(row => row.rejections.includes('out-and-back-spur')).length} |`)
  }
}

say('\n## P9 — directional family diversity\n')
say('| fixture | families with a sequence | families routed | families with a pass | distinct anchor triples routed | closing anchor re-picked |')
say('|---|---:|---:|---:|---:|---:|')
for (const field of fields) {
  const rows = results.filter(row => row.fixture === field.name)
  const found = sequences.get(field.name)!
  say(`| ${field.name} | ${new Set(found.map(row => row.family)).size} | ${new Set(rows.map(row => row.family)).size} | ${new Set(rows.filter(row => row.pass).map(row => row.family)).size} | ${new Set(rows.map(row => row.anchors.join(','))).size} | ${rows.filter(row => row.reselected).length} |`)
}

say('\n## Preprocessing and total cost\n')
say('| fixture | field ms | pool ms | compatibility ms | search ms | probe calls | candidate calls | total calls | routing elapsed ms |')
say('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
for (const field of fields) {
  const cost = selectionCosts.find(row => row.fixture === field.name)!
  const rows = results.filter(row => row.fixture === field.name)
  const graph = compat.get(field.name)!
  const calls = rows.reduce((sum, row) => sum + row.calls, 0)
  say(`| ${field.name} | ${field.wallMs.toFixed(2)} | ${cost.poolMs.toFixed(1)} | ${cost.compatMs.toFixed(1)} | ${cost.searchMs.toFixed(1)} | ${graph.probes.length} | ${calls} | ${calls + graph.probes.length} | ${routingCosts.find(row => row.fixture === field.name)!.ms.toFixed(0)} |`)
}
const probeTotal = fields.reduce((sum, field) => sum + compat.get(field.name)!.probes.length, 0)
say('')
say(`Phase 8 total including probes: ${totals.calls + probeTotal} calls versus Phase 3B ${P3B.total.calls}. Calls on rejected candidates ${totals.rejected} versus ${P3B.total.rejected}.`)

mkdirSync(new URL('results/', import.meta.url), { recursive: true })
const suffix = process.env.LABEL ? `-${process.env.LABEL}` : ''
writeFileSync(new URL(`results/offline${suffix}.md`, import.meta.url), lines.join('\n') + '\n')
writeFileSync(new URL(`results/offline${suffix}.json`, import.meta.url), JSON.stringify({
  pool: CHOSEN_POOL, fanout: FANOUT, probeBudget: PROBE_BUDGET, perFamily: PER_FAMILY,
  poolSizeStudy, selectionCosts, routingCosts,
  compatibility: [...compat].map(([fixture, graph]) => ({ fixture, stretch: graph.stretch, probes: graph.probes, edges: [...graph.out.values()].flat().length })),
  sequences: [...sequences].flatMap(([fixture, list]) => list.map(row => ({ fixture, family: row.family, rank: row.rank, anchors: row.anchors.map(node => node.node), predicted: row.predicted, legs: row.legs, penalty: row.penalty, probedEdges: row.probedEdges }))),
  results: results.map(({ coordinates, traversals, ...row }) => ({ ...row, pointCount: coordinates.length, edgeCount: traversals?.length ?? 0 })),
}, null, 2) + '\n')
void angleGap
