/**
 * Algorithm feature flags.
 *
 * Each significant change to how loops are found gets its own switch, and each
 * one arrives switched off. Two unproven changes enabled together produce a
 * regression nobody can attribute to either of them, which is worse than
 * shipping neither.
 *
 * Flags are passed down as ordinary options rather than read from the
 * environment inside the generator, so a test states the algorithm it is
 * testing instead of inheriting whatever the machine happens to be set to.
 */
export type AlgorithmFlags = {
  /**
   * Measure retracing and route-to-route similarity from the network edges
   * actually traversed, rather than from geometric proximity. Falls back to
   * geometry per route whenever the engine did not supply edge ids.
   */
  edgeOverlap: boolean
  /**
   * Dispatch candidate bearings spread round the compass rather than in order
   * round it, so that stopping partway leaves a sample of the ground rather
   * than a sample of one side of it.
   */
  spreadCandidateBearings: boolean
  /**
   * Stop dispatching candidates when the real diversity selector can already
   * fill three offers, rather than after a fixed count of passing candidates.
   * Only meaningful alongside `spreadCandidateBearings`, since an in-order
   * prefix of bearings can never satisfy a "different directions" rule.
   */
  diversityAwareEarlyStop: boolean
  /** Keep a bounded archive of non-dominated candidates before weighted scoring. */
  paretoArchive: boolean
  /** Attempt one bounded local repair on a candidate that narrowly failed one gate. */
  localRepair: boolean
  /** Aim candidate bearings using a reachability probe of the pedestrian network. */
  networkAwareSeeds: boolean
  /** Screen many cheap skeletons before paying for incremental avoidance. */
  twoStageScreening: boolean
  /**
   * Try only the two shapes that answer most of the time, instead of every
   * shape from a two-legged there-and-back to a five-legged estate loop.
   */
  narrowCornerSweep: boolean
  /**
   * Only pay for a cheaper reroute of an over-long leg when the leg actually
   * looks like it detoured round something. A leg that is long because its
   * target is far away is not going to be shortened by relaxing a penalty it
   * never ran into.
   */
  budgetDetourGate: boolean
  /**
   * Only undo and redo two legs when the join between them is a genuine
   * turn-around. A short dead-end branch straddling the seam is spliced out of
   * the finished geometry for nothing by the tiny-spike trim, so paying two
   * engine calls to route around one buys what we already had.
   */
  pullbackTurnOnly: boolean
  /**
   * Build waypoint loops from an ordered backbone and a slack budget spread
   * across the gaps, rather than from one global shaping point.
   */
  waypointBackbone: boolean
  /** Serve an identical repeat request from a bounded in-memory cache. */
  requestCache: boolean
}

/**
 * What ships. A flag turns on here only once the offline benchmark says it
 * earns its place — see docs/routing-baseline.md for the evidence behind each
 * one, including the one that did not.
 */
export const DEFAULT_FLAGS: AlgorithmFlags = {
  // 15% fewer engine calls with the bearing spread below, identical routes,
  // and it is the only measure that can tell a back lane from the road it
  // runs behind. Falls back to geometry per route where edge ids are absent.
  edgeOverlap: true,
  // 14% fewer engine calls on its own, and better-separated alternatives.
  spreadCandidateBearings: true,
  // Measured at 30% more engine calls than the bearing spread alone for half
  // a percentage point of extra separation. Left off; see the Phase 1 report.
  diversityAwareEarlyStop: false,
  // Correct and provably harmless, and the benchmark shows no benefit either:
  // the candidate pools are too small for a front to bind. Left off until
  // something produces a pool big enough for it to mean anything.
  paretoArchive: false,
  // Does what it says — four in five near misses become offerable walks for
  // about five engine calls each — and the walks offered do not improve for
  // it: the extra candidates rank well and separate badly, and the mean
  // overlap between the three offered walks gets worse. Left off; see the
  // Phase 2 report.
  localRepair: false,
  // Does exactly what it is for — a fifth off a seafront start, a ninth off a
  // promenade — and costs one extra call everywhere else, netting half a
  // percent across this fixture mix. Worth switching on for a coastal region
  // and measuring there; not worth switching on everywhere on this evidence.
  networkAwareSeeds: false,
  // Fewer HTTP calls (+1%) but 37% more path searches inside the engine, no
  // extra walks offered and no latency gained: putting a whole ring in one
  // request saves round trips, not the engine's work. Left off; see Phase 5.
  twoStageScreening: false,
  // The largest single win measured: waypoint walks cost 85% fewer engine
  // calls, hit the requested length four times more closely, and two fixtures
  // that previously returned nothing now return walks. See the Phase 4 report.
  // Measured on real production traffic: the fix-ups are 43% of all engine
  // work, and these two gates cut the wasted part without changing a single
  // offered walk. -8% calls together, and better-separated alternatives.
  // A quarter of all engine calls, and it costs a walk in twenty plus some
  // separation between the ones that remain. Whether that trade is worth it
  // depends on the ground, so it stays a decision rather than a default.
  narrowCornerSweep: false,
  budgetDetourGate: true,
  pullbackTurnOnly: true,
  waypointBackbone: true,
  requestCache: false,
}

export const withFlags = (flags?: Partial<AlgorithmFlags>): AlgorithmFlags => ({ ...DEFAULT_FLAGS, ...flags })

/** Deterministic, sorted, and short — it goes into cache keys and log lines. */
export const flagFingerprint = (flags: AlgorithmFlags): string =>
  (Object.keys(flags) as Array<keyof AlgorithmFlags>)
    .sort()
    .filter(name => flags[name])
    .join(',') || 'none'
