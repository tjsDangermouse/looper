/**
 * P7, P14, P15 — what the search costs and which knob buys what.
 *
 * Beam width, band width and the per-node dominance cap are swept together
 * with the diversity quota, because they trade against each other: a wider
 * beam buys nothing if one junction is allowed to fill it. Memory is the heap
 * the search actually holds, measured around a forced collection rather than
 * inferred from the state count.
 */
import { writeFileSync } from 'node:fs'
import { selectDiverseRoutes } from '../../src/loops/diversity.js'
import { STARTS, mean } from '../phase8/field.mjs'
import { loadSubgraphs, buildSearchGraph } from './graph.mjs'
import { beamSearch, objectiveFor, rootOf } from './search.mjs'
import { judge } from './walk.mjs'

const graphs = loadSubgraphs(new URL('subgraphs.json', import.meta.url)).map(buildSearchGraph)
const heap = () => { globalThis.gc?.(); return process.memoryUsage().heapUsed }

type Row = { beam: number; band: number; perNode: number; quota: boolean; fixture: string
  found: number; passes: number; offered: number; searchMs: number; expanded: number
  generated: number; peak: number; store: number; heapMb: number; quality: number; error: number }

const rows: Row[] = []
const seen = new Set<string>()
const run = (beam: number, band: number, perNode: number, quota: boolean) => {
  // A configuration appears in more than one sweep; run and count it once.
  const key = `${beam}/${band}/${perNode}/${quota}`
  if (seen.has(key)) return
  seen.add(key)
  for (const graph of graphs) {
    const { root } = rootOf(graph)
    const before = heap()
    const { walks, stats } = beamSearch(graph, {
      objective: objectiveFor(graph.targetMetres), budget: Infinity,
      beam, band, perNode, perFamily: quota ? 1 : 0, minCompactness: 0.2,
    })
    const settled = heap()
    void settled
    const judged = walks.map(walk => judge(graph, walk, root, STARTS.get(graph.name)!))
    const passes = judged.filter(entry => entry.report.pass)
    const offered = selectDiverseRoutes(passes.map(entry => ({ ...entry, coordinates: entry.assembled.coordinates, quality: entry.report.quality, totalMetres: entry.assembled.graphMetres })), 3)
    rows.push({
      beam, band, perNode, quota, fixture: graph.name, found: walks.length, passes: passes.length,
      offered: offered.length, searchMs: stats.wallMs, expanded: stats.expanded, generated: stats.generated,
      peak: stats.peakFrontier, store: stats.storeSize,
      // Peak heap in use while the search runs, sampled per band, against the
      // collected baseline before it started.
      heapMb: Math.max(0, stats.peakHeapBytes - before) / 1e6,
      quality: offered.length ? mean(offered.map(entry => entry.report.quality.score)) : 0,
      error: offered.length ? mean(offered.map(entry => Math.abs(entry.assembled.graphMetres - graph.targetMetres))) : NaN,
    })
  }
}

for (const beam of [50, 100, 200, 300, 600, 1200]) run(beam, 100, 3, true)
for (const band of [50, 100, 200, 400]) run(300, band, 3, true)
for (const perNode of [1, 2, 3, 6, 12]) run(300, 100, perNode, true)
run(300, 100, 3, false)

const out: string[] = ['# Phase 9 P7/P14/P15 — search cost and dominance sweep\n']
const table = (title: string, filter: (row: Row) => boolean, key: (row: Row) => string) => {
  out.push(`## ${title}\n`)
  out.push('| setting | offered / 12 | closed walks | gate passes | states expanded | states generated | peak band | store entries | search ms (ring) | worst fixture ms | heap MB (max) | mean quality | mean abs error |')
  out.push('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
  const groups = new Map<string, Row[]>()
  for (const row of rows.filter(filter)) {
    const name = key(row)
    const group = groups.get(name)
    if (group) group.push(row); else groups.set(name, [row])
  }
  for (const [name, set] of groups) {
    const offeredSet = set.filter(row => row.offered > 0)
    out.push(`| ${name} | ${set.reduce((sum, row) => sum + row.offered, 0)} | ${set.reduce((sum, row) => sum + row.found, 0)} `
      + `| ${set.reduce((sum, row) => sum + row.passes, 0)} | ${set.reduce((sum, row) => sum + row.expanded, 0)} `
      + `| ${set.reduce((sum, row) => sum + row.generated, 0)} | ${Math.max(...set.map(row => row.peak))} `
      + `| ${set.reduce((sum, row) => sum + row.store, 0)} | ${set.reduce((sum, row) => sum + row.searchMs, 0).toFixed(0)} `
      + `| ${Math.max(...set.map(row => row.searchMs)).toFixed(0)} | ${Math.max(...set.map(row => row.heapMb)).toFixed(1)} `
      + `| ${offeredSet.length ? mean(offeredSet.map(row => row.quality)).toFixed(1) : '—'} `
      + `| ${offeredSet.length ? mean(offeredSet.map(row => row.error)).toFixed(0) + ' m' : '—'} |`)
  }
  out.push('')
}
table('Beam width (band 100 m, per-node 3, quota on)', row => row.band === 100 && row.perNode === 3 && row.quota, row => `beam ${row.beam}`)
table('Band width (beam 300, per-node 3, quota on)', row => row.beam === 300 && row.perNode === 3 && row.quota, row => `band ${row.band} m`)
table('Per-node dominance cap (beam 300, band 100 m, quota on)', row => row.beam === 300 && row.band === 100 && row.quota, row => `per-node ${row.perNode}`)
table('Diversity quota (beam 300, band 100 m, per-node 3)', row => row.beam === 300 && row.band === 100 && row.perNode === 3, row => row.quota ? 'quota on' : 'quota off')

out.push('## Per fixture, the retained operating point\n')
out.push('| fixture | closed walks | gate passes | offered | states expanded | peak band | store entries | heap MB | search ms |')
out.push('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
for (const row of rows.filter(row => row.beam === 300 && row.band === 100 && row.perNode === 3 && row.quota)) {
  out.push(`| ${row.fixture} | ${row.found} | ${row.passes} | ${row.offered} | ${row.expanded} | ${row.peak} | ${row.store} | ${row.heapMb.toFixed(1)} | ${row.searchMs.toFixed(0)} |`)
}
writeFileSync(new URL('results/sweep.md', import.meta.url), out.join('\n') + '\n')
writeFileSync(new URL('results/sweep.json', import.meta.url), JSON.stringify(rows, null, 2) + '\n')
console.log(out.join('\n'))
