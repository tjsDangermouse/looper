/**
 * Phase 9 headline analysis.
 *
 * Runs the search prototypes over the exported request-local graphs, judges
 * every closed walk with Looper's own acceptance gate, selects three with
 * Looper's own diversity rule, and prices the whole thing. Nothing here routes
 * except where the materialisation study does, and that is priced separately.
 */
import { writeFileSync } from 'node:fs'
import { mutualSharedFraction, selectDiverseRoutes } from '../../src/loops/diversity.js'
import { MAX_DISTANCE_ERROR } from '../../src/loops/quality.js'
import { STARTS, median, mean } from '../phase8/field.mjs'
import { loadSubgraphs, buildSearchGraph, type SearchGraph } from './graph.mjs'
import { beamSearch, coreEntries, depthFirstSearch, meetSearch, objectiveFor, rootOf, type SearchStats, type Walk } from './search.mjs'
import { judge, type Judged } from './walk.mjs'

const NORMAL = ['douglas-5km', 'douglas-3km', 'peel-5km', 'onchan-5km']
const BEAM = Number(process.env.BEAM ?? 300)
const BAND = Number(process.env.BAND ?? 100)
const PER_NODE = Number(process.env.PER_NODE ?? 3)
const PER_FAMILY = Number(process.env.PER_FAMILY ?? 1)
const WANTED = Number(process.env.WANTED ?? Number.POSITIVE_INFINITY)
const LABEL = process.env.LABEL ?? 'offline'

const graphs = loadSubgraphs(new URL('subgraphs.json', import.meta.url))
  .filter(raw => NORMAL.includes(raw.name))
  .map(buildSearchGraph)

const zero: SearchStats = { generated: 0, expanded: 0, prunedDistance: 0, prunedReuse: 0, prunedBeam: 0, prunedDominated: 0, peakFrontier: 0, completed: 0, wallMs: 0, storeSize: 0, peakHeapBytes: 0 }
const add = (a: SearchStats, b: SearchStats): SearchStats => ({
  generated: a.generated + b.generated, expanded: a.expanded + b.expanded,
  prunedDistance: a.prunedDistance + b.prunedDistance, prunedReuse: a.prunedReuse + b.prunedReuse,
  prunedBeam: a.prunedBeam + b.prunedBeam, prunedDominated: a.prunedDominated + b.prunedDominated,
  peakFrontier: Math.max(a.peakFrontier, b.peakFrontier), completed: a.completed + b.completed,
  wallMs: a.wallMs + b.wallMs, storeSize: a.storeSize + b.storeSize,
  peakHeapBytes: Math.max(a.peakHeapBytes, b.peakHeapBytes),
})

type Run = { walks: Walk[]; stats: SearchStats; root: number }

const runners: Record<string, (graph: SearchGraph) => Run> = {
  /** S1 — exhaustive depth-first, bounded only by the two exact prunes. */
  S1: graph => {
    const { root } = rootOf(graph)
    const result = depthFirstSearch(graph, { objective: objectiveFor(graph.targetMetres), budget: 2_000_000, wanted: WANTED, minCompactness: 0.2 })
    return { ...result, root }
  },
  /** S2 — beam over distance bands, the headline prototype. */
  S2: graph => {
    const { root } = rootOf(graph)
    const result = beamSearch(graph, {
      objective: objectiveFor(graph.targetMetres), budget: Infinity,
      beam: BEAM, band: BAND, perNode: PER_NODE, perFamily: PER_FAMILY, wanted: WANTED, minCompactness: 0.2,
    })
    return { ...result, root }
  },
  /** S3 — the same beam, entered at every 2-core node inside the doorstep. */
  S3: graph => {
    const entries = coreEntries(graph, 75)
    let stats = { ...zero }
    const walks: Walk[] = []
    let root = rootOf(graph).root
    for (const entry of entries.slice(0, 4)) {
      const result = beamSearch(graph, {
        objective: objectiveFor(graph.targetMetres), budget: Infinity, root: entry.root, stemMetres: entry.stemMetres,
        beam: Math.max(60, Math.floor(BEAM / Math.min(4, entries.length))), band: BAND, perNode: PER_NODE,
        perFamily: PER_FAMILY, wanted: WANTED, minCompactness: 0.2,
      })
      stats = add(stats, result.stats)
      if (!walks.length && result.walks.length) root = entry.root
      // Only walks from the entry that produced them can be assembled, so the
      // per-entry results are judged separately and merged afterwards.
      for (const walk of result.walks) walks.push(Object.assign(walk, { entry: entry.root }) as Walk & { entry: number })
    }
    return { walks, stats, root }
  },
  /** S4 — two half-walks meeting on a node, joined where they share no edge. */
  S4: graph => {
    const { root } = rootOf(graph)
    const result = meetSearch(graph, {
      objective: objectiveFor(graph.targetMetres), budget: Infinity,
      // A meeting needs several partial walks on the same node, so the
      // per-node cap that keeps the single-frontier beam honest would starve
      // it. Both caps are widened rather than the prototype being handicapped.
      beam: BEAM, band: BAND, perNode: 8, poolPerNode: 12, wanted: WANTED, minCompactness: 0.2,
    })
    return { ...result, root }
  },
}

