# Phase 9 — direct bounded closed-walk search

Analysis only. Nothing here changes production generation; there is no
`LOOPER_DIRECT_CLOSED_WALK_SEARCH` flag, because nothing was integrated. See
`docs/GRAPHHOPPER_LOOPER_PHASE9_DIRECT_CLOSED_WALK_SEARCH.md` for the decision
(B — structurally viable, engineering needed) and every measurement behind it.

The one production-tree change is a passive tracing-only field on the
`candidate` trace event carrying a completed candidate's physical edge passes.
It is computed only when `LOOPER_TRACE_FILE` is set, and `topology.mts` is what
reads it.

```sh
# P0 - Phase 3B reference, and the corpus this phase reads
npx tsx bench/phase8/baseline.mts
npx tsx bench/phase9/capture.mts P9

# P3 - topology of the walks Phase 3B already offers
npx tsx bench/phase9/topology.mts P9

# P4 - bounded subgraph export
docker build -t looper-phase9 gh-harness
docker run --rm --entrypoint java \
  -v looper_graph-cache-iom:/data/graph-cache:ro \
  -v "$PWD/graphhopper:/gh:ro" -v "$PWD/bench/phase9:/work" \
  looper-phase9 -Xmx4g -cp /h/gh-harness.jar \
  com.looper.routing.Subgraph /gh/config.yml /data/graph-cache \
  /work/fixtures.json /work/subgraphs.json true
npx tsx bench/phase9/graph.mts
npx tsx bench/phase9/validate.mts

# P6-P11, P16 - the prototypes, the gate, diversity, the comparison
node --expose-gc --import tsx bench/phase9/analyse.mts
node --expose-gc --import tsx bench/phase9/compare.mts
npx tsx bench/phase9/diagnose.mts
S4_DEBUG=1 npx tsx bench/phase9/s4debug.mts

# P7, P14, P15 - cost, memory and dominance sweep
node --expose-gc --import tsx bench/phase9/sweep.mts

# P13 - materialisation, with the Phase 8 three-corner control
npx tsx bench/phase9/materialise.mts

# P18, P19 - oracle route availability and constraint sensitivity
node --expose-gc --import tsx bench/phase9/oracle.mts

# P21 - GraphHopper's own round-trip algorithm
npx tsx bench/phase9/roundtrip.mts
```

`graph.mts` holds the 2-core peel, the degree-2 contraction and the stem
reconstruction; `search.mts` the four search prototypes, the field lower-bound
prune, the incremental shape state and the family-quota beam; `walk.mts` turns
a searched walk into the line and edge spans Looper's own acceptance gate
consumes. Every quality judgement in this phase is `analyseRouteQuality` with
no threshold relaxed, and every offered set is `selectDiverseRoutes`.

Environment knobs: `BEAM`, `BAND`, `PER_NODE`, `PER_FAMILY`, `WANTED`, `LABEL`
(analyser); `ORACLE_BEAM`, `ORACLE_BAND`, `ORACLE_PER_NODE` (oracle); `SEEDS`
(round-trip); `SAMPLE` (materialisation); `GH_URL`, `GH_ENGINE_URL`.
