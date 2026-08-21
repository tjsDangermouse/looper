// Vercel serverless endpoint. Replace the fetch inside requestLoop if ORS limits are reached.
import { describeDirection, measure, nameLoops, selectLoops, type Point } from './_lib/loopQuality.js'
const hits = new Map<string, { count: number; at: number }>()

type ApiRequest = { method?: string; headers?: Record<string, string | string[] | undefined>; body?: { start?: { lng?: number; lat?: number }; inputMode?: string; distanceKm?: number; minutes?: number } }
type ApiResponse = { status: (code: number) => ApiResponse; json: (payload: unknown) => void }

// Candidate loops are cheap relative to a bad walk, so we ask for a pool and
// keep the best three, stopping as soon as a wave has supplied them. The
// waypoint counts vary within a wave: fewer points give a rounder circuit,
// more give a wandering one, and the good shape for a given street layout is
// not knowable in advance. Two waves is the ceiling the ORS free tier allows
// (40 directions calls a minute) against this endpoint's own 8-per-minute cap.
const WAVES = [[3, 4, 5, 6], [3, 4, 5, 6]]

export default async function handler(req: ApiRequest, res: ApiResponse) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' })
  const ip = String(req.headers?.['x-forwarded-for'] || 'local').split(',')[0]
  const now = Date.now(), prior = hits.get(ip)
  if (prior && now - prior.at < 60_000 && prior.count >= 8) return res.status(429).json({ error: 'Please wait a moment before finding more loops.' })
  hits.set(ip, { count: (prior && now - prior.at < 60_000 ? prior.count : 0) + 1, at: now })

  const { start, inputMode, distanceKm, minutes } = req.body || {}
  if (!start || !Number.isFinite(start.lng) || !Number.isFinite(start.lat) || Math.abs(start.lng!) > 180 || Math.abs(start.lat!) > 90) return res.status(400).json({ error: 'Choose a valid starting point.' })
  const targetKm = inputMode === 'time' ? Number(minutes) / 12 : Number(distanceKm)
  if (!['distance', 'time'].includes(inputMode || '') || !Number.isFinite(targetKm) || targetKm < 1 || targetKm > 20) return res.status(400).json({ error: inputMode === 'time' ? 'Choose 15 minutes to 4 hours.' : 'Choose a loop between 1 and 20 km.' })
  if (!process.env.ORS_API_KEY) return res.status(503).json({ error: process.env.VERCEL_ENV === 'production' ? 'Route service is unavailable.' : 'Add ORS_API_KEY to generate routes locally.' })

  const origin: Point = [start.lng!, start.lat!]
  const targetMeters = targetKm * 1000
  let throttled = false
  const requestLoop = async (length: number, seed: number, points: number) => {
    const response = await fetch('https://api.heigit.org/openrouteservice/v2/directions/foot-walking/geojson', {
      method: 'POST', headers: { Authorization: process.env.ORS_API_KEY!, 'Content-Type': 'application/json' },
      body: JSON.stringify({ coordinates: [[start.lng, start.lat]], instructions: true, options: { round_trip: { length: Math.round(length), points, seed } } }),
    })
    if (!response.ok) { throttled ||= response.status === 429; return undefined }
    const data: any = await response.json(), feature = data.features?.[0], summary = feature?.properties?.summary
    if (!feature?.geometry?.coordinates?.length || !summary) return undefined
    const steps = (feature.properties.segments || []).flatMap((segment: any) => segment.steps || []).map((step: any) => ({ instruction: step.instruction, distanceMeters: step.distance, durationSeconds: step.duration, startIndex: step.way_points?.[0], endIndex: step.way_points?.[1], maneuver: step.type }))
    const coordinates: Point[] = feature.geometry.coordinates
    return { coordinates, geometry: feature.geometry, summary, steps, metrics: measure(coordinates, summary.distance, targetMeters, steps.map((s: any) => s.maneuver)) }
  }

  type Candidate = NonNullable<Awaited<ReturnType<typeof requestLoop>>>

  try {
    const candidates: Candidate[] = []
    for (const wave of WAVES) {
      const results = await Promise.all(wave.map(points => requestLoop(targetMeters, Math.floor(Math.random() * 1_000_000), points).catch(() => undefined)))
      candidates.push(...results.filter((r): r is Candidate => !!r))
      // Stop early once the pool already holds three clean, distinct loops.
      if (selectLoops(candidates, 3, false).length >= 3) break
    }
    if (throttled && !candidates.length) return res.status(503).json({ error: 'The route service is busy. Please try again in a moment.' })
    if (!candidates.length) return res.status(502).json({ error: 'No loops found from this point. Try a different distance.' })

    const chosen = selectLoops(candidates)
    if (!chosen.length) return res.status(502).json({ error: 'No loops of that length start from here. Try a different distance.' })
    const names = nameLoops(chosen.map(candidate => ({ distanceMeters: candidate.summary.distance, direction: describeDirection(candidate.coordinates, origin) })))
    const routes = chosen.map((candidate, index) => ({
      id: crypto.randomUUID(),
      name: names[index],
      distanceMeters: candidate.summary.distance,
      durationSeconds: candidate.summary.duration,
      targetDifferencePercent: Math.round((candidate.summary.distance / targetMeters - 1) * 100),
      geometry: candidate.geometry,
      steps: candidate.steps,
    }))
    return res.status(200).json({ routes })
  } catch { return res.status(502).json({ error: 'Route service is unavailable. Please try again.' }) }
}
