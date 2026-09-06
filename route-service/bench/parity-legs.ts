/**
 * Phase 4a — the leg-routing ceiling.
 *
 * Routes a fixed set of ordinary town legs through a local GraphHopper (the
 * remote engine's own search + `looper_foot.json`) and joins the result with
 * the same legs put to `LocalLegRouter` on the Overpass graph by
 * `Phase4ParityTests.testEmitLegParityLines`. After C1 the two should be near
 * identical; whatever is left is the tie-break/snapping residual plus the C2
 * graph difference.
 *
 *   docker start looper-graphhopper-iom-1        # or `docker compose … up`
 *   npx tsx bench/parity-legs.ts --ondevice /path/to/ondevice-parity.log \
 *     [--gh http://localhost:8989]
 */
import { writeFileSync, readFileSync, mkdirSync, existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

type LngLat = [number, number]

const LEGS: { id: string; from: LngLat; to: LngLat }[] = [
  { id: 'douglas-seafront', from: [-4.4816, 54.1506], to: [-4.4693, 54.1602] },
  { id: 'douglas-inland', from: [-4.475, 54.155], to: [-4.46, 54.165] },
  { id: 'onchan', from: [-4.453, 54.172], to: [-4.44, 54.18] },
  { id: 'peel-control', from: [-4.702, 54.225], to: [-4.69, 54.232] },
]

const PEDESTRIAN = new Set(['footway', 'path', 'pedestrian', 'steps'])
const round = (x: number, dp = 2) => Math.round(x * 10 ** dp) / 10 ** dp

function haversine(a: LngLat, b: LngLat): number {
  const R = 6371000
  const toRad = (d: number) => (d * Math.PI) / 180
  const dLat = toRad(b[1] - a[1])
  const dLng = toRad(a[0] - b[0]) * -1
  const lat1 = toRad(a[1])
  const lat2 = toRad(b[1])
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2
  return 2 * R * Math.asin(Math.sqrt(h))
}

async function ghLeg(gh: string, from: LngLat, to: LngLat) {
  const response = await fetch(`${gh}/route`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      points: [from, to],
      profile: 'foot',
      'ch.disable': true,
      instructions: false,
      points_encoded: false,
      details: ['road_class'],
    }),
  })
  if (!response.ok) throw new Error(`${response.status} ${(await response.text()).slice(0, 200)}`)
  const path = ((await response.json()) as any).paths[0]
  const coords: LngLat[] = path.points.coordinates
  const intervals: [number, number, string][] = path.details.road_class
  let onPave = 0
  let total = 0
  let hops = 0
  let previousPed: boolean | null = null
  for (const [start, end, cls] of intervals) {
    const ped = PEDESTRIAN.has(cls)
    let segMetres = 0
    for (let i = start; i < end; i++) segMetres += haversine(coords[i], coords[i + 1])
    total += segMetres
    if (ped) onPave += segMetres
    if (previousPed !== null && previousPed !== ped) hops++
    previousPed = ped
  }
  return {
    metres: Math.round(path.distance),
    pavePct: total > 0 ? round((onPave / total) * 100, 1) : 0,
    hopsPerKm: total > 0 ? round(hops / (total / 1000), 2) : 0,
    coords: coords.map(([lng, lat]) => [round(lng, 5), round(lat, 5)] as LngLat),
  }
}

function readOnDeviceLegs(path: string): Map<string, any> {
  const rows = new Map<string, any>()
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const marker = line.indexOf('[parity-leg-json] ')
    if (marker < 0) continue
    const parsed = JSON.parse(line.slice(marker + '[parity-leg-json] '.length))
    rows.set(parsed.id, parsed)
  }
  return rows
}

// Very rough overlap: fraction of the shorter polyline whose vertices sit
// within 20 m of the other polyline. Enough to say "same corridor or not".
function overlapFraction(a: LngLat[], b: LngLat[]): number {
  const near = (p: LngLat, line: LngLat[]) => line.some(q => haversine(p, q) < 20)
  const [short, long] = a.length <= b.length ? [a, b] : [b, a]
  if (!short.length) return 0
  return short.filter(p => near(p, long)).length / short.length
}

async function main() {
  const args = process.argv.slice(2)
  const gh = args.includes('--gh') ? args[args.indexOf('--gh') + 1] : 'http://localhost:8989'
  const onDevicePath = args.includes('--ondevice') ? args[args.indexOf('--ondevice') + 1] : null
  const device = onDevicePath ? readOnDeviceLegs(onDevicePath) : new Map()

  const here = dirname(fileURLToPath(import.meta.url))
  const resultsDir = join(here, 'results')
  if (!existsSync(resultsDir)) mkdirSync(resultsDir, { recursive: true })

  const rows: any[] = []
  for (const leg of LEGS) {
    process.stderr.write(`  ${leg.id} … `)
    try {
      const g = await ghLeg(gh, leg.from, leg.to)
      const raw = device.get(leg.id)
      const d = raw && !raw.error ? raw : null
      const overlap = d ? round(overlapFraction(g.coords, d.coords) * 100, 1) : null
      if (raw?.error) process.stderr.write(`(device: ${raw.error}) `)
      rows.push({ id: leg.id, gh: g, device: d ?? null, overlapPct: overlap })
      process.stderr.write(`gh=${g.metres}m pave=${g.pavePct}%  device=${d ? d.metres + 'm pave=' + d.pavePct + '%' : '—'}  overlap=${overlap ?? '—'}%\n`)
    } catch (error) {
      process.stderr.write(`FAILED ${(error as Error).message}\n`)
      rows.push({ id: leg.id, error: (error as Error).message })
    }
  }

  writeFileSync(join(resultsDir, 'parity-4a-legs.json'), JSON.stringify(rows, null, 1))

  const lines: string[] = ['', '## Leg-routing ceiling (LocalLegRouter vs local GraphHopper)', '']
  lines.push(`GraphHopper: \`${gh}\` (profile \`foot\`, \`looper_foot.json\`)`)
  lines.push('')
  lines.push('| leg | metres (gh / device) | Δ% | pave % (gh / device) | hops/km (gh / device) | corridor overlap % |')
  lines.push('|---|---|---|---|---|---|')
  for (const r of rows) {
    if (r.error) { lines.push(`| ${r.id} | — | — | — | — | error: ${r.error} |`); continue }
    const d = r.device
    const deviceNote = !d && device.get(r.id)?.error ? ` _(device: ${device.get(r.id).error})_` : ''
    const delta = d ? round(((d.metres - r.gh.metres) / r.gh.metres) * 100, 1) : null
    lines.push(
      `| ${r.id} `
      + `| ${r.gh.metres} / ${d ? d.metres : '—'} `
      + `| ${delta == null ? '—' : (delta > 0 ? '+' : '') + delta} `
      + `| ${r.gh.pavePct} / ${d ? d.pavePct : '—'} `
      + `| ${r.gh.hopsPerKm} / ${d ? d.hopsPerKm : '—'} `
      + `| ${r.overlapPct ?? '—'}${deviceNote} |`,
    )
  }
  lines.push('')

  const report = join(resultsDir, 'parity-4a.md')
  const heading = '## Leg-routing ceiling'
  let head = ''
  if (existsSync(report)) {
    const current = readFileSync(report, 'utf8')
    const at = current.indexOf(heading)
    head = at >= 0 ? current.slice(0, at).replace(/\n+$/, '\n') : current.replace(/\n+$/, '\n')
  }
  writeFileSync(report, head + lines.join('\n') + '\n')
  process.stderr.write(`\nAppended leg-ceiling section to ${report}\n`)
}

main()
