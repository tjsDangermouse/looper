/**
 * C2: route home from every traced intermediate endpoint.  This is deliberately
 * an offline oracle, never part of candidate generation.  It establishes the
 * ceiling before a production estimator or a one-probe strategy is retained.
 *
 *   CORPUS=corpus-C0 npx tsx bench/phase4/oracle.mts
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { FIXTURES } from '../phase2/fixtures.mjs'
import { buildRouteBody, parseLeg } from '../../src/graphhopper.js'

const corpus = process.env.CORPUS ?? 'corpus-C0'
const ghUrl = process.env.GH_URL ?? 'http://localhost:8991'
const dir = new URL(`${corpus}/`, import.meta.url)
const starts = new Map(FIXTURES.map(fixture => [fixture.name, [fixture.body.start.lng, fixture.body.start.lat] as [number, number]]))
const rows: Array<Record<string, unknown>> = []

for (const fixture of FIXTURES) {
  const lines = readFileSync(new URL(`${fixture.name}.jsonl`, dir), 'utf8').trim().split('\n')
  for (const line of lines) {
    if (!line) continue
    const record = JSON.parse(line)
    if (record.event !== 'decision' || record.kind !== 'leg-result' || record.legIndex >= record.cornerCount) continue
    if (typeof record.endpointLng !== 'number' || typeof record.endpointLat !== 'number') continue
    const start = starts.get(fixture.name)!
    const response = await fetch(`${ghUrl}/route`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      // Plain is intentional: this measures the cheap, best-possible direct
      // closure oracle. C5 separately measures a real avoided closure probe.
      body: JSON.stringify(buildRouteBody([[record.endpointLng, record.endpointLat], start], { profile: 'foot' })),
    })
    if (!response.ok) {
      rows.push({ fixture: fixture.name, candidateId: record.candidateId, legIndex: record.legIndex, error: response.status })
      continue
    }
    const leg = parseLeg(await response.json())
    const used = Number(record.distanceUsedAfterLeg)
    const target = Number(record.targetDistance)
    rows.push({
      fixture: fixture.name, candidateId: record.candidateId, cornerCount: record.cornerCount, legIndex: record.legIndex,
      distanceUsed: used, targetDistance: target, oracleCloseDistance: Math.round(leg.distanceMeters),
      totalIfClosedNow: Math.round(used + leg.distanceMeters),
      errorIfClosedNow: Math.round(used + leg.distanceMeters - target),
    })
  }
}

writeFileSync(new URL('oracle-C2.json', dir), JSON.stringify(rows, null, 2) + '\n')
const valid = rows.filter(row => typeof row.oracleCloseDistance === 'number')
console.log(`C2 wrote ${valid.length} direct-home oracle rows to ${new URL('oracle-C2.json', dir).pathname}`)
