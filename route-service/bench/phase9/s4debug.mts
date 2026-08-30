import { loadSubgraphs, buildSearchGraph } from './graph.mjs'
import { meetSearch, objectiveFor } from './search.mjs'
const raw = loadSubgraphs(new URL('subgraphs.json', import.meta.url))
for (const entry of raw) {
  const graph = buildSearchGraph(entry)
  const r = meetSearch(graph, { objective: objectiveFor(graph.targetMetres), budget: Infinity, beam: 300, band: 100, perNode: 8, poolPerNode: 12, minCompactness: 0 })
  console.log(entry.name, 'walks', r.walks.length, 'expanded', r.stats.expanded, 'completed', r.stats.completed)
}
