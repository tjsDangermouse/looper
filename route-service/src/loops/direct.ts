import { randomUUID } from 'node:crypto'
import type { LineString } from 'geojson'
import { GraphHopperError, parseLeg, type ClosedWalkSearch, type GraphHopperClient } from '../graphhopper.js'
import { MAX_SHARED_FRACTION, initialBearing, labelRoutes, selectDiverseRoutes } from './diversity.js'
import { measureTraversals, type EdgeTraversal } from './edges.js'
import type { LngLat } from './geo.js'
import { analyseRouteQuality, sharedCorridorMetres, type QualityReport } from './quality.js'
import { targetMetresFor, targetSecondsFor } from './units.js'
import { measureOffered } from './generate.js'
import type { LoopRequest, LoopResponse, LoopRoute } from './generate.js'
import type { EngineDiagnostics } from './engine.js'

/**
 * The direct closed-walk engine, on this side of the wire.
 *
 * The search happens in the routing facade, over GraphHopper's own graph, and
 * what comes back is a set of finished walks. Nothing here re-routes them and
 * nothing here re-defines what a good walk is: the walks are put through
 * Looper's own {@link analyseRouteQuality} with no threshold relaxed, and
 * through the same {@link selectDiverseRoutes} the Phase 3B generator ends on.
 * If a walk the search liked does not pass the gate, it is not offered — the
 * gate is the authority, and the whole value of searching the walk is that it
 * is the object the gate judges.
 *
 * ## What this deliberately does not do
 *
 * It does not hand the searched walk back to the router as via points. Phase 9
 * measured that: given three corners of a walk known to be good, GraphHopper
 * returns something 1,486 m away from it at median, and none of twelve walks
 * survives. The line that comes back from the facade is the line the search
 * chose, edge for edge.
 *
 * It does not handle ordered waypoints. Those stay on the Phase 3B path, and
 * the engine selector — not this module — is where that is decided.
 *
 * ## Declining
 *
 * A direct request that cannot be served returns {@link DirectDeclined} rather
 * than an empty answer, and the caller runs Phase 3B instead. That is the
 * whole of the fallback policy: the walker never sees a worse answer because a
 * new engine was switched on, and the reason travels with the result so a
 * field test can see how often it happened and why.
 */

/** Direct Search handing the request back, with the reason it did. */
export type DirectDeclined = { declined: true; reason: string; searchMs?: number; closedWalks?: number; stemMetres?: number; offered?: number }

export type DirectResult = {
  response: LoopResponse
  diagnostics: Pick<EngineDiagnostics, 'offered' | 'searchTurnRejections' | 'searchStemMetres' | 'searchStates' | 'searchExpanded' | 'searchGraphNodes' | 'searchRawNodes' | 'searchClosedWalks' | 'searchOfferedWalks' | 'searchMs' | 'searchPeakBytes' | 'searchRetainedBytes'>
  /** What the facade reported about its own stages; logged, never served. */
  timing?: ClosedWalkSearch['timing']
}

export type DirectOptions = {
  client: GraphHopperClient
  signal?: AbortSignal
  /** How many walks the facade hands back for the gate to judge. */
  candidateWalks?: number
  /** Below this many offered routes the request is handed back to Phase 3B. */
  minRoutes?: number
  timeoutMs?: number
  /** See config.direct.turnAware. */
  turnAware?: boolean
}

/**
 * How many walks are asked for.
 *
 * The search closes 120–190 walks per fixture and three are offered, so what
 * this number buys is the selector's room to separate them. It is not free —
 * every walk carries its full geometry, instructions and path details across
 * the wire — so it is a handful of times the offer rather than everything the
 * search found.
 */
export const DEFAULT_CANDIDATE_WALKS = 24

/**
 * Three walks, or hand the request back.
 *
 * Mixing a direct walk with two remote ones would produce a set nothing had
 * judged for diversity as a set, with two different notions of what a leg is
 * inside one answer. Phase 10 does not do that: an engine answers a request
 * whole or not at all, which also makes an A/B walk in the field a comparison
 * between two engines rather than between two blends of them.
 */
export const DEFAULT_MIN_ROUTES = 3

type Judged = {
  coordinates: LngLat[]
  distanceMeters: number
  durationSeconds: number
  steps: ReturnType<typeof parseLeg>['steps']
  report: QualityReport
  bearing: number
  traversals?: EdgeTraversal[]
  searchedMetres: number
}

