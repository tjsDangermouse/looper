/**
 * Which engine answers a loop request.
 *
 * Two exist and they are different pieces of machinery, not two settings of
 * one. `remote` is the Phase 3B generator: candidate bearings, legs routed
 * one at a time by GraphHopper, the finished walk measured and offered or
 * thrown away. `direct` is the Phase 9 closed-walk search: the walk itself is
 * searched over the request-local graph inside the routing facade, and no
 * point-to-point routing call is made at all.
 *
 * The choice is resolved in exactly one place — {@link resolveRoutingEngine} —
 * and the result is carried as a value. There is deliberately no boolean flag
 * threaded through the generator asking "am I the new one": a request has one
 * engine, decided once, and everything downstream is told which.
 *
 * ## Precedence
 *
 * ```text
 * ordered user waypoints        -> remote, always
 * an explicit request engine    -> that engine
 * the server default flag       -> direct when LOOPER_DIRECT_CLOSED_WALK_SEARCH
 * otherwise                     -> remote (Phase 3B)
 * ```
 *
 * Waypoints come first and are not negotiable. An ordered pin list is a
 * different object from a rooted circuit, the direct search has no
 * representation for one, and Phase 10 does not redesign waypoint routing. A
 * client that asks for `direct` with waypoints gets a route rather than an
 * error, and the answer says which engine actually produced it.
 */

export const ROUTING_ENGINES = ['remote', 'direct'] as const
export type RoutingEngine = (typeof ROUTING_ENGINES)[number]

/** What ships. Direct Search is opt-in until real-world testing says otherwise. */
export const DEFAULT_ROUTING_ENGINE: RoutingEngine = 'remote'

export const isRoutingEngine = (value: unknown): value is RoutingEngine =>
  typeof value === 'string' && (ROUTING_ENGINES as readonly string[]).includes(value)

/** Why the request ended up on the engine it did. Developer-facing only. */
export type EngineReason =
  /** The request named this engine. */
  | 'requested'
  /** Nothing named one, so the server default applied. */
  | 'server-default'
  /** Direct Search was asked for, but the request carries ordered waypoints. */
  | 'waypoint-fallback'
  /** The facade behind this region cannot search walks. */
  | 'engine-unsupported'

export type EngineChoice = {
  /** What the request asked for, if it asked. */
  requested?: RoutingEngine
  /** What will actually run. */
  engine: RoutingEngine
  reason: EngineReason
}

export function resolveRoutingEngine(input: {
  requested?: RoutingEngine
  serverDefault: RoutingEngine
  hasWaypoints: boolean
  /** False where the region's facade does not advertise `looper_closed_walk`. */
  directAvailable?: boolean
}): EngineChoice {
  const wanted = input.requested ?? input.serverDefault
  const reason: EngineReason = input.requested ? 'requested' : 'server-default'
  if (wanted !== 'direct') return { ...(input.requested ? { requested: input.requested } : {}), engine: 'remote', reason }
  if (input.hasWaypoints) return { requested: 'direct', engine: 'remote', reason: 'waypoint-fallback' }
  if (input.directAvailable === false) return { requested: 'direct', engine: 'remote', reason: 'engine-unsupported' }
  return { ...(input.requested ? { requested: input.requested } : {}), engine: 'direct', reason }
}

/**
 * What a result says about how it was produced.
 *
 * Kept beside the routes rather than inside them, and deliberately separate
 * from anything a walker sees: the app's map, walk screen and instructions
 * must work identically whichever engine answered, so nothing here is allowed
 * to become part of route semantics. It exists so that a phone on a hillside
 * can say which engine drew the line it is standing on.
 */
export type EngineDiagnostics = {
  requestedEngine?: RoutingEngine
  routingEngine: RoutingEngine
  engineReason: EngineReason
  generationMs: number
  /** Present when Direct Search ran and handed the request back. */
  fallbackReason?: string
  /** Direct Search only. */
  searchStates?: number
  searchExpanded?: number
  /** Nodes in the reduced search graph, after peeling and contraction. */
  searchGraphNodes?: number
  /** Nodes the bounded exploration settled, before either reduction. */
  searchRawNodes?: number
  searchClosedWalks?: number
  /** Completed walks the gate's own u-turn rule dropped before ranking. */
  searchTurnRejections?: number
  /** How far the walk had to reach out of the door to meet the 2-core. */
  searchStemMetres?: number
  searchOfferedWalks?: number
  searchMs?: number
  searchPeakBytes?: number
  searchRetainedBytes?: number
  /**
   * What the walker was actually offered, measured the same way for both
   * engines — see `measureOffered`. Present on the direct path so that a
   * paired benchmark compares the same numbers rather than two derivations of
   * them; the remote path reports the same figures under `diagnostics.metrics`.
   */
  offered?: unknown
}
