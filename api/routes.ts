// Vercel serverless endpoint. Loops are built from waypoint rings we choose and
// then scored — ORS `round_trip` is deliberately not used, because its seeded
// shapes double back, cross bridges twice and cannot be reasoned about.
import { describeDirection, nameLoops, qualityCues, scoreLoopRoute, selectLoops, type Assessment, type Point, type Target } from './_lib/loopQuality.js'
import { generateCandidates, metresFromMinutes, minutesFromMetres, routeCoordinates, seedFor } from './_lib/waypoints.js'

const ORS_URL = 'https://api.heigit.org/openrouteservice/v2/directions/foot-walking/geojson'
const CANDIDATES = 18
const CONCURRENCY = 4
// Wide enough to reach the nearest footpath, tight enough that a waypoint in a
// field cannot silently jump to an unrelated road a kilometre away.
const SNAP_RADIUS_METRES = 400
const CACHE_TTL_MS = 5 * 60_000
// A serverless invocation is killed at a fixed wall clock, so the search is
// given a budget rather than a request count: whatever has come back when the
// budget runs out is what gets scored. One stalled ORS call must not cost the
// walker the whole search, hence the shorter per-call timeout as well.
const SEARCH_BUDGET_MS = Number(process.env.LOOPER_SEARCH_BUDGET_MS) || 45_000
const ORS_TIMEOUT_MS = 12_000
// One search is CANDIDATES calls to ORS, whose free tier allows 40 a minute.
// Two searches a minute per caller keeps the whole app inside that budget; the
// short-lived cache absorbs the repeat presses this would otherwise refuse.
const RATE_LIMIT = { max: Math.max(1, Math.floor(40 / CANDIDATES)), windowMs: 60_000 }
const development = process.env.VERCEL_ENV !== 'production'

type ApiRequest = { method?: string; headers?: Record<string, string | string[] | undefined>; body?: { start?: { lng?: number; lat?: number }; inputMode?: string; distanceKm?: number; minutes?: number; unit?: string } }
type ApiResponse = { status: (code: number) => ApiResponse; json: (payload: unknown) => void }

const hits = new Map<string, { count: number; at: number }>()
const cache = new Map<string, { at: number; payload: unknown }>()

type Candidate = { coordinates: Point[]; geometry: unknown; distanceMeters: number; durationSeconds: number; steps: unknown[]; assessment: Assessment }

/** Keep at most `limit` ORS calls in flight. The free tier is 40 directions a
 *  minute; 18 candidates fired at once would burn a third of that in a second
 *  and start collecting 429s mid-search. */
async function mapLimited<T, R>(items: T[], limit: number, deadline: number, worker: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length)
  let next = 0
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    for (let index = next++; index < items.length && Date.now() < deadline; index = next++) results[index] = await worker(items[index])
  }))
  return results
}

