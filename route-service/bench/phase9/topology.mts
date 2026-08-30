/**
 * P3 — the topology of the walks Looper already accepts.
 *
 * Reads the Phase 3B trace corpus and describes each completed candidate in
 * graph terms rather than geometric ones: how many distinct physical edges it
 * used, how much ground it repeated, how long the shared stem at the door is,
 * and how much of the walk is the cycle proper. Phase 9's search has to aim at
 * whatever pattern the accepted walks actually exhibit, so this is measured
 * before anything is designed.
 */
import { readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { compactness as isoperimetric, boundingBoxSides, type LngLat } from '../../src/loops/geo.js'
import { median, mean, percentile } from '../phase8/field.mjs'
import { EDGE_START_IGNORE_METRES } from '../../src/loops/edges.js'

const GATE_DOORSTEP_METRES = EDGE_START_IGNORE_METRES

const label = process.argv[2] ?? 'P9'
const dir = new URL(`corpus-${label}/`, import.meta.url)
const NORMAL = ['douglas-5km', 'douglas-3km', 'peel-5km', 'onchan-5km']

type Pass = [number, number]
export type Walk = {
  fixture: string; candidateId: string; outcome: string; rejections: string[]
  distance: number; target: number; quality: number; uTurns: number; repeatedPercent: number
  passes: Pass[]; coordinates: LngLat[]; offered: boolean
}

/** Edge-level topology of one walk. Everything here is physical-edge, not geometric. */
export function topology(passes: Pass[]) {
  const total = passes.reduce((sum, [, m]) => sum + m, 0)
  const byEdge = new Map<number, { count: number; metres: number; first: number }>()
  for (const [id, metres] of passes) {
    const seen = byEdge.get(id)
    if (seen) { seen.count++; seen.metres += metres } else byEdge.set(id, { count: 1, metres, first: metres })
  }
  const repeatedMetres = [...byEdge.values()].reduce((sum, e) => sum + (e.metres - e.first), 0)
  // The same rule the acceptance gate itself applies in `edgeRepeatReport`:
  // a pass is charged only for the ground it covers twice, and the doorstep
  // at either end is free. Direction is not available from the trace, so the
  // reverse premium is not reproduced — this is the unweighted figure.
  let gateRepeated = 0, along = 0
  const covered = new Map<number, number>()
  for (const [id, metres] of passes) {
    along += metres / 2
    const seen = covered.get(id) ?? 0
    const doorstep = along < GATE_DOORSTEP_METRES || along > total - GATE_DOORSTEP_METRES
    if (!doorstep) gateRepeated += Math.min(metres, seen)
    if (metres > seen) covered.set(id, metres)
    along += metres / 2
  }
  // The shared access stem: the leading run of edges the walk retraces, in
  // reverse, on its way back in. This is the `stem + cycle + stem` shape P2
  // asks about, read straight off the walk rather than assumed.
  let stemEdges = 0
  while (stemEdges < passes.length - 1 - stemEdges && passes[stemEdges][0] === passes[passes.length - 1 - stemEdges][0]) stemEdges++
  let stemMetres = 0
  for (let i = 0; i < stemEdges; i++) stemMetres += passes[i][1]
  return {
    passes: passes.length, uniqueEdges: byEdge.size, totalMetres: total,
    repeatedMetres, repeatedFraction: total > 0 ? repeatedMetres / total : 0,
    gateRepeatedMetres: gateRepeated, gateRepeatedFraction: total > 0 ? gateRepeated / total : 0,
    maxReuse: Math.max(0, ...[...byEdge.values()].map(e => e.count)),
    reusedEdges: [...byEdge.values()].filter(e => e.count > 1).length,
    stemEdges, stemMetres, stemFraction: total > 0 ? stemMetres / total : 0,
    coreMetres: total - 2 * stemMetres,
  }
}

// ------------------------------------------------------------------ loading

export function loadWalks(dir: URL, only?: string[]): Walk[] {
  const offered = JSON.parse(readFileSync(new URL('offered.json', dir), 'utf8')) as Array<{ fixture: string; routes: Array<{ distanceMeters: number }> }>
  const walks: Walk[] = []
  for (const file of readdirSync(dir).filter(name => name.endsWith('.jsonl'))) {
    const fixture = file.replace('.jsonl', '')
    if (only && !only.includes(fixture)) continue
    const finals = new Map<string, LngLat[]>()
    const rows: Walk[] = []
    for (const line of readFileSync(new URL(file, dir), 'utf8').split('\n')) {
      if (!line) continue
      const event = JSON.parse(line)
      if (event.kind === 'candidate-finalize' && event.geometryAfterTrim) finals.set(event.candidateId, event.geometryAfterTrim)
      if (event.kind !== 'candidate' || !event.edgePasses) continue
      rows.push({
        fixture, candidateId: event.candidateId, outcome: event.outcome, rejections: event.rejections ?? [],
        distance: event.distance, target: event.target, quality: event.quality, uTurns: event.uTurns,
        repeatedPercent: event.repeatedPercent, passes: event.edgePasses, coordinates: [], offered: false,
      })
    }
    // A candidate is only traced once, so its final geometry is the one the
    // finalize line carries; the quality gate judged exactly this line.
    for (const walk of rows) walk.coordinates = finals.get(walk.candidateId) ?? []
    // The offered walks are those whose distance the service returned. Matching
    // on the rounded metre is exact here: no two passing candidates in the
    // corpus share one.
    const wanted = new Set((offered.find(entry => entry.fixture === fixture)?.routes ?? []).map(route => Math.round(route.distanceMeters)))
    for (const walk of rows) if (walk.outcome === 'passed' && wanted.has(Math.round(walk.distance))) walk.offered = true
    walks.push(...rows)
  }
  return walks
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const walks = loadWalks(dir, NORMAL)
  const rows = walks.map(walk => {
    const shape = walk.coordinates.length > 3 ? isoperimetric(walk.coordinates) : NaN
    const sides = walk.coordinates.length > 3 ? boundingBoxSides(walk.coordinates) : { longMetres: NaN, shortMetres: NaN }
    return { ...walk, ...topology(walk.passes), compactness: shape, bboxRatio: sides.longMetres / sides.shortMetres }
  })

  const groups: Array<[string, typeof rows]> = [
    ['offered', rows.filter(r => r.offered)],
    ['passed', rows.filter(r => r.outcome === 'passed')],
    ['rejected', rows.filter(r => r.outcome !== 'passed')],
    ['rejected: shapeless', rows.filter(r => r.rejections.includes('shapeless'))],
    ['rejected: out-and-back-spur', rows.filter(r => r.rejections.includes('out-and-back-spur'))],
    ['rejected: distance', rows.filter(r => r.rejections.includes('distance'))],
  ]
  const stat = (values: number[]) => values.filter(Number.isFinite)
  const line = (name: string, set: typeof rows) => {
    if (!set.length) return `| ${name} | 0 | — | — | — | — | — | — | — | — |`
    const f = (values: number[], digits = 0, scale = 1) => (median(stat(values)) * scale).toFixed(digits)
    return `| ${name} | ${set.length} | ${f(set.map(r => r.uniqueEdges))} | ${f(set.map(r => r.passes))} `
      + `| ${f(set.map(r => r.repeatedMetres))} | ${f(set.map(r => r.repeatedFraction), 2, 100)}% `
      + `| ${f(set.map(r => r.gateRepeatedFraction), 2, 100)}% `
      + `| ${f(set.map(r => r.maxReuse), 1)} | ${f(set.map(r => r.stemMetres))} | ${f(set.map(r => r.stemFraction), 2, 100)}% `
      + `| ${f(set.map(r => r.coreMetres))} | ${f(set.map(r => r.compactness), 3)} |`
  }

  const out: string[] = []
  out.push('# Phase 9 P3 — topology of Phase 3B walks\n')
  out.push('Medians across the four normal fixtures.\n')
  out.push('| group | walks | unique edges | edge passes | repeated m | repeated % | gate repeated % | max reuse | stem m | stem % | core m | compactness |')
  out.push('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
  for (const [name, set] of groups) out.push(line(name, set))

  out.push('\n## Per fixture, offered walks only\n')
  out.push('| fixture | walks | distance | unique edges | repeated m | repeated % | max reuse | stem m | stem % | core m | compactness | u-turns |')
  out.push('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
  for (const fixture of NORMAL) {
    const set = rows.filter(r => r.offered && r.fixture === fixture)
    if (!set.length) { out.push(`| ${fixture} | 0 | | | | | | | | | | |`); continue }
    const f = (values: number[], digits = 0, scale = 1) => (median(stat(values)) * scale).toFixed(digits)
    out.push(`| ${fixture} | ${set.length} | ${f(set.map(r => r.totalMetres))} | ${f(set.map(r => r.uniqueEdges))} `
      + `| ${f(set.map(r => r.repeatedMetres))} | ${f(set.map(r => r.repeatedFraction), 2, 100)}% | ${f(set.map(r => r.maxReuse), 1)} `
      + `| ${f(set.map(r => r.stemMetres))} | ${f(set.map(r => r.stemFraction), 2, 100)}% | ${f(set.map(r => r.coreMetres))} `
      + `| ${f(set.map(r => r.compactness), 3)} | ${f(set.map(r => r.uTurns), 1)} |`)
  }

  const offeredRows = rows.filter(r => r.offered)
  out.push('\n## Distribution over offered walks\n')
  out.push('```text')
  for (const [name, values] of [
    ['unique edges', offeredRows.map(r => r.uniqueEdges)],
    ['edge passes', offeredRows.map(r => r.passes)],
    ['repeated metres', offeredRows.map(r => r.repeatedMetres)],
    ['repeated fraction %', offeredRows.map(r => r.repeatedFraction * 100)],
    ['gate repeated %', offeredRows.map(r => r.gateRepeatedFraction * 100)],
    ['max edge reuse', offeredRows.map(r => r.maxReuse)],
    ['reused edges', offeredRows.map(r => r.reusedEdges)],
    ['stem edges', offeredRows.map(r => r.stemEdges)],
    ['stem metres', offeredRows.map(r => r.stemMetres)],
    ['stem fraction %', offeredRows.map(r => r.stemFraction * 100)],
    ['compactness', offeredRows.map(r => r.compactness)],
    ['bbox ratio', offeredRows.map(r => r.bboxRatio)],
  ] as Array<[string, number[]]>) {
    const clean = stat(values)
    out.push(`${name.padEnd(22)} min ${percentile(clean, 0.001).toFixed(3).padStart(9)}  p25 ${percentile(clean, 0.25).toFixed(3).padStart(9)}  median ${median(clean).toFixed(3).padStart(9)}  p75 ${percentile(clean, 0.75).toFixed(3).padStart(9)}  max ${percentile(clean, 1).toFixed(3).padStart(9)}  mean ${mean(clean).toFixed(3).padStart(9)}`)
  }
  out.push('```')

  const text = out.join('\n') + '\n'
  writeFileSync(new URL(`results/topology-${label}.md`, import.meta.url), text)
  writeFileSync(new URL(`results/topology-${label}.json`, import.meta.url), JSON.stringify(rows.map(row => ({ ...row, coordinates: undefined, passes: undefined })), null, 2) + '\n')
  console.log(text)
}
