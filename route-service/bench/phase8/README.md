# Phase 8 — pairwise topological anchor compatibility

Analysis only. Nothing here changes production generation; there is no
`LOOPER_PAIRWISE_ANCHOR_CANDIDATES` flag, because the analysis gate did not
pass. See `docs/GRAPHHOPPER_LOOPER_PHASE8_PAIRWISE_ANCHOR_COMPATIBILITY.md`.

```sh
# P0 — Phase 3B reference: trace corpus and offered-route confirmation
npx tsx bench/phase6/capture.mts P8
npx tsx bench/phase8/baseline.mts

# P1/P3 — rebuild the field exporter, now seeded on the QueryGraph virtual
# node and carrying shortest-path-tree predecessors
docker build -t looper-phase8-field gh-harness
docker run --rm --entrypoint java \
  -v looper_graph-cache-iom:/data/graph-cache:ro \
  -v "$PWD/graphhopper:/gh:ro" -v "$PWD/bench/phase8:/work" \
  looper-phase8-field -Xmx2g -cp /h/gh-harness.jar \
  com.looper.routing.NetworkField /gh/config.yml /data/graph-cache \
  /work/fixtures.json /work/network-fields.json

# P4/P5 — anchor and all-pairs probe oracle (offline price, see the report)
POOL=32 npx tsx bench/phase8/probe.mts

# P2, P6-P17 — the analysis itself
npx tsx bench/phase8/analyse.mts
PER_FAMILY=1 LABEL=per-family-1 npx tsx bench/phase8/analyse.mts
ADAPTIVE=false LABEL=static npx tsx bench/phase8/analyse.mts
npx tsx bench/phase8/diagnose.mts
```

`field.mts` holds the field, tree-ancestry and anchor-pool primitives;
`sequence.mts` the sparse compatibility graph and sequence search;
`analyse.mts` routes the chosen sequences through the same Phase 3B leg
machinery and writes every table. Environment knobs: `POOL`, `FANOUT`,
`PROBE_BUDGET`, `PER_FAMILY`, `ADAPTIVE`, `INFLATION`, `POOL_SIZES`, `LABEL`.