export default async function handler(req: ApiRequest, res: ApiResponse) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' })
  const ip = String(req.headers?.['x-forwarded-for'] || 'local').split(',')[0]
  const now = Date.now(), prior = hits.get(ip)
  if (prior && now - prior.at < RATE_LIMIT.windowMs && prior.count >= RATE_LIMIT.max) return res.status(429).json({ error: 'Please wait a moment before finding more loops.' })
  hits.set(ip, { count: prior && now - prior.at < RATE_LIMIT.windowMs ? prior.count + 1 : 1, at: now })

  const { start, inputMode, distanceKm, minutes, unit } = req.body || {}
  if (!start || !Number.isFinite(start.lng) || !Number.isFinite(start.lat) || Math.abs(start.lng!) > 180 || Math.abs(start.lat!) > 90) return res.status(400).json({ error: 'Choose a valid starting point.' })
  const timed = inputMode === 'time'
  const targetKm = timed ? metresFromMinutes(Number(minutes)) / 1000 : Number(distanceKm)
  if (!['distance', 'time'].includes(inputMode || '') || !Number.isFinite(targetKm) || targetKm < 1 || targetKm > 20) return res.status(400).json({ error: timed ? 'Choose 15 minutes to 4 hours.' : 'Choose a loop between 1 and 20 km.' })
  if (!process.env.ORS_API_KEY) return res.status(503).json({ error: development ? 'Add ORS_API_KEY to generate routes locally.' : 'Route service is unavailable.' })

  const origin: Point = [start.lng!, start.lat!]
  const targetMetres = targetKm * 1000
  const target: Target = { metres: targetMetres, seconds: timed ? Number(minutes) * 60 : undefined, mode: timed ? 'time' : 'distance' }
  // Rounded to ~11 m: the same walk asked for twice should answer instantly and
  // identically, without a metre of GPS drift counting as a new search.
  const cacheKey = `${origin[0].toFixed(4)},${origin[1].toFixed(4)}|${inputMode}|${Math.round(targetMetres)}|${unit || 'km'}`
  const cached = cache.get(cacheKey)
  if (cached && now - cached.at < CACHE_TTL_MS) return res.status(200).json(cached.payload)

  const deadline = now + SEARCH_BUDGET_MS
  let throttled = false, reachedService = false
  const requestLoop = async (waypoints: Point[], forTarget: Target): Promise<Candidate | undefined> => {
    const coordinates = routeCoordinates(origin, waypoints)
    const response = await fetch(ORS_URL, {
      method: 'POST',
      headers: { Authorization: process.env.ORS_API_KEY!, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        coordinates,
        preference: 'recommended',
        // The ring order *is* the loop. Letting ORS re-order the waypoints would
        // turn the circuit back into a there-and-back.
        optimized: false,
        instructions: true,
        extra_info: ['osmid'],
        radiuses: coordinates.map(() => SNAP_RADIUS_METRES),
      }),
      signal: AbortSignal.timeout(ORS_TIMEOUT_MS),
    })
    reachedService = true
    // A waypoint with no path near it is an ordinary outcome here, not an error.
    if (!response.ok) { throttled ||= response.status === 429; return undefined }
    const data = await response.json() as any
    const feature = data.features?.[0], summary = feature?.properties?.summary
    if (!feature?.geometry?.coordinates?.length || !summary?.distance) return undefined
    const segments: any[] = feature.properties.segments || []
    const steps = segments.flatMap(segment => segment.steps || []).map((step: any) => ({
      instruction: step.instruction, distanceMeters: step.distance, durationSeconds: step.duration,
      startIndex: step.way_points?.[0], endIndex: step.way_points?.[1], maneuver: step.type,
    }))
    const route = {
      coordinates: feature.geometry.coordinates as Point[],
      distanceMeters: summary.distance as number,
      durationSeconds: summary.duration as number,
      legDistances: segments.map(segment => segment.distance as number),
      maneuvers: steps.map((step: any) => step.maneuver as number | undefined),
      wayValues: feature.properties.extras?.osmid?.values as number[][] | undefined,
    }
    return { ...route, geometry: feature.geometry, steps, assessment: scoreLoopRoute(route, forTarget) }
  }

  const gather = async (forTarget: Target, seedOffset: number) => {
    const rings = generateCandidates(origin, forTarget.metres, CANDIDATES, seedFor(origin, forTarget.metres) + seedOffset)
    const results = await mapLimited(rings, CONCURRENCY, deadline, ring => requestLoop(ring.waypoints, forTarget).catch(() => undefined))
    return results.filter((r): r is Candidate => !!r)
  }

  try {
    let candidates = await gather(target, 0)
    let chosen = selectLoops(candidates)

    // Time input only: ORS's own duration is the truth, and a first pass sized
    // by 5 km/h can land consistently short or long on hilly or winding ground.
    // One correction pass, scaled by how far the best attempt actually missed.
    // Only worth a second pass if there is time left to run one.
    if (timed && !chosen.length && candidates.length && Date.now() < deadline - SEARCH_BUDGET_MS / 3) {
      const best = candidates.reduce((a, b) => (a.assessment.metrics.durationErrorFraction <= b.assessment.metrics.durationErrorFraction ? a : b))
      const ratio = target.seconds! / best.durationSeconds
      if (Math.abs(1 - ratio) > .12) {
        const retryTarget: Target = { ...target, metres: Math.min(20000, Math.max(1000, targetMetres * ratio)) }
        const retried = await gather(retryTarget, 1)
        // Re-scored against the original ask, so the retry cannot flatter itself.
        candidates = [...candidates, ...retried]
        chosen = selectLoops(candidates)
      }
    }

    if (development) console.log(`[looper] ${Date.now() - now} ms, ${candidates.length} of ${CANDIDATES} rings routed, ${candidates.filter(c => c.assessment.passed).length} clean`, candidates.map(c => ({ km: +(c.distanceMeters / 1000).toFixed(2), score: Math.round(c.assessment.score), why: c.assessment.rejections })))

    if (!chosen.length) {
      if (!reachedService) return res.status(502).json({ error: 'Route service is unavailable. Please try again.' })
      if (throttled && !candidates.length) return res.status(503).json({ error: 'The route service is busy. Please try again in a moment.' })
      // Not an error: the local path network genuinely cannot make this walk.
      return res.status(200).json({ routes: [], reason: 'no-clean-loop' })
    }

    const cues = qualityCues(chosen.map(candidate => candidate.assessment))
    const names = nameLoops(chosen.map(candidate => ({ distanceMeters: candidate.distanceMeters, direction: describeDirection(candidate.assessment.metrics.dominantBearing) })))
    const payload = {
      routes: chosen.map((candidate, index) => ({
        id: `${cacheKey}#${index}`,
        name: names[index],
        cue: cues[index],
        distanceMeters: candidate.distanceMeters,
        durationSeconds: candidate.durationSeconds,
        targetDifferencePercent: Math.round((timed ? candidate.durationSeconds / target.seconds! : candidate.distanceMeters / targetMetres) * 100 - 100),
        geometry: candidate.geometry,
        steps: candidate.steps,
      })),
      // Rounded target in minutes, so the UI can talk about the ask, not the key.
      targetMinutes: Math.round(minutesFromMetres(targetMetres)),
    }
    cache.set(cacheKey, { at: now, payload })
    for (const [key, entry] of cache) if (now - entry.at > CACHE_TTL_MS) cache.delete(key)
    return res.status(200).json(payload)
  } catch (error) {
    if (development) console.error('[looper]', error)
    return res.status(502).json({ error: 'Route service is unavailable. Please try again.' })
  }
}
