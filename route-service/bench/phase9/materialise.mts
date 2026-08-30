/**
 * P13 — materialisation.
 *
 * A walk found in graph space is already a real walk: every metre of it is a
 * GraphHopper edge, drawn with GraphHopper's own geometry, and its length is
 * the sum of those edges' own distances. The question is what, if anything,
 * GraphHopper still has to be asked.
 *
 * Three representations are compared against the searched walk itself:
 *   M1  every junction on the walk, in order, as via points;
 *   M2  a subsampled subsequence of those junctions;
 *   M3  the anchors Phase 8 would have used — three corners and the start.
 * M3 is included because it is the Phase 8 failure written as a control: if
 * GraphHopper is free to choose between sparse anchors it does not return the
 * walk that was searched, and the whole phase would be back where it started.
 */
import { writeFileSync } from 'node:fs'
import { GraphHopperClient, parseLeg } from '../../src/graphhopper.js'
import { haversine, type LngLat } from '../../src/loops/geo.js'
import { measureTraversals } from '../../src/loops/edges.js'
import { analyseRouteQuality } from '../../src/loops/quality.js'
import { STARTS, median } from '../phase8/field.mjs'
import { loadSubgraphs, buildSearchGraph } from './graph.mjs'
import { beamSearch, objectiveFor, rootOf } from './search.mjs'
import { judge } from './walk.mjs'

const gh = new GraphHopperClient(process.env.GH_URL ?? 'http://localhost:8991', 'foot', 30000)
const PER_FIXTURE = Number(process.env.SAMPLE ?? 3)

let calls = 0, wallMs = 0
const route = async (points: LngLat[]) => {
  calls++
  const began = performance.now()
  const response = await gh.route(points, {})
  wallMs += performance.now() - began
  return parseLeg(response.payload)
}

const rows: Array<Record<string, unknown>> = []
for (const raw of loadSubgraphs(new URL('subgraphs.json', import.meta.url))) {
  const graph = buildSearchGraph(raw)
  const { root } = rootOf(graph)
  const start = STARTS.get(graph.name)!
  const { walks } = beamSearch(graph, {
    objective: objectiveFor(graph.targetMetres), budget: Infinity,
    beam: 300, band: 100, perNode: 3, perFamily: 1, minCompactness: 0.2, wanted: 400,
  })
  const passing = walks.map(walk => judge(graph, walk, root, start)).filter(entry => entry.report.pass)
  const sample = passing.sort((a, b) => b.report.quality.score - a.report.quality.score).slice(0, PER_FIXTURE)

  for (const [index, entry] of sample.entries()) {
    // Junction points of the walk: the ends of every super-edge, in order.
    const junctions: LngLat[] = [start]
    let at = root
    for (const [step, edgeIndex] of entry.walk.edges.entries()) {
      const edge = graph.edges[edgeIndex]
      at = entry.walk.forward[step] ? edge.to : edge.from
      junctions.push([graph.lon[at], graph.lat[at]])
    }
    junctions.push(start)
    const subsample = junctions.filter((_, i) => i === 0 || i === junctions.length - 1 || i % 4 === 0)
    const third = Math.floor(entry.walk.edges.length / 3)
    const corners = [start,
      junctions[Math.max(1, third)], junctions[Math.max(2, third * 2)], junctions[Math.max(3, third * 3)], start]

    const compare = async (name: string, points: LngLat[]) => {
      const leg = await route(points)
      const traversals = measureTraversals(leg.coordinates, leg.edges)
      const report = analyseRouteQuality({
        traversals, coordinates: leg.coordinates, start,
        distanceMeters: leg.distanceMeters, durationSeconds: leg.durationSeconds,
        targetMetres: graph.targetMetres, legDistances: [],
      })
      const searched = new Set(entry.assembled.passes.map(([id]) => id))
      const got = new Set((leg.edges ?? []).map(span => span.id))
      const shared = [...got].filter(id => searched.has(id)).length
      return {
        fixture: graph.name, walk: index, representation: name, points: points.length,
        searchedMetres: Math.round(entry.assembled.graphMetres), routedMetres: Math.round(leg.distanceMeters),
        deltaMetres: Math.round(leg.distanceMeters - entry.assembled.graphMetres),
        edgesSearched: searched.size, edgesRouted: got.size,
        edgeAgreement: got.size ? shared / got.size : 0,
        pass: report.pass, rejections: report.rejections, quality: report.quality.score,
        compactness: report.quality.compactness, repeatedPercent: report.quality.repeatedPercent,
        uTurns: report.quality.uTurnCount,
        endpointGap: Math.round(haversine(leg.coordinates[0], leg.coordinates[leg.coordinates.length - 1])),
      }
    }
    rows.push(await compare('M1 every junction', junctions))
    rows.push(await compare('M2 every fourth junction', subsample))
    rows.push(await compare('M3 three corners (Phase 8 control)', corners))
    rows.push({
      fixture: graph.name, walk: index, representation: 'M0 searched walk, unrouted', points: 0,
      searchedMetres: Math.round(entry.assembled.graphMetres), routedMetres: Math.round(entry.assembled.graphMetres),
      deltaMetres: 0, edgesSearched: new Set(entry.assembled.passes.map(([id]) => id)).size,
      edgesRouted: new Set(entry.assembled.passes.map(([id]) => id)).size, edgeAgreement: 1,
      pass: entry.report.pass, rejections: entry.report.rejections, quality: entry.report.quality.score,
      compactness: entry.report.quality.compactness, repeatedPercent: entry.report.quality.repeatedPercent,
      uTurns: entry.report.quality.uTurnCount, endpointGap: 0,
    })
  }
}

const kinds = [...new Set(rows.map(row => row.representation as string))].sort()
const out: string[] = ['# Phase 9 P13 — materialisation\n',
  '| representation | walks | via points | median |routed − searched| m | median edge agreement | gate passes | median quality | median compactness |',
  '|---|---:|---:|---:|---:|---:|---:|---:|']
for (const kind of kinds) {
  const set = rows.filter(row => row.representation === kind)
  out.push(`| ${kind} | ${set.length} | ${median(set.map(row => row.points as number)).toFixed(0)} `
    + `| ${median(set.map(row => Math.abs(row.deltaMetres as number))).toFixed(0)} `
    + `| ${(100 * median(set.map(row => row.edgeAgreement as number))).toFixed(1)}% `
    + `| ${set.filter(row => row.pass).length}/${set.length} `
    + `| ${median(set.map(row => row.quality as number)).toFixed(1)} `
    + `| ${median(set.map(row => row.compactness as number)).toFixed(3)} |`)
}
out.push(`\nGraphHopper calls: ${calls}, boundary wall ${wallMs.toFixed(0)} ms\n`)
out.push('## Per walk\n')
out.push('| fixture | walk | representation | points | searched m | routed m | delta | edge agreement | pass | rejections |')
out.push('|---|---:|---|---:|---:|---:|---:|---:|---|---|')
for (const row of rows) out.push(`| ${row.fixture} | ${row.walk} | ${row.representation} | ${row.points} | ${row.searchedMetres} | ${row.routedMetres} | ${row.deltaMetres} | ${(100 * (row.edgeAgreement as number)).toFixed(1)}% | ${row.pass ? 'yes' : 'no'} | ${(row.rejections as string[]).join(', ') || '—'} |`)
writeFileSync(new URL('results/materialise.md', import.meta.url), out.join('\n') + '\n')
writeFileSync(new URL('results/materialise.json', import.meta.url), JSON.stringify({ calls, wallMs, rows }, null, 2) + '\n')
console.log(out.slice(0, 10).join('\n'))