type FixtureResult = {
  fixture: string; prototype: string; stats: SearchStats
  found: number; passes: number; offered: Judged[]
  judgeMs: number; buildMs: number; exportMs: number
  rejections: Map<string, number>
}

const results: FixtureResult[] = []
for (const graph of graphs) {
  const start = STARTS.get(graph.name)!
  for (const [prototype, run] of Object.entries(runners)) {
    const began = performance.now()
    const { walks, stats, root } = run(graph)
    const searched = performance.now()
    const judged = walks.map(walk => judge(graph, walk, (walk as Walk & { entry?: number }).entry ?? root, start))
    const passes = judged.filter(entry => entry.report.pass)
    const rejections = new Map<string, number>()
    for (const entry of judged) for (const reason of entry.report.rejections) rejections.set(reason, (rejections.get(reason) ?? 0) + 1)
    // Looper's own selection, unchanged: best quality first, a different way
    // out of the door preferred, and no walk sharing more than 55% of its
    // ground with one already chosen.
    const selectable = passes.map(entry => ({ ...entry, coordinates: entry.assembled.coordinates, quality: entry.report.quality, totalMetres: entry.assembled.graphMetres }))
    const offered = selectDiverseRoutes(selectable, 3)
    results.push({
      fixture: graph.name, prototype, stats,
      found: walks.length, passes: passes.length, offered: offered as unknown as Judged[],
      judgeMs: performance.now() - searched, buildMs: graph.stats.buildWallMs, exportMs: graph.stats.exportWallMs,
      rejections,
    })
    void began
  }
}

// -------------------------------------------------------------------- report

const out: string[] = [`# Phase 9 — direct bounded closed-walk search (${LABEL})\n`]
out.push(`beam ${BEAM}, band ${BAND} m, per-node cap ${PER_NODE}, per-family floor ${PER_FAMILY}, wanted ${WANTED}, band ±${(100 * MAX_DISTANCE_ERROR).toFixed(0)}%\n`)

