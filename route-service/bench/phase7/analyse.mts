/** Phase 7 analysis-only graph-anchor family experiment. */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { GraphHopperClient, parseLeg, type GraphHopperLeg } from '../../src/graphhopper.js'
import { analyseRouteQuality } from '../../src/loops/quality.js'
import { applyJoinPullback, joinAndTrimLegs, routeLegAttempt, type RoutedLeg } from '../../src/loops/routing.js'
import { bearingBetween, haversine, normaliseBearing, type LngLat } from '../../src/loops/geo.js'
import { measureTraversals } from '../../src/loops/edges.js'
import { initialBearing, mutualSharedFraction, selectDiverseRoutes } from '../../src/loops/diversity.js'
import type { RoutePurpose } from '../../src/loops/metrics.js'

type Node = { node: number; lat: number; lon: number; networkMetres: number; degree: number }
type Field = { name: string; targetMetres: number; limitMetres: number; nodesVisited: number; edgesVisited: number; wallMs: number; heapDeltaBytes: number; nodes: Node[] }
const fields = (JSON.parse(readFileSync(new URL('network-fields.json', import.meta.url), 'utf8')) as Array<Omit<Field, 'nodes'> & { nodes: Array<Node & { network_metres?: number }> }>).map(field => ({
  ...field, nodes: field.nodes.map(node => ({ ...node, networkMetres: node.networkMetres ?? node.network_metres ?? 0 })),
}))
const gh = new GraphHopperClient(process.env.GH_URL ?? 'http://localhost:8991', 'foot', 8000)
const starts = new Map<string, LngLat>([
  ['douglas-5km', [-4.4816, 54.1506]], ['douglas-3km', [-4.4816, 54.1506]],
  ['peel-5km', [-4.6947, 54.2247]], ['onchan-5km', [-4.4530, 54.1745]],
])
const angle = (a: number, b: number) => Math.abs(((a - b + 540) % 360) - 180)
const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)] ?? 0

type Plan = { family: string; id: string; anchors: LngLat[]; nodes: Node[]; bearing: number; direction: 1 | -1 }
function plans(field: Field, family: 'A' | 'B'): Plan[] {
  const start = starts.get(field.name)!
  const fractions = family === 'A' ? [.25, .25, .25] : [.20, .32, .20]
  const result: Plan[] = []
  for (let pair = 0; pair < 12; pair++) for (const direction of [1, -1] as const) {
    const bearing = pair * 30
    const chosen: Node[] = []
    for (let stage = 0; stage < 3; stage++) {
      const wantedBearing = normaliseBearing(bearing + direction * stage * 90)
      const wantedDistance = field.targetMetres * fractions[stage]
      const ranked = field.nodes.filter(node => node.degree >= 2 && node.networkMetres > field.targetMetres * .12)
        .filter(node => chosen.every(prior => haversine([node.lon, node.lat], [prior.lon, prior.lat]) >= field.targetMetres * .08))
        .sort((a, b) => score(a, wantedBearing, wantedDistance, start) - score(b, wantedBearing, wantedDistance, start))
      if (!ranked.length) break
      chosen.push(ranked[0])
    }
    if (chosen.length === 3) result.push({ family, id: `${pair}-${direction > 0 ? 'cw' : 'ccw'}`, anchors: chosen.map(n => [n.lon, n.lat]), nodes: chosen, bearing, direction })
  }
  return result
}
const score = (node: Node, wantedBearing: number, wantedDistance: number, start: LngLat) =>
  Math.abs(node.networkMetres - wantedDistance) / Math.max(1, wantedDistance * .08)
  + angle(bearingBetween(start, [node.lon, node.lat]), wantedBearing) / 15
  - Math.min(4, node.degree) * .15

