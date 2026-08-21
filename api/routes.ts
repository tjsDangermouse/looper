// Vercel serverless endpoint. Replace the fetch inside requestLoop if ORS limits are reached.
const hits = new Map<string, { count: number; at: number }>()
const labels = ['North loop', 'Park loop', 'West loop', 'Riverside loop', 'East loop']

type ApiRequest = { method?: string; headers?: Record<string, string | string[] | undefined>; body?: { start?: { lng?: number; lat?: number }; inputMode?: string; distanceKm?: number; minutes?: number } }
type ApiResponse = { status: (code: number) => ApiResponse; json: (payload: unknown) => void }

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

  const targetMeters = targetKm * 1000
  const requestLoop = async (length: number, seed: number) => {
    const response = await fetch('https://api.heigit.org/openrouteservice/v2/directions/foot-walking/geojson', {
      method: 'POST', headers: { Authorization: process.env.ORS_API_KEY!, 'Content-Type': 'application/json' },
      body: JSON.stringify({ coordinates: [[start.lng, start.lat]], instructions: true, options: { round_trip: { length: Math.round(length), points: 4 + (seed % 3), seed } } }),
    })
    if (!response.ok) return undefined
    const data: any = await response.json(), feature = data.features?.[0], summary = feature?.properties?.summary
    return feature && summary ? { feature, summary } : undefined
  }

  try {
    const routes = []
    for (let index = 0; index < 5 && routes.length < 3; index++) {
      const seed = Math.floor(Math.random() * 1_000_000)
      let result = await requestLoop(targetMeters, seed)
      if (!result) continue
      const difference = Math.abs(result.summary.distance - targetMeters) / targetMeters
      // ORS round trips are approximate. Correct once using the observed distance ratio.
      if (difference > .10) result = await requestLoop(targetMeters * targetMeters / result.summary.distance, seed) || result
      const steps = (result.feature.properties.segments || []).flatMap((segment: any) => segment.steps || []).map((step: any) => ({ instruction: step.instruction, distanceMeters: step.distance, durationSeconds: step.duration, startIndex: step.way_points?.[0], endIndex: step.way_points?.[1], maneuver: step.type }))
      routes.push({ id: crypto.randomUUID(), name: labels[routes.length], distanceMeters: result.summary.distance, durationSeconds: result.summary.duration, targetDifferencePercent: Math.round((result.summary.distance / targetMeters - 1) * 100), geometry: result.feature.geometry, steps })
    }
    if (!routes.length) return res.status(502).json({ error: 'No loops found from this point. Try a different distance.' })
    return res.status(200).json({ routes })
  } catch { return res.status(502).json({ error: 'Route service is unavailable. Please try again.' }) }
}
