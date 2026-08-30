# Phase 10 — productionising the direct closed-walk search

The Phase 9 prototype lived here in TypeScript and searched an exported
subgraph. Phase 10 moved the search into the routing facade, so what is left in
this folder is measurement rather than algorithm: every script drives the real
route service against the real facade and reports what came back.

```sh
# The Java engine on its own: every stage timed, memory measured exactly,
# and a repeated-request check for leaks.
docker build -t looper-phase10 gh-harness
docker run --rm --entrypoint java \
  -v looper_graph-cache-iom:/data/graph-cache:ro \
  -v "$PWD/graphhopper:/gh:ro" -v "$PWD/bench/phase10:/work" \
  looper-phase10 -Xmx4g -Dlooper.direct.leakRuns=40 -cp /h/gh-harness.jar \
  com.looper.routing.direct.DirectBench /gh/config.yml /data/graph-cache \
  /work/fixtures.json /work/results/java-bench.json 5

# Phase 3B against Direct Search, alternating, on the six production probes.
npx tsx bench/phase10/paired.mts

# What turn awareness is worth, on and off.
npx tsx bench/phase10/turns.mts

# 2/3/5/8/10 km, and starts at increasing remove from the 2-core.
npx tsx bench/phase10/smoke.mts

# The Java engine against the Phase 9 TypeScript prototype's own recorded runs.
npx tsx bench/phase10/compare9.mts
```

Every script expects the settled facade on `:8991` (`bench/phase3a/facades.sh`)
and the GraphHopper container on `:8989`. `GH_URL` overrides the first.

Knobs: `REPEATS` for the paired benchmark; `-Dlooper.direct.{wanted,beam,band,
perNode,quota,turnAware,leakRuns}` for the Java benchmark.
