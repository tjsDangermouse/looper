/**
 * Gate 5: the whole Looper generator, twice, over two engines.
 *
 * The route service is started once per engine with nothing changed but
 * GRAPHHOPPER_IOM_URL, and the same six production requests are put through
 * it. If the engines are the same engine, every candidate the generator
 * builds, rejects, repairs and ranks is built from the same legs, so the
 * routes that come out the far end must be identical — not similar. Anything
 * less means some server-side behaviour has not been reproduced, and the
 * per-route geometry hash is what says so.
 */
import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { writeFileSync } from 'node:fs'

const ENGINES = [
  { label: 'graphhopper-container', url: 'http://localhost:8989', port: 8801 },
  { label: 'minimal-core', url: 'http://localhost:8991', port: 8802 },
]

const START = { lng: -4.4816, lat: 54.1506 }
/** The established production probe set, unchanged. */
const FIXTURES: Array<{ name: string; body: any }> = [
  { name: 'douglas-5km', body: { start: START, mode: 'distance', distanceKm: 5, units: 'km', variation: 0 } },
  { name: 'douglas-3km', body: { start: START, mode: 'distance', distanceKm: 3, units: 'km', variation: 0 } },
  { name: 'peel-5km', body: { start: { lng: -4.6947, lat: 54.2247 }, mode: 'distance', distanceKm: 5, units: 'km', variation: 0 } },
  { name: 'onchan-5km', body: { start: { lng: -4.4530, lat: 54.1745 }, mode: 'distance', distanceKm: 5, units: 'km', variation: 0 } },
  { name: 'wp-one', body: { start: START, mode: 'distance', distanceKm: 6, units: 'km', variation: 0, waypoints: [{ lng: -4.4746, lat: 54.1566 }] } },
  { name: 'wp-two', body: { start: START, mode: 'distance', distanceKm: 8, units: 'km', variation: 0, waypoints: [{ lng: -4.4700, lat: 54.1560 }, { lng: -4.4900, lat: 54.1600 }] } },
]

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms))

const startService = async (url: string, port: number) => {
  const child = spawn('npx', ['tsx', 'src/index.ts'], {
    cwd: new URL('../..', import.meta.url).pathname,
    env: {
      ...process.env,
      PORT: String(port),
      GRAPHHOPPER_IOM_URL: url,
      GRAPHHOPPER_ENGLAND_URL: url,
      // The generator must not be throttled, and nothing may be served from a
      // previous engine's answers.
      RATE_LIMIT_PER_MINUTE: '100000',
      LOOPER_REQUEST_CACHE: 'false',
      LOG_LEVEL: 'error',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  child.stderr.on('data', d => { const s = String(d); if (s.includes('Error') || s.includes('error')) process.stderr.write(s) })
  for (let i = 0; i < 120; i++) {
    await sleep(500)
    try {
      const r = await fetch(`http://localhost:${port}/health`)
      if (r.ok) return child
    } catch { /* not up yet */ }
  }
  child.kill('SIGKILL')
  throw new Error(`route service on :${port} never became healthy`)
}

/** Six decimals, matching the low-level comparison so the two tables mean the same thing. */
const hashRoute = (coords: number[][]) =>
  createHash('sha256').update(coords.map(([a, b]) => `${Math.round(a * 1e6) / 1e6},${Math.round(b * 1e6) / 1e6}`).join(';')).digest('hex').slice(0, 16)

const runEngine = async (engine: typeof ENGINES[number]) => {
  console.log(`\n=== ${engine.label} (${engine.url}) ===`)
  const child = await startService(engine.url, engine.port)
  const out: any[] = []
  try {
    for (const fixture of FIXTURES) {
      const began = Date.now()
      const response = await fetch(`http://localhost:${engine.port}/v1/loops`, {
        method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(fixture.body),
      })
      const wallMs = Date.now() - began
      const payload: any = await response.json()
      const routes = (payload.routes ?? []).map((r: any) => ({
        distanceMeters: r.distanceMeters,
        quality: r.quality?.score ?? r.score ?? null,
        repeatedFraction: r.quality?.repeatedFraction ?? null,
        geometryHash: hashRoute(r.geometry?.coordinates ?? r.coordinates ?? []),
        pointCount: (r.geometry?.coordinates ?? r.coordinates ?? []).length,
      }))
      const metrics = payload.diagnostics?.metrics ?? {}
      const row = {
        name: fixture.name, wallMs, routeCount: routes.length, routes,
        graphhopperCalls: metrics.graphhopperCalls ?? null,
        engineMs: metrics.engineMs ?? null,
        totalMs: metrics.totalMs ?? null,
        visitedNodes: metrics.visitedNodes ?? null,
      }
      out.push(row)
      console.log(`${fixture.name.padEnd(14)} ${String(wallMs).padStart(6)}ms wall  routes=${routes.length}  calls=${String(row.graphhopperCalls).padStart(4)}  engineMs=${Math.round(row.engineMs ?? 0)}`)
    }
  } finally {
    child.kill('SIGKILL')
    await sleep(500)
  }
  return out
}

const results: Record<string, any[]> = {}
for (const engine of ENGINES) results[engine.label] = await runEngine(engine)

writeFileSync(new URL('results-full-loops.json', import.meta.url), JSON.stringify(results, null, 1))

// --- equivalence -----------------------------------------------------------
const [a, b] = ENGINES.map(e => results[e.label])
console.log('\nfixture          routes  distances  quality  geometry |  container ms   core ms   calls')
console.log('--------------  -------  ---------  -------  -------- | ------------  --------  ------')
let failures = 0
for (let i = 0; i < FIXTURES.length; i++) {
  const x = a[i], y = b[i]
  const same = (f: (r: any) => unknown) => JSON.stringify(x.routes.map(f)) === JSON.stringify(y.routes.map(f))
  const checks = {
    count: x.routeCount === y.routeCount,
    distances: same((r: any) => r.distanceMeters),
    quality: same((r: any) => r.quality),
    geometry: same((r: any) => r.geometryHash),
  }
  // Engine-call count is reported, never asserted. The diversity-aware early
  // stop evaluates the candidate pool at wave boundaries, and candidates are
  // routed concurrently, so which candidates have landed when the stop trips
  // depends on arrival order — that is, on latency. The same engine gives 763
  // and 779 calls on alternate runs of peel-5km while returning byte-identical
  // walks. What must match is the walks.
  if (Object.values(checks).some(v => !v)) failures++
  const t = (ok: boolean) => (ok ? '  ok' : 'DIFF')
  console.log(
    `${x.name.padEnd(14)}  ${t(checks.count).padStart(7)}  ${t(checks.distances).padStart(9)}  ${t(checks.quality).padStart(7)}` +
    `  ${t(checks.geometry).padStart(8)} | ${String(x.wallMs).padStart(11)}  ${String(y.wallMs).padStart(8)}  ${String(x.graphhopperCalls).padStart(4)}/${String(y.graphhopperCalls).padEnd(4)}`,
  )
}
const sum = (rows: any[]) => rows.reduce((s, r) => s + r.wallMs, 0)
console.log(`\ntotal wall: container ${sum(a)} ms, minimal core ${sum(b)} ms  ->  ${(sum(a) / sum(b)).toFixed(2)}x`)
console.log(failures ? `\nFAIL: ${failures} of ${FIXTURES.length} fixtures differ` : `\nPASS: all ${FIXTURES.length} full-generation fixtures identical`)
