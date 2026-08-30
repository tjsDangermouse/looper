/**
 * P18, P19 — how many qualifying walks the ground actually holds.
 *
 * Phase 8 could not distinguish "the search did not find three walks" from
 * "three walks do not exist", and its Peel result was read as the second. This
 * is the check: a deliberately expensive search, far wider than any request
 * would pay for, followed by a maximal mutually-diverse selection under the
 * production rule. Analysis only — nothing here is a proposed operating point.
 *
 * P19 then re-counts the same walk set under one relaxed constraint at a time,
 * so that if a fixture is short of three the binding constraint is named
 * rather than guessed. No production threshold is changed.
 */
import { writeFileSync } from 'node:fs'
import { MAX_SHARED_FRACTION, bearingOctant, mutualSharedFraction } from '../../src/loops/diversity.js'
import { MAX_DISTANCE_ERROR } from '../../src/loops/quality.js'
import { STARTS } from '../phase8/field.mjs'
import { loadSubgraphs, buildSearchGraph } from './graph.mjs'
import { beamSearch, objectiveFor, rootOf } from './search.mjs'
import { judge, type Judged } from './walk.mjs'

const BEAM = Number(process.env.ORACLE_BEAM ?? 2000)
const BAND = Number(process.env.ORACLE_BAND ?? 50)
const PER_NODE = Number(process.env.ORACLE_PER_NODE ?? 6)

const selectable = (entry: Judged) => ({
  coordinates: entry.assembled.coordinates, quality: entry.report.quality, bearing: entry.bearing,
  traversals: entry.traversals, totalMetres: entry.assembled.graphMetres,
})

/** Greedy maximal set no two of which share more than `maxShared` of ground. */
function maximalDiverse(entries: Judged[], maxShared = MAX_SHARED_FRACTION): Judged[] {
  const ranked = [...entries].sort((a, b) => b.report.quality.score - a.report.quality.score)
  const chosen: Judged[] = []
  for (const entry of ranked) {
    if (chosen.some(taken => mutualSharedFraction(selectable(entry), selectable(taken)) > maxShared)) continue
    chosen.push(entry)
  }
  return chosen
}

const out: string[] = ['# Phase 9 P18/P19 — oracle route availability\n',
  `Beam ${BEAM}, band ${BAND} m, per-node cap ${PER_NODE}, diversity quota on, no early stop.\n`]
const summary: Array<Record<string, unknown>> = []

for (const raw of loadSubgraphs(new URL('subgraphs.json', import.meta.url))) {
  const graph = buildSearchGraph(raw)
  const { root } = rootOf(graph)
  const start = STARTS.get(graph.name)!
  const began = performance.now()
  const { walks, stats } = beamSearch(graph, {
    objective: objectiveFor(graph.targetMetres), budget: Infinity,
    beam: BEAM, band: BAND, perNode: PER_NODE, perFamily: 1, minCompactness: 0,
  })
  const judged = walks.map(walk => judge(graph, walk, root, start))
  const passes = judged.filter(entry => entry.report.pass)
  const diverse = maximalDiverse(passes)
  const octants = new Set(passes.map(entry => bearingOctant(entry.bearing)))

  // P19: the same closed walks, counted under one loosened rule at a time.
  const relaxations: Array<[string, (entry: Judged) => boolean]> = [
    ['current gate', entry => entry.report.pass],
    ['distance band ±18% instead of ±12%', entry => !entry.report.rejections.some(reason => reason !== 'distance')
      && Math.abs(entry.assembled.graphMetres - graph.targetMetres) / graph.targetMetres <= 0.18],
    ['compactness floor 0.15 instead of 0.20', entry => !entry.report.rejections.some(reason => reason !== 'shapeless')
      && entry.report.quality.compactness >= 0.15],
    ['u-turns allowed up to 2 instead of 1', entry => !entry.report.rejections.some(reason => reason !== 'u-turns')
      && entry.report.quality.uTurnCount <= 2],
    ['shape rules set aside (essentials only)', entry => entry.report.passesEssentials],
  ]

  out.push(`## ${graph.name}\n`)
  out.push(`closed walks ${walks.length}, gate passes ${passes.length}, octants reached ${[...octants].sort().join(',') || 'none'}, `
    + `search ${stats.wallMs.toFixed(0)} ms, states expanded ${stats.expanded}, peak heap ${(stats.peakHeapBytes / 1e6).toFixed(0)} MB, `
    + `judge ${(performance.now() - began - stats.wallMs).toFixed(0)} ms\n`)
  out.push(`**Mutually diverse qualifying walks available: ${diverse.length}**\n`)
  if (diverse.length) {
    out.push('| # | distance | error | quality | compactness | repeated % | u-turns | octant | worst overlap with the others |')
    out.push('|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
    diverse.slice(0, 12).forEach((entry, index) => {
      const worst = Math.max(0, ...diverse.filter(other => other !== entry).map(other => mutualSharedFraction(selectable(entry), selectable(other))))
      out.push(`| ${index + 1} | ${entry.assembled.graphMetres.toFixed(0)} m | ${(100 * (entry.assembled.graphMetres / graph.targetMetres - 1)).toFixed(1)}% `
        + `| ${entry.report.quality.score} | ${entry.report.quality.compactness} | ${entry.report.quality.repeatedPercent} `
        + `| ${entry.report.quality.uTurnCount} | ${bearingOctant(entry.bearing)} | ${(100 * worst).toFixed(1)}% |`)
    })
    out.push('')
  }
  out.push('| constraint | qualifying walks | mutually diverse |')
  out.push('|---|---:|---:|')
  for (const [name, test] of relaxations) {
    const set = judged.filter(test)
    out.push(`| ${name} | ${set.length} | ${maximalDiverse(set).length} |`)
  }
  out.push('')
  summary.push({ fixture: graph.name, walks: walks.length, passes: passes.length, diverse: diverse.length,
    searchMs: stats.wallMs, expanded: stats.expanded, peakHeapMb: stats.peakHeapBytes / 1e6 })
}

out.push('## Summary\n')
out.push('| fixture | closed walks | gate passes | mutually diverse qualifying walks | search ms |')
out.push('|---|---:|---:|---:|---:|')
for (const row of summary) out.push(`| ${row.fixture} | ${row.walks} | ${row.passes} | ${row.diverse} | ${(row.searchMs as number).toFixed(0)} |`)
out.push(`\nAcceptance band ±${(100 * MAX_DISTANCE_ERROR).toFixed(0)}%, diversity bar ${(100 * MAX_SHARED_FRACTION).toFixed(0)}% shared ground.\n`)
writeFileSync(new URL('results/oracle.md', import.meta.url), out.join('\n') + '\n')
writeFileSync(new URL('results/oracle.json', import.meta.url), JSON.stringify(summary, null, 2) + '\n')
console.log(out.join('\n'))