export async function generateDirectLoops(
  request: LoopRequest,
  options: DirectOptions,
): Promise<DirectResult | DirectDeclined> {
  if (request.waypoints?.length) return { declined: true, reason: 'waypoints' }
  const start: LngLat = [request.start.lng, request.start.lat]
  const targetMetres = targetMetresFor(request)
  const targetSeconds = targetSecondsFor(request)
  const minRoutes = options.minRoutes ?? DEFAULT_MIN_ROUTES

  let search: ClosedWalkSearch
  try {
    search = await options.client.closedWalks(start, targetMetres, {
      wanted: options.candidateWalks ?? DEFAULT_CANDIDATE_WALKS,
      turnAware: options.turnAware,
      signal: options.signal,
      timeoutMs: options.timeoutMs,
    })
  } catch (error) {
    // Includes the 404 from a facade that does not know the endpoint. Every
    // one of these means the same thing to this caller: use Phase 3B.
    const kind = error instanceof GraphHopperError ? `search-${error.kind}` : 'search-failed'
    return { declined: true, reason: kind }
  }
  if (search.failure) return { declined: true, reason: `search-${search.failure}`, searchMs: search.timing?.search_ms }
  if (!search.walks?.length) {
    return { declined: true, reason: 'no-closed-walk', searchMs: search.timing?.search_ms, closedWalks: search.closedWalks ?? 0 }
  }

  // The production gate, on the searched walks, with nothing relaxed. A walk
  // searched in graph space has no legs — it was never cut into planned steps
  // — so `legDistances` is empty, which is exactly what the gate already does
  // for a single-leg walk: both leg-balance rules are skipped.
  const judged: Judged[] = []
  for (const walk of search.walks) {
    let leg
    try {
      leg = parseLeg(walk)
    } catch {
      continue
    }
    const traversals = measureTraversals(leg.coordinates, leg.edges)
    const report = analyseRouteQuality({
      traversals,
      coordinates: leg.coordinates,
      start,
      distanceMeters: leg.distanceMeters,
      durationSeconds: leg.durationSeconds,
      targetMetres,
      targetSeconds,
      legDistances: [],
      maneuverSigns: leg.steps.map(step => step.sign),
      thresholds: request.overrides?.quality,
    })
    judged.push({
      coordinates: leg.coordinates,
      distanceMeters: leg.distanceMeters,
      durationSeconds: leg.durationSeconds,
      steps: leg.steps,
      report,
      bearing: initialBearing(leg.coordinates, start),
      traversals,
      searchedMetres: walk.looper?.searchedMetres ?? leg.distanceMeters,
    })
  }

  const maxShared = request.overrides?.maxSharedFraction ?? MAX_SHARED_FRACTION
  const passing = judged.filter(entry => entry.report.pass)
  const fresh = request.exclude?.length
    ? passing.filter(entry => request.exclude!.every(previous => sharedCorridorMetres(entry.coordinates, previous).fraction <= maxShared))
    : passing
  const chosen = selectDiverseRoutes(fresh.map(entry => ({
    coordinates: entry.coordinates,
    quality: { score: entry.report.quality.score },
    bearing: entry.bearing,
    traversals: entry.traversals,
    totalMetres: entry.distanceMeters,
    source: entry,
  })), 3, maxShared)

  const stats = {
    offered: measureOffered(chosen.map(entry => ({
      coordinates: entry.source.coordinates,
      distanceMeters: entry.source.distanceMeters,
      quality: entry.source.report.quality,
      traversals: entry.source.traversals,
    })), targetMetres),
    searchStates: search.search?.store_size,
    searchExpanded: search.search?.expanded,
    searchGraphNodes: search.graph?.nodes,
    searchRawNodes: search.graph?.raw_nodes,
    searchClosedWalks: search.closedWalks,
    searchTurnRejections: search.rejectedTurns,
    searchStemMetres: search.search?.stem_metres,
    searchOfferedWalks: chosen.length,
    searchMs: search.timing?.search_ms,
    searchPeakBytes: search.search?.peak_store_bytes,
    searchRetainedBytes: search.search?.retained_bytes,
  }

  if (chosen.length < minRoutes) {
    return {
      declined: true,
      reason: passing.length ? 'too-few-diverse' : 'gate-rejected-all',
      searchMs: search.timing?.search_ms,
      closedWalks: search.closedWalks,
      stemMetres: search.search?.stem_metres,
      offered: chosen.length,
    }
  }

  const labels = labelRoutes(chosen.map(entry => ({ bearing: entry.bearing, distanceMeters: entry.source.distanceMeters })))
  const routes: LoopRoute[] = chosen.map((entry, position) => {
    const walk = entry.source
    return {
      id: randomUUID(),
      label: labels[position],
      distanceMeters: Math.round(walk.distanceMeters),
      durationSeconds: Math.round(walk.durationSeconds),
      targetDifferencePercent: Math.round((walk.distanceMeters / targetMetres - 1) * 100),
      geometry: { type: 'LineString', coordinates: walk.coordinates } as LineString,
      steps: walk.steps.map(step => ({
        instruction: step.instruction,
        distanceMeters: Math.round(step.distanceMeters),
        durationSeconds: Math.round(step.durationSeconds),
        maneuver: step.maneuver,
        road: step.road,
        roadClass: step.roadClass,
        startIndex: step.startIndex,
        endIndex: step.endIndex,
      })),
      quality: walk.report.quality,
    }
  })

  return {
    response: { routes },
    diagnostics: stats,
    timing: search.timing,
  }
}

export const isDeclined = (result: DirectResult | DirectDeclined): result is DirectDeclined =>
  (result as DirectDeclined).declined === true