type Result = { fixture: string; family: string; id: string; pass: boolean; outcome: string; distance: number; error: number; calls: number; routeWallMs: number; engineRouteMs: number; purposes: Record<string, number>; guideMisses: number[]; trimRetention: number; quality: any; rejections: string[]; coordinates: LngLat[]; traversals: ReturnType<typeof measureTraversals>; bearing: number; legDistances: number[]; anchorNetworkMetres: number[]; anchorCrowMetres: number[] }
async function build(field: Field, plan: Plan): Promise<Result | undefined> {
  const start = starts.get(field.name)!
  let calls = 0, routeWallMs = 0, engineRouteMs = 0
  const purposes: Record<string, number> = {}
  const route = async (points: LngLat[], customModel: any, purpose: RoutePurpose = 'leg'): Promise<GraphHopperLeg> => {
    calls++; purposes[purpose] = (purposes[purpose] ?? 0) + 1
    const began = performance.now(), response = await gh.route(points, { customModel })
    routeWallMs += performance.now() - began
    engineRouteMs += response.timing.routeMs
    return parseLeg(response.payload)
  }
  const legs: RoutedLeg[] = [], walked: LngLat[][] = [], points = [start], guideMisses: number[] = []
  for (let index = 0; index < 4; index++) {
    const target = index < 3 ? plan.anchors[index] : start
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
    const endpoint = leg.coordinates.at(-1) ?? target
    guideMisses.push(haversine(endpoint, target))
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
  return { fixture: field.name, family: plan.family, id: plan.id, pass: report.pass, outcome, distance: candidate.distanceMeters,
    error: candidate.distanceMeters - field.targetMetres, calls, routeWallMs, engineRouteMs, purposes, guideMisses, trimRetention: candidate.distanceMeters / before,
    quality: report.quality, rejections: report.rejections, coordinates: candidate.coordinates, traversals,
    bearing: initialBearing(candidate.coordinates, start), legDistances: legs.map(leg => leg.distanceMeters),
    anchorNetworkMetres: plan.nodes.map(node => node.networkMetres),
    anchorCrowMetres: plan.anchors.map(anchor => haversine(start, anchor)) }
}

const results: Result[] = []
const selectionCosts: Array<{ fixture: string; family: string; ms: number; plans: number }> = []
const routingCosts: Array<{ fixture: string; family: string; ms: number }> = []
const planSets = new Map<string, Plan[]>()
for (const field of fields) for (const family of ['A', 'B'] as const) {
  const selectedAt = performance.now()
  const queue = plans(field, family)
  planSets.set(`${field.name}:${family}`, queue)
  selectionCosts.push({ fixture: field.name, family, ms: performance.now() - selectedAt, plans: queue.length })
  const routedAt = performance.now()
  for (let offset = 0; offset < queue.length; offset += 4) {
    const batch = await Promise.all(queue.slice(offset, offset + 4).map(plan => build(field, plan)))
    results.push(...batch.filter((row): row is Result => Boolean(row)))
  }
  routingCosts.push({ fixture: field.name, family, ms: performance.now() - routedAt })
  console.log(`${field.name} family ${family}: ${results.filter(row => row.fixture === field.name && row.family === family).length} routed`)
}

const lines: string[] = [], say = (line = '') => { lines.push(line); console.log(line) }
say('# Phase 7 graph-anchor offline analysis')
say('\n## Bounded exploration cost\n')
say('| fixture | limit m | nodes | edges | median warm ms | heap delta |')
say('|---|---:|---:|---:|---:|---:|')
for (const f of fields) say(`| ${f.name} | ${f.limitMetres} | ${f.nodesVisited} | ${f.edgesVisited} | ${f.wallMs.toFixed(2)} | ${f.heapDeltaBytes} |`)
say('\n## Shell and angular availability\n')
say('| fixture | shell width | populated shells | 15° sectors represented | median degree | max angular gap |')
say('|---|---:|---:|---:|---:|---:|')
for (const f of fields) {
  const start = starts.get(f.name)!, width = f.targetMetres * .05
  const shells = new Set(f.nodes.map(n => Math.floor(n.networkMetres / width)))
  const sectors = new Set(f.nodes.filter(n => n.networkMetres >= f.targetMetres * .12).map(n => Math.floor(bearingBetween(start, [n.lon, n.lat]) / 15)))
  const sorted = [...sectors].sort((a, b) => a - b), gaps = sorted.map((v, i) => ((sorted[(i + 1) % sorted.length] + (i === sorted.length - 1 ? 24 : 0)) - v) * 15)
  say(`| ${f.name} | ${width.toFixed(0)} | ${shells.size} | ${sectors.size}/24 | ${median(f.nodes.map(n => n.degree)).toFixed(0)} | ${Math.max(...gaps)}° |`)
}
say('\n## Candidate results\n')
say('| fixture | family | built | pass | short | long | other | calls | calls/pass | median guide miss | median abs error | median trim retention |')
say('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
for (const f of fields) for (const family of ['A', 'B']) {
  const rows = results.filter(r => r.fixture === f.name && r.family === family), calls = rows.reduce((s, r) => s + r.calls, 0), passed = rows.filter(r => r.pass).length
  say(`| ${f.name} | ${family} | ${rows.length} | ${passed} | ${rows.filter(r => r.outcome === 'TOO_SHORT').length} | ${rows.filter(r => r.outcome === 'TOO_LONG').length} | ${rows.filter(r => r.outcome === 'OTHER_QUALITY_FAILURE').length} | ${calls} | ${(calls / Math.max(1, passed)).toFixed(1)} | ${median(rows.flatMap(r => r.guideMisses)).toFixed(1)} | ${median(rows.map(r => Math.abs(r.error))).toFixed(0)} | ${median(rows.map(r => r.trimRetention)).toFixed(3)} |`)
}
say('\n## Anchor probe predictability\n')
say('| fixture | family | anchors | median network/crow stretch | median first-leg network-distance error | median endpoint miss | median anchor-to-anchor routed/crow |')
say('|---|---|---:|---:|---:|---:|---:|')
for (const field of fields) for (const family of ['A', 'B']) {
  const rows = results.filter(row => row.fixture === field.name && row.family === family)
  const stretches = rows.flatMap(row => row.anchorNetworkMetres.map((metres, i) => metres / Math.max(1, row.anchorCrowMetres[i])))
  const firstError = rows.map(row => Math.abs(row.legDistances[0] - row.anchorNetworkMetres[0]))
  const between = rows.flatMap(row => row.legDistances.slice(1, 3).map((metres, i) => {
    const plan = planSets.get(`${field.name}:${family}`)!.find(value => value.id === row.id)!
    return metres / Math.max(1, haversine(plan.anchors[i], plan.anchors[i + 1]))
  }))
  say(`| ${field.name} | ${family} | ${rows.length * 3} | ${median(stretches).toFixed(2)} | ${median(firstError).toFixed(1)} m | ${median(rows.flatMap(row => row.guideMisses)).toFixed(1)} m | ${median(between).toFixed(2)} |`)
}
say('\n## Repair work\n')
say('| family | candidates | calls/candidate | relaxed | leg-budget | pullback | spike | calls on rejected |')
say('|---|---:|---:|---:|---:|---:|---:|---:|')
for (const family of ['A', 'B']) {
  const rows = results.filter(r => r.family === family), purpose = (name: string) => rows.reduce((s, r) => s + (r.purposes[name] ?? 0), 0)
  say(`| ${family} | ${rows.length} | ${(rows.reduce((s, r) => s + r.calls, 0) / rows.length).toFixed(2)} | ${purpose('leg-relaxed')} | ${purpose('leg-budget')} | ${purpose('join-pullback')} | ${purpose('spike')} | ${rows.filter(r => !r.pass).reduce((s, r) => s + r.calls, 0)} |`)
}
say('\n## Offered quality and diversity\n')
say('| family | offered | mean abs error | mean quality | mean repeated | u-turns | worst geometric overlap | worst physical overlap |')
say('|---|---:|---:|---:|---:|---:|---:|---:|')
for (const family of ['A', 'B']) {
  const offered = fields.flatMap(field => selectDiverseRoutes(results.filter(row => row.fixture === field.name && row.family === family && row.pass).map(row => ({ ...row, totalMetres: row.distance }))))
  const pairs: Array<[Result, Result]> = []
  for (const field of fields) {
    const selected = offered.filter(row => row.fixture === field.name)
    for (let a = 0; a < selected.length; a++) for (let b = a + 1; b < selected.length; b++) pairs.push([selected[a], selected[b]])
  }
  const geometric = pairs.map(([a, b]) => mutualSharedFraction({ ...a, traversals: undefined, totalMetres: a.distance }, { ...b, traversals: undefined, totalMetres: b.distance }))
  const physical = pairs.map(([a, b]) => mutualSharedFraction({ ...a, totalMetres: a.distance }, { ...b, totalMetres: b.distance }))
  say(`| ${family} | ${offered.length} | ${(offered.reduce((s, r) => s + Math.abs(r.error), 0) / Math.max(1, offered.length)).toFixed(0)} m | ${(offered.reduce((s, r) => s + r.quality.score, 0) / Math.max(1, offered.length)).toFixed(1)} | ${(offered.reduce((s, r) => s + r.quality.repeatedPercent, 0) / Math.max(1, offered.length)).toFixed(2)}% | ${offered.reduce((s, r) => s + r.quality.uTurnCount, 0)} | ${(100 * Math.max(0, ...geometric)).toFixed(1)}% | ${(100 * Math.max(0, ...physical)).toFixed(1)}% |`)
}
say('\n## Preprocessing accounting\n')
say('| fixture | family | exploration ms | selection ms | routing elapsed ms | total analysis path ms | summed GH engine route ms | summed route boundary wall ms |')
say('|---|---|---:|---:|---:|---:|---:|---:|')
for (const field of fields) for (const family of ['A', 'B']) {
  const rows = results.filter(row => row.fixture === field.name && row.family === family)
  const selection = selectionCosts.find(row => row.fixture === field.name && row.family === family)!.ms
  const routing = routingCosts.find(row => row.fixture === field.name && row.family === family)!.ms
  say(`| ${field.name} | ${family} | ${field.wallMs.toFixed(2)} | ${selection.toFixed(2)} | ${routing.toFixed(1)} | ${(field.wallMs + selection + routing).toFixed(1)} | ${rows.reduce((sum, row) => sum + row.engineRouteMs, 0).toFixed(1)} | ${rows.reduce((sum, row) => sum + row.routeWallMs, 0).toFixed(1)} |`)
}
mkdirSync(new URL('results/', import.meta.url), { recursive: true })
writeFileSync(new URL('results/offline.md', import.meta.url), lines.join('\n') + '\n')
writeFileSync(new URL('results/offline.json', import.meta.url), JSON.stringify({ fields: fields.map(field => ({ name: field.name, targetMetres: field.targetMetres, limitMetres: field.limitMetres, nodesVisited: field.nodesVisited, edgesVisited: field.edgesVisited, wallMs: field.wallMs, heapDeltaBytes: field.heapDeltaBytes })), selectionCosts, routingCosts, plans: [...planSets.values()].flat(), results: results.map(({ coordinates, traversals, ...row }) => ({ ...row, pointCount: coordinates.length, edgeCount: traversals?.length ?? 0 })) }, null, 2) + '\n')
