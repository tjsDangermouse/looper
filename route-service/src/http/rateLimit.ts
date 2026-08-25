/**
 * A fixed window per client, held in memory.
 *
 * One small container serves one small app; a shared store would be more
 * machinery than the problem deserves. Generating a set of loops is close to a
 * hundred routing calls, so the limit is about protecting the engine, not about
 * punishing anyone.
 */
export type RateLimiter = { take: (key: string, now?: number) => boolean; reset: () => void }

export function createRateLimiter(perMinute: number, windowMs = 60_000): RateLimiter {
  const hits = new Map<string, { count: number; since: number }>()
  return {
    take(key, now = Date.now()) {
      const prior = hits.get(key)
      if (!prior || now - prior.since >= windowMs) {
        hits.set(key, { count: 1, since: now })
        if (hits.size > 5000) for (const [k, v] of hits) if (now - v.since >= windowMs) hits.delete(k)
        return true
      }
      if (prior.count >= perMinute) return false
      prior.count++
      return true
    },
    reset: () => hits.clear(),
  }
}
