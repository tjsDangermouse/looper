/**
 * Phase 4a of the iOS↔remote parity plan: measurement and report, no changes.
 *
 * Puts a fixed set of loop requests to the remote `/v1/loops`, computes the
 * same handful of shape metrics the on-device harness emits
 * (`ios/LooperKit/Tests/LooperKitTests/Phase4ParityTests.swift`), joins the
 * two, and writes `bench/results/parity-4a.md`.
 *
 *   npx tsx bench/parity.ts \
 *     --ondevice /path/to/ondevice-parity.log \
 *     [--base https://www.woollams.com/looper_router] \
 *     [--only douglas]
 *
 * The remote endpoint is rate limited to 20 requests/minute per IP, so the
 * calls below are spaced. `--ondevice` points at the captured output of
 *   LOOPER_LIVE_OVERPASS=1 swift test --filter Phase4ParityTests
 * (each `[parity-json] {…}` line is read; everything else is ignored). Omit it
 * to capture only the remote side.
 */
import { writeFileSync, readFileSync, mkdirSync, existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { compactness } from '../src/loops/geo.js'
import { countUTurns, sharedCorridorMetres } from '../src/loops/quality.js'

type LngLat = [number, number]

type Fixture = {
  id: string
  kind: 'ring' | 'waypoint'
  start: { lng: number; lat: number }
  targetKm: number
  waypoints: { lng: number; lat: number }[]
}

// The identical matrix the Swift harness runs. Keep the two in lockstep.
const DOUGLAS = { lng: -4.4816, lat: 54.1506 }
const PEEL = { lng: -4.6997, lat: 54.2246 }
const ONCHAN = { lng: -4.4569, lat: 54.1728 }

const FIXTURES: Fixture[] = [
  { id: 'douglas-3km', kind: 'ring', start: DOUGLAS, targetKm: 3, waypoints: [] },
  { id: 'douglas-4km', kind: 'ring', start: DOUGLAS, targetKm: 4, waypoints: [] },
  { id: 'douglas-5km', kind: 'ring', start: DOUGLAS, targetKm: 5, waypoints: [] },
  { id: 'douglas-8km', kind: 'ring', start: DOUGLAS, targetKm: 8, waypoints: [] },
  { id: 'peel-5km', kind: 'ring', start: PEEL, targetKm: 5, waypoints: [] },
  { id: 'onchan-5km', kind: 'ring', start: ONCHAN, targetKm: 5, waypoints: [] },
  { id: 'douglas-prom-4km', kind: 'ring', start: { lng: -4.4739, lat: 54.1517 }, targetKm: 4, waypoints: [] },
  { id: 'douglas-wp1-6km', kind: 'waypoint', start: DOUGLAS, targetKm: 6, waypoints: [{ lng: -4.4746, lat: 54.1566 }] },
  {
    id: 'douglas-wp2-8km', kind: 'waypoint', start: DOUGLAS, targetKm: 8,
    waypoints: [{ lng: -4.47, lat: 54.156 }, { lng: -4.49, lat: 54.16 }],
  },
]

const PEDESTRIAN_ROAD_CLASSES = new Set(['footway', 'path', 'pedestrian', 'steps'])

type EngineRow = {
  id: string
  engine: 'remote' | 'on-device'
  kind: string
  offered: number
  meanDistErrPct: number
  uTurns: number
  meanCompactness: number
  worstOverlapPct: number
  meanPavePct: number | null
  meanHopsPerKm: number | null
  gateRejections: Record<string, number>
  routes: LngLat[][]
  closedWalks?: number
  passedGate?: number
  raw?: unknown
}

const round = (x: number, dp = 2) => Math.round(x * 10 ** dp) / 10 ** dp

function ringMetrics(id: string, kind: string, targetMetres: number, payload: any): EngineRow {
  const routes: any[] = payload.routes ?? []
  const lines: LngLat[][] = routes.map(r => r.geometry.coordinates as LngLat[])
  const distErr = routes.length
    ? routes.reduce((s, r) => s + Math.abs(r.distanceMeters - targetMetres) / targetMetres, 0) / routes.length * 100
    : 0
  const uTurns = lines.reduce((s, l) => s + countUTurns(l), 0)
  const compact = lines.length ? lines.reduce((s, l) => s + compactness(l), 0) / lines.length : 0
  let worstOverlap = 0
  for (let i = 0; i < lines.length; i++) {
    for (let j = i + 1; j < lines.length; j++) {
      worstOverlap = Math.max(
        worstOverlap,
        sharedCorridorMetres(lines[i], lines[j]).fraction,
        sharedCorridorMetres(lines[j], lines[i]).fraction,
      )
    }
  }
  // Pavement share from the offered routes' own steps — the same basis the
  // on-device `RouteQuality.pavement` uses (a step is one graph edge).
  let onPave = 0
  let total = 0
  let hops = 0
  for (const route of routes) {
    const steps: any[] = route.steps ?? []
    let previousPed: boolean | null = null
    for (const step of steps) {
      const ped = PEDESTRIAN_ROAD_CLASSES.has(step.roadClass ?? '')
      total += step.distanceMeters ?? 0
      if (ped) onPave += step.distanceMeters ?? 0
      if (previousPed !== null && previousPed !== ped) hops++
      previousPed = ped
    }
  }
  const km = total / 1000
  const runHopsPerKm = payload.diagnostics?.metrics?.pavementHopsPerKm

  return {
    id, engine: 'remote', kind,
    offered: routes.length,
    meanDistErrPct: round(distErr),
    uTurns,
    meanCompactness: round(compact, 3),
    worstOverlapPct: round(worstOverlap * 100, 1),
    meanPavePct: total > 0 ? round((onPave / total) * 100, 1) : null,
    meanHopsPerKm: runHopsPerKm != null ? round(runHopsPerKm, 2) : (km > 0 ? round(hops / km, 2) : null),
    gateRejections: payload.diagnostics?.rejections ?? {},
    routes: lines.map(l => l.map(([lng, lat]) => [round(lng, 5), round(lat, 5)] as LngLat)),
    raw: payload.diagnostics,
  }
}

async function askRemote(base: string, fixture: Fixture): Promise<any> {
  const body: any = {
    start: fixture.start,
    mode: 'distance',
    distanceKm: fixture.targetKm,
    units: 'km',
    variation: 0,
  }
  if (fixture.waypoints.length) body.waypoints = fixture.waypoints
  const response = await fetch(`${base}/v1/loops`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
  if (!response.ok) throw new Error(`${response.status} ${(await response.text()).slice(0, 200)}`)
  return response.json()
}

function readOnDevice(path: string): Map<string, EngineRow> {
  const rows = new Map<string, EngineRow>()
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const marker = line.indexOf('[parity-json] ')
    if (marker < 0) continue
    let parsed: any
    try {
      parsed = JSON.parse(line.slice(marker + '[parity-json] '.length))
    } catch {
      process.stderr.write(`  (skipped an unparseable [parity-json] line)\n`)
      continue
    }
    rows.set(parsed.id, {
      id: parsed.id,
      engine: 'on-device',
      kind: parsed.kind,
      offered: parsed.offered,
      meanDistErrPct: parsed.meanDistErrPct,
      uTurns: parsed.uTurns,
      meanCompactness: parsed.meanCompactness,
      worstOverlapPct: parsed.worstOverlapPct,
      meanPavePct: parsed.meanPavePct ?? null,
      meanHopsPerKm: parsed.meanHopsPerKm ?? null,
      gateRejections: parsed.gateRejections ?? {},
      routes: parsed.routes ?? [],
      closedWalks: parsed.closedWalks,
      passedGate: parsed.passedGate,
    })
  }
  return rows
}

/** Best geometry overlap of any remote route with any on-device route. */
function sameWalkRate(remote: LngLat[][], device: LngLat[][]): number | null {
  if (!remote.length || !device.length) return null
  let best = 0
  for (const r of remote) {
    for (const d of device) {
      const f = Math.min(sharedCorridorMetres(r, d).fraction, sharedCorridorMetres(d, r).fraction)
      best = Math.max(best, f)
    }
  }
  return round(best * 100, 1)
}

function cell(a: number | null, b: number | null, dp = 1): string {
  const fmt = (x: number | null) => (x == null ? '—' : x.toFixed(dp))
  return `${fmt(a)} / ${fmt(b)}`
}

async function main() {
  const args = process.argv.slice(2)
  const base = args[args.indexOf('--base') + 1] && args.includes('--base')
    ? args[args.indexOf('--base') + 1]
    : 'https://www.woollams.com/looper_router'
  const onDevicePath = args.includes('--ondevice') ? args[args.indexOf('--ondevice') + 1] : null
  const only = args.includes('--only') ? args[args.indexOf('--only') + 1] : null

  const fixtures = only ? FIXTURES.filter(f => f.id.includes(only)) : FIXTURES
  const device = onDevicePath ? readOnDevice(onDevicePath) : new Map<string, EngineRow>()

  const here = dirname(fileURLToPath(import.meta.url))
  const resultsDir = join(here, 'results')
  if (!existsSync(resultsDir)) mkdirSync(resultsDir, { recursive: true })

  const remoteRows: EngineRow[] = []
  const rawRemote: Record<string, unknown> = {}
  for (const [i, fixture] of fixtures.entries()) {
    process.stderr.write(`  ${fixture.id} … `)
    try {
      const payload = await askRemote(base, fixture)
      const row = ringMetrics(fixture.id, fixture.kind, fixture.targetKm * 1000, payload)
      remoteRows.push(row)
      rawRemote[fixture.id] = payload
      process.stderr.write(`offered=${row.offered} pave=${row.meanPavePct}% hops/km=${row.meanHopsPerKm}\n`)
    } catch (error) {
      process.stderr.write(`FAILED ${(error as Error).message}\n`)
      remoteRows.push({
        id: fixture.id, engine: 'remote', kind: fixture.kind, offered: 0,
        meanDistErrPct: 0, uTurns: 0, meanCompactness: 0, worstOverlapPct: 0,
        meanPavePct: null, meanHopsPerKm: null, gateRejections: { error: 1 }, routes: [],
      })
    }
    if (i < fixtures.length - 1) await new Promise(r => setTimeout(r, 3200))
  }

  writeFileSync(join(resultsDir, 'parity-4a-remote.json'), JSON.stringify(rawRemote, null, 1))

  const lines: string[] = []
  lines.push('# Phase 4a — iOS ↔ remote parity measurement')
  lines.push('')
  lines.push(`Remote: \`${base}\`  ·  on-device: ${onDevicePath ?? '_(not captured)_'}`)
  lines.push(`Generated ${new Date().toISOString()}`)
  lines.push('')
  lines.push('Each cell is **remote / on-device**. `sameWalk%` is the best geometry')
  lines.push('overlap between any remote offer and any on-device offer for that fixture')
  lines.push('(≥ 95% ⇒ the two engines found the same walk).')
  lines.push('')
  lines.push('| fixture | offered | sameWalk% | dist err % | pave % | hops/km | u-turns | compactness | worst overlap % |')
  lines.push('|---|---|---|---|---|---|---|---|---|')
  for (const remote of remoteRows) {
    const d = device.get(remote.id)
    const sw = d ? sameWalkRate(remote.routes, d.routes) : null
    lines.push(
      `| ${remote.id} `
      + `| ${remote.offered} / ${d ? d.offered : '—'} `
      + `| ${sw == null ? '—' : sw.toFixed(1)} `
      + `| ${cell(remote.meanDistErrPct, d?.meanDistErrPct ?? null)} `
      + `| ${cell(remote.meanPavePct, d?.meanPavePct ?? null)} `
      + `| ${cell(remote.meanHopsPerKm, d?.meanHopsPerKm ?? null, 2)} `
      + `| ${remote.uTurns} / ${d ? d.uTurns : '—'} `
      + `| ${cell(remote.meanCompactness, d?.meanCompactness ?? null, 3)} `
      + `| ${cell(remote.worstOverlapPct, d?.worstOverlapPct ?? null)} |`,
    )
  }
  lines.push('')
  lines.push('## Per-route best match (offer-set agreement)')
  lines.push('')
  lines.push('For each remote offer, its best geometry overlap with any on-device')
  lines.push('offer, and vice versa. Three high numbers ⇒ the same three walks.')
  lines.push('')
  for (const remote of remoteRows) {
    const d = device.get(remote.id)
    if (!d || !remote.routes.length || !d.routes.length) continue
    const bestFor = (line: LngLat[], pool: LngLat[][]) =>
      Math.max(0, ...pool.map(p => Math.min(sharedCorridorMetres(line, p).fraction, sharedCorridorMetres(p, line).fraction)))
    const r2d = remote.routes.map(r => round(bestFor(r, d.routes) * 100, 0))
    const d2r = d.routes.map(x => round(bestFor(x, remote.routes) * 100, 0))
    lines.push(`- **${remote.id}** — remote→device best overlap: [${r2d.join(', ')}] %  ·  device→remote: [${d2r.join(', ')}] %`)
  }
  lines.push('')
  lines.push('## Candidate throughput')
  lines.push('')
  lines.push('Remote routes ~24 candidates and stops; on-device judges a pool of up')
  lines.push('to 256 (by design — no wire). Compare the **pass rate**, not the raw')
  lines.push('reject counts.')
  lines.push('')
  lines.push('| fixture | remote routed → passed (rate) | on-device closed → passed (rate) |')
  lines.push('|---|---|---|')
  for (const remote of remoteRows) {
    const dg: any = remote.raw ?? {}
    const rRouted = dg.routed ?? 0
    const rPassed = dg.passed ?? 0
    const d: any = device.get(remote.id)
    const rRate = rRouted ? `${Math.round((rPassed / rRouted) * 100)}%` : '—'
    const dCell = d && d.closedWalks
      ? `${d.closedWalks} → ${d.passedGate} (${Math.round((d.passedGate / d.closedWalks) * 100)}%)`
      : '—'
    lines.push(`| ${remote.id} | ${rRouted} → ${rPassed} (${rRate}) | ${dCell} |`)
  }
  lines.push('')
  lines.push('## Gate rejections (histogram, per fixture)')
  lines.push('')
  for (const remote of remoteRows) {
    const d = device.get(remote.id)
    lines.push(`- **${remote.id}** — remote: \`${JSON.stringify(remote.gateRejections)}\``
      + (d ? `  ·  on-device: \`${JSON.stringify(d.gateRejections)}\`` : ''))
  }
  lines.push('')
  lines.push('## Notes')
  lines.push('')
  lines.push('- pave% basis: remote from `steps[].roadClass`, on-device from')
  lines.push('  `diagnostics.offeredPavement` (both edge-level). hops/km: remote is the')
  lines.push('  run-level `diagnostics.metrics.pavementHopsPerKm`; on-device is the mean')
  lines.push('  of the offered routes. Treat hops/km as indicative, not exact.')
  lines.push('- The leg-routing ceiling section below is written by `bench/parity-legs.ts`')
  lines.push('  against a local GraphHopper (`docker start looper-graphhopper-iom-1`).')
  lines.push('- Analysis and the proposed 4b list: [`parity-4a-findings.md`](./parity-4a-findings.md).')

  const outPath = join(resultsDir, 'parity-4a.md')
  writeFileSync(outPath, lines.join('\n') + '\n')
  process.stderr.write(`\nWrote ${outPath}\n`)
}

main()
