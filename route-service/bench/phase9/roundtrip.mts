/**
 * P21 — GraphHopper's own round-trip algorithm.
 *
 * Phase 1's rule is that Looper does not reinvent what GraphHopper already
 * does. GraphHopper 11 ships `algorithm=round_trip`, so before any custom
 * cycle search is defended it has to be measured against the same fixtures and
 * judged by the same gate: distance accuracy, quality, retracing and whether
 * several seeds produce genuinely different walks.
 */
import { writeFileSync } from 'node:fs'
import { measureTraversals } from '../../src/loops/edges.js'
import { analyseRouteQuality } from '../../src/loops/quality.js'
import { initialBearing, mutualSharedFraction, selectDiverseRoutes } from '../../src/loops/diversity.js'
import { parseLeg } from '../../src/graphhopper.js'
import { median } from '../phase8/field.mjs'
import { FIXTURES } from '../phase2/fixtures.mjs'

const base = process.env.GH_ENGINE_URL ?? 'http://localhost:8989'
const SEEDS = Number(process.env.SEEDS ?? 12)
const NORMAL = [
  { name: 'douglas-5km', lat: 54.1506, lon: -4.4816, target: 5000 },
  { name: 'douglas-3km', lat: 54.1506, lon: -4.4816, target: 3000 },
  { name: 'peel-5km', lat: 54.2247, lon: -4.6947, target: 5000 },
  { name: 'onchan-5km', lat: 54.1745, lon: -4.4530, target: 5000 },
]
void FIXTURES

let calls = 0, wallMs = 0
const rows: Array<Record<string, unknown>> = []
const out: string[] = ['# Phase 9 P21 — GraphHopper round_trip\n']

for (const fixture of NORMAL) {
  const start: [number, number] = [fixture.lon, fixture.lat]
  const judged: Array<{ coordinates: [number, number][]; quality: { score: number }; bearing: number; traversals: ReturnType<typeof measureTraversals>; totalMetres: number; distance: number; report: ReturnType<typeof analyseRouteQuality> }> = []
  for (let seed = 1; seed <= SEEDS; seed++) {
    const url = `${base}/route?point=${fixture.lat},${fixture.lon}&profile=foot&algorithm=round_trip`
      + `&round_trip.distance=${fixture.target}&round_trip.seed=${seed}&ch.disable=true`
      + `&points_encoded=false&details=edge_id&details=street_name&details=road_class&instructions=true`
    calls++
    const began = performance.now()
    const response = await fetch(url)
    wallMs += performance.now() - began
    const payload = await response.json() as any
    if (!payload?.paths?.length) { rows.push({ fixture: fixture.name, seed, failed: true }); continue }
    const leg = parseLeg(payload)
    const traversals = measureTraversals(leg.coordinates, leg.edges)
    const report = analyseRouteQuality({
      traversals, coordinates: leg.coordinates, start,
      distanceMeters: leg.distanceMeters, durationSeconds: leg.durationSeconds,
      targetMetres: fixture.target, legDistances: [],
      maneuverSigns: leg.steps.map(step => step.sign),
    })
    judged.push({
      coordinates: leg.coordinates, quality: report.quality, bearing: initialBearing(leg.coordinates, start),
      traversals, totalMetres: leg.distanceMeters, distance: leg.distanceMeters, report,
    })
    rows.push({
      fixture: fixture.name, seed, distance: Math.round(leg.distanceMeters),
      errorPercent: Number((100 * (leg.distanceMeters / fixture.target - 1)).toFixed(1)),
      pass: report.pass, rejections: report.rejections, quality: report.quality.score,
      compactness: report.quality.compactness, repeated: report.quality.repeatedPercent, uTurns: report.quality.uTurnCount,
    })
  }
  const passes = judged.filter(entry => entry.report.pass)
  const chosen = selectDiverseRoutes(passes, 3)
  let worstOverlap = 0
  for (let i = 0; i < chosen.length; i++) for (let j = i + 1; j < chosen.length; j++) worstOverlap = Math.max(worstOverlap, mutualSharedFraction(chosen[i], chosen[j]))
  out.push(`## ${fixture.name}\n`)
  out.push(`seeds ${SEEDS}, routed ${judged.length}, gate passes ${passes.length}, offered ${chosen.length}, `
    + `median distance ${median(judged.map(entry => entry.distance)).toFixed(0)} m against ${fixture.target} m, `
    + `median |error| ${median(judged.map(entry => Math.abs(entry.distance - fixture.target))).toFixed(0)} m, `
    + `median quality ${median(judged.map(entry => entry.quality.score)).toFixed(1)}, `
    + `median compactness ${median(judged.map(entry => entry.report.quality.compactness)).toFixed(3)}, `
    + `median repeated ${median(judged.map(entry => entry.report.quality.repeatedPercent)).toFixed(2)}%, `
    + `worst overlap among offered ${(100 * worstOverlap).toFixed(1)}%\n`)
  const reasons = new Map<string, number>()
  for (const entry of judged) for (const reason of entry.report.rejections) reasons.set(reason, (reasons.get(reason) ?? 0) + 1)
  out.push('```text\nrejections: ' + ([...reasons].sort((a, b) => b[1] - a[1]).map(([r, n]) => `${r}=${n}`).join('  ') || 'none') + '\n```\n')
}

out.push(`\nGraphHopper calls ${calls}, wall ${wallMs.toFixed(0)} ms (${(wallMs / calls).toFixed(0)} ms/call)\n`)
out.push('| fixture | seed | distance | error | pass | quality | compactness | repeated % | u-turns | rejections |')
out.push('|---|---:|---:|---:|---|---:|---:|---:|---:|---|')
for (const row of rows) {
  if (row.failed) { out.push(`| ${row.fixture} | ${row.seed} | — | — | no path | | | | | |`); continue }
  out.push(`| ${row.fixture} | ${row.seed} | ${row.distance} | ${row.errorPercent}% | ${row.pass ? 'yes' : 'no'} | ${row.quality} | ${row.compactness} | ${row.repeated} | ${row.uTurns} | ${(row.rejections as string[]).join(', ') || '—'} |`)
}
writeFileSync(new URL('results/roundtrip.md', import.meta.url), out.join('\n') + '\n')
writeFileSync(new URL('results/roundtrip.json', import.meta.url), JSON.stringify({ calls, wallMs, rows }, null, 2) + '\n')
console.log(out.join('\n').slice(0, 3000))
