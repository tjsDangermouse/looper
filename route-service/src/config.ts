import { DEFAULT_FLAGS, type AlgorithmFlags } from './loops/flags.js'

/** Every knob the service has, read once at start-up. */
const number = (value: string | undefined, fallback: number) => {
  const parsed = Number(value)
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback
}

/**
 * Anything but an explicit `true`/`1` leaves the flag as it ships. A typo in a
 * deployment environment should mean "the algorithm I already had", never "an
 * unproven one, silently".
 *
 * Empty counts as absent, and that is load-bearing rather than tidy. Compose
 * passes an unset variable through as `''`, not as nothing, so reading it as
 * "not true, therefore false" would take every flag that ships *on* and
 * silently switch it off across a whole deployment — the loudest possible
 * version of the failure this function exists to prevent.
 */
export const flag = (value: string | undefined, fallback: boolean) =>
  value === undefined || value === '' ? fallback : value === 'true' || value === '1'

const flags: AlgorithmFlags = {
  edgeOverlap: flag(process.env.LOOPER_EDGE_OVERLAP, DEFAULT_FLAGS.edgeOverlap),
  spreadCandidateBearings: flag(process.env.LOOPER_SPREAD_BEARINGS, DEFAULT_FLAGS.spreadCandidateBearings),
  diversityAwareEarlyStop: flag(process.env.LOOPER_DIVERSITY_EARLY_STOP, DEFAULT_FLAGS.diversityAwareEarlyStop),
  paretoArchive: flag(process.env.LOOPER_PARETO_ARCHIVE, DEFAULT_FLAGS.paretoArchive),
  localRepair: flag(process.env.LOOPER_LOCAL_REPAIR, DEFAULT_FLAGS.localRepair),
  networkAwareSeeds: flag(process.env.LOOPER_NETWORK_AWARE_SEEDS, DEFAULT_FLAGS.networkAwareSeeds),
  twoStageScreening: flag(process.env.LOOPER_TWO_STAGE_SCREENING, DEFAULT_FLAGS.twoStageScreening),
  narrowCornerSweep: flag(process.env.LOOPER_NARROW_CORNER_SWEEP, DEFAULT_FLAGS.narrowCornerSweep),
  progressiveCornerSweep: flag(process.env.LOOPER_PROGRESSIVE_CORNER_SWEEP, DEFAULT_FLAGS.progressiveCornerSweep),
  budgetDetourGate: flag(process.env.LOOPER_BUDGET_DETOUR_GATE, DEFAULT_FLAGS.budgetDetourGate),
  pullbackTurnOnly: flag(process.env.LOOPER_PULLBACK_TURN_ONLY, DEFAULT_FLAGS.pullbackTurnOnly),
  guidePointPullback: flag(process.env.LOOPER_GUIDE_POINT_PULLBACK, DEFAULT_FLAGS.guidePointPullback),
  waypointBackbone: flag(process.env.LOOPER_WAYPOINT_BACKBONE, DEFAULT_FLAGS.waypointBackbone),
  keepPinnedSpurs: flag(process.env.LOOPER_KEEP_PINNED_SPURS, DEFAULT_FLAGS.keepPinnedSpurs),
  requestCache: flag(process.env.LOOPER_REQUEST_CACHE, DEFAULT_FLAGS.requestCache),
}

export const config = {
  port: number(process.env.PORT, 8080),
  graphhopperIomUrl: process.env.GRAPHHOPPER_IOM_URL ?? process.env.GRAPHHOPPER_URL ?? 'http://localhost:8989',
  graphhopperEnglandUrl: process.env.GRAPHHOPPER_ENGLAND_URL ?? 'http://graphhopper-england:8989',
  graphhopperProfile: process.env.GRAPHHOPPER_PROFILE ?? 'foot',
  /** Per-leg routing timeout. */
  legTimeoutMs: number(process.env.LEG_TIMEOUT_MS, 8000),
  /**
   * The reachability probe's own timeout, deliberately much shorter than a
   * leg's: it runs before anything else and its whole purpose is to save work,
   * so a slow one has to be abandoned rather than waited for.
   */
  networkProbeTimeoutMs: number(process.env.NETWORK_PROBE_TIMEOUT_MS, 2500),
  /** Ceiling for one POST /v1/loops, after which everything in flight is cancelled. */
  requestTimeoutMs: number(process.env.REQUEST_TIMEOUT_MS, 25000),
  candidateCount: number(process.env.CANDIDATE_COUNT, 24),
  concurrency: number(process.env.ROUTING_CONCURRENCY, 6),
  /**
   * Ceiling on concurrent GraphHopper calls across *all* walkers at once, per
   * region — not per request, unlike `concurrency` above. Tune from real
   * traffic/load testing; this default is a starting point, not a target.
   */
  graphhopperMaxConcurrency: number(process.env.GRAPHHOPPER_MAX_CONCURRENCY, 24),
  /** Waiters beyond this are refused immediately rather than left to queue. */
  graphhopperMaxQueue: number(process.env.GRAPHHOPPER_MAX_QUEUE, 100),
  rateLimitPerMinute: number(process.env.RATE_LIMIT_PER_MINUTE, 20),
  corsOrigins: (process.env.CORS_ORIGINS ?? '*').split(',').map(origin => origin.trim()).filter(Boolean),
  isProduction: process.env.NODE_ENV === 'production',
  logLevel: process.env.LOG_LEVEL ?? 'info',
  /** See loops/flags.ts. Each algorithm change has its own switch. */
  flags,
  /**
   * How Looper talks to the engine, as opposed to what it asks for.
   *
   * Separate from `flags` on purpose: nothing here can change a route, so
   * nothing here belongs beside the switches that can. Both ship off, because
   * the model registry needs a facade that keeps corridors and the shipped
   * GraphHopper container does not — pointed at one that does not, the
   * capability check turns it off again by itself.
   */
  boundary: {
    /** Name a corridor set once and refer to it, instead of restating it per call. */
    modelRegistry: flag(process.env.LOOPER_MODEL_REGISTRY, false),
    /** Answer an identical request from the one already asked, within a generation. */
    routeMemo: flag(process.env.LOOPER_ROUTE_MEMO, false),
  },
  cacheMaxEntries: number(process.env.ROUTE_CACHE_MAX_ENTRIES, 500),
  cacheTtlMs: number(process.env.ROUTE_CACHE_TTL_MS, 10 * 60 * 1000),
  cacheEmptyTtlMs: number(process.env.ROUTE_CACHE_EMPTY_TTL_MS, 60 * 1000),
  /**
   * Bumped by hand when the walking profile is retuned. Old answers were
   * generated under the old model and are wrong the moment it changes.
   */
  profileVersion: process.env.GRAPHHOPPER_PROFILE_VERSION ?? 'looper-foot-4',
} as const

export type Config = typeof config
