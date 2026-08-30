/**
 * Turning a searched walk into something the acceptance gate can judge.
 *
 * The gate is Looper's own, unchanged: the same `analyseRouteQuality` the
 * production generator calls, given the same edge traversals it would have
 * measured from a GraphHopper response. Nothing is re-defined for the search's
 * convenience — the point of the phase is to find out whether a walk chosen in
 * graph space survives the test a routed walk has to pass.
 */
import { measureTraversals, type EdgeSpan } from '../../src/loops/edges.js'
import { pathLength, type LngLat } from '../../src/loops/geo.js'
import { analyseRouteQuality, type QualityReport } from '../../src/loops/quality.js'
import { initialBearing } from '../../src/loops/diversity.js'
import { stemTo, type SearchGraph } from './graph.mjs'
import type { Walk } from './search.mjs'

export type Assembled = {
  coordinates: LngLat[]
  spans: EdgeSpan[]
  /** Physical edge ids and metres, in walk order. */
  passes: Array<[number, number]>
  graphMetres: number
  drawnMetres: number
}

/** The drawn line and the physical edges under it, stem included at both ends. */
export function assemble(graph: SearchGraph, walk: Walk, root: number): Assembled {
  const coordinates: LngLat[] = []
  const spans: EdgeSpan[] = []
  const passes: Array<[number, number]> = []
  let graphMetres = 0
  const append = (points: LngLat[], physical: Array<[number, number]>) => {
    // One span per physical edge, so the gate measures the same units the
    // production path measures. Geometry is shared at the joins.
    const total = physical.reduce((sum, [, metres]) => sum + metres, 0)
    const started = Math.max(0, coordinates.length - 1)
    for (const point of points) {
      const last = coordinates[coordinates.length - 1]
      if (!last || last[0] !== point[0] || last[1] !== point[1]) coordinates.push(point)
    }
    const finished = coordinates.length - 1
    if (finished <= started) return
    // Physical edges inside a contracted chain are laid out along the chain in
    // proportion to their own length; a chain of one is the exact case.
    let cursor = started
    let walked = 0
    physical.forEach(([id, metres], index) => {
      walked += metres
      const end = index === physical.length - 1 ? finished : started + Math.round((finished - started) * (total > 0 ? walked / total : 0))
      if (end > cursor) { spans.push({ id, startIndex: cursor, endIndex: end }); cursor = end }
      passes.push([id, metres])
      graphMetres += metres
    })
  }

  const stem = stemTo(graph, root)
  if (stem.geometry.length) append(stem.geometry, stem.physical)
  walk.edges.forEach((index, step) => {
    const edge = graph.edges[index]
    const forward = walk.forward[step]
    append(forward ? edge.geometry : [...edge.geometry].reverse(),
      forward ? edge.physical : [...edge.physical].reverse())
  })
  if (stem.geometry.length) append([...stem.geometry].reverse(), [...stem.physical].reverse())

  return { coordinates, spans, passes, graphMetres, drawnMetres: pathLength(coordinates) }
}

export type Judged = {
  walk: Walk
  assembled: Assembled
  report: QualityReport
  bearing: number
  traversals: ReturnType<typeof measureTraversals>
}

/** The production gate, on the searched walk, with no thresholds relaxed. */
export function judge(graph: SearchGraph, walk: Walk, root: number, requestStart: LngLat): Judged {
  const assembled = assemble(graph, walk, root)
  const traversals = measureTraversals(assembled.coordinates, assembled.spans)
  const report = analyseRouteQuality({
    traversals,
    coordinates: assembled.coordinates,
    start: requestStart,
    distanceMeters: assembled.graphMetres,
    durationSeconds: 0,
    targetMetres: graph.targetMetres,
    // A directly searched walk has no legs: it was never cut into planned
    // steps, so the balance rules have nothing to be lopsided against. Passing
    // an empty list is what the gate already does for a single-leg walk.
    legDistances: [],
  })
  return { walk, assembled, report, bearing: initialBearing(assembled.coordinates, requestStart), traversals }
}