out.push('## Prototype comparison\n')
out.push('| prototype | fixture | closed walks | gate passes | pass rate | offered | states expanded | states generated | pruned: distance | pruned: reuse | pruned: beam | pruned: dominated | peak band | search ms | judge ms |')
out.push('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
for (const prototype of Object.keys(runners)) {
  for (const row of results.filter(entry => entry.prototype === prototype)) {
    out.push(`| ${prototype} | ${row.fixture} | ${row.found} | ${row.passes} | ${row.found ? (100 * row.passes / row.found).toFixed(1) : '0.0'}% | ${row.offered.length} `
      + `| ${row.stats.expanded} | ${row.stats.generated} | ${row.stats.prunedDistance} | ${row.stats.prunedReuse} | ${row.stats.prunedBeam} | ${row.stats.prunedDominated} `
      + `| ${row.stats.peakFrontier} | ${row.stats.wallMs.toFixed(0)} | ${row.judgeMs.toFixed(0)} |`)
  }
}

out.push('\n## Offered walks\n')
out.push('| prototype | fixture | offered | median distance | mean abs error | mean quality | mean compactness | mean repeated % | u-turns | worst physical overlap |')
out.push('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|')
for (const prototype of Object.keys(runners)) {
  for (const row of results.filter(entry => entry.prototype === prototype)) {
    const set = row.offered
    if (!set.length) { out.push(`| ${prototype} | ${row.fixture} | 0 | — | — | — | — | — | — | — |`); continue }
    const graph = graphs.find(entry => entry.name === row.fixture)!
    let worst = 0
    for (let i = 0; i < set.length; i++) for (let j = i + 1; j < set.length; j++) {
      worst = Math.max(worst, mutualSharedFraction(
        { coordinates: set[i].assembled.coordinates, quality: set[i].report.quality, bearing: set[i].bearing, traversals: set[i].traversals, totalMetres: set[i].assembled.graphMetres },
        { coordinates: set[j].assembled.coordinates, quality: set[j].report.quality, bearing: set[j].bearing, traversals: set[j].traversals, totalMetres: set[j].assembled.graphMetres }))
    }
    out.push(`| ${prototype} | ${row.fixture} | ${set.length} | ${median(set.map(entry => entry.assembled.graphMetres)).toFixed(0)} `
      + `| ${mean(set.map(entry => Math.abs(entry.assembled.graphMetres - graph.targetMetres))).toFixed(0)} m `
      + `| ${mean(set.map(entry => entry.report.quality.score)).toFixed(1)} `
      + `| ${mean(set.map(entry => entry.report.quality.compactness)).toFixed(3)} `
      + `| ${mean(set.map(entry => entry.report.quality.repeatedPercent)).toFixed(2)}% `
      + `| ${set.reduce((sum, entry) => sum + entry.report.quality.uTurnCount, 0)} `
      + `| ${(100 * worst).toFixed(1)}% |`)
  }
}

out.push('\n## Rejection classes\n```text')
for (const prototype of Object.keys(runners)) {
  const merged = new Map<string, number>()
  for (const row of results.filter(entry => entry.prototype === prototype)) {
    for (const [reason, count] of row.rejections) merged.set(reason, (merged.get(reason) ?? 0) + count)
  }
  out.push(`${prototype}: ${[...merged].sort((a, b) => b[1] - a[1]).map(([reason, count]) => `${reason}=${count}`).join('  ') || 'none'}`)
}
out.push('```')

out.push('\n## Cost per request\n')
out.push('| fixture | subgraph export ms | search-graph build ms | S2 search ms | judge ms | total ms | states expanded | store entries | peak heap MB |')
out.push('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
for (const row of results.filter(entry => entry.prototype === 'S2')) {
  out.push(`| ${row.fixture} | ${row.exportMs.toFixed(2)} | ${row.buildMs.toFixed(1)} | ${row.stats.wallMs.toFixed(0)} | ${row.judgeMs.toFixed(0)} `
    + `| ${(row.exportMs + row.buildMs + row.stats.wallMs + row.judgeMs).toFixed(0)} | ${row.stats.expanded} | ${row.stats.storeSize} | ${(row.stats.peakHeapBytes / 1e6).toFixed(0)} |`)
}

const summary = results.filter(entry => entry.prototype === 'S2')
out.push(`\nS2 total offered across the normal ring: **${summary.reduce((sum, row) => sum + row.offered.length, 0)} of 12**`)
out.push(`S2 total search time across the ring: ${summary.reduce((sum, row) => sum + row.stats.wallMs, 0).toFixed(0)} ms\n`)

writeFileSync(new URL(`results/${LABEL}.md`, import.meta.url), out.join('\n') + '\n')
writeFileSync(new URL(`results/${LABEL}.json`, import.meta.url), JSON.stringify(results.map(row => ({
  ...row, rejections: Object.fromEntries(row.rejections),
  offered: row.offered.map(entry => ({
    metres: entry.assembled.graphMetres, quality: entry.report.quality, bearing: entry.bearing,
    edges: entry.walk.edges.length, coordinates: entry.assembled.coordinates.length,
  })),
})), null, 2) + '\n')
console.log(out.join('\n'))
