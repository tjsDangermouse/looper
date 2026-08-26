/** Every knob the service has, read once at start-up. */
const number = (value: string | undefined, fallback: number) => {
  const parsed = Number(value)
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback
}

export const config = {
  port: number(process.env.PORT, 8080),
  graphhopperIomUrl: process.env.GRAPHHOPPER_IOM_URL ?? process.env.GRAPHHOPPER_URL ?? 'http://localhost:8989',
  graphhopperEnglandUrl: process.env.GRAPHHOPPER_ENGLAND_URL ?? 'http://graphhopper-england:8989',
  graphhopperProfile: process.env.GRAPHHOPPER_PROFILE ?? 'foot',
  /** Per-leg routing timeout. */
  legTimeoutMs: number(process.env.LEG_TIMEOUT_MS, 8000),
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
} as const

export type Config = typeof config
