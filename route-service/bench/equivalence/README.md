# GraphHopper equivalence bench

Proves that Looper's routing can be served by GraphHopper's own code called
directly, rather than by GraphHopper's HTTP server, without any route changing.
Findings live in
[docs/GRAPHHOPPER_MINIMAL_BASELINE_REPORT.md](../../docs/GRAPHHOPPER_MINIMAL_BASELINE_REPORT.md).

Three engines answer the same bytes:

| | what it is |
|---|---|
| container | `looper-graphhopper-iom-1` on :8989, the shipped stack |
| direct Java | `LooperRoutingCore` in-process, no socket at all |
| minimal core | the same core behind ~100 lines of JDK HTTP on :8991 |

## Running it

The container must be up (`docker compose up -d graphhopper-iom`) and the
harness image built (`docker build -t looper-gh-harness gh-harness`).

```sh
# The shared fixtures. Avoidance corridors are routed and baked in here so
# that both engines are handed byte-identical polygons.
npx tsx bench/equivalence/fixtures.mts

# The baseline, and the minimal core over its own socket.
GH_URL=http://localhost:8989 OUT=results-http.json LABEL=graphhopper-container \
  npx tsx bench/equivalence/http-baseline.mts
GH_URL=http://localhost:8991 OUT=results-core.json LABEL=minimal-core-http \
  npx tsx bench/equivalence/http-baseline.mts

# The direct Java API, against the very graph bytes the container imported.
docker run --rm \
  -v looper_graph-cache-iom:/data/graph-cache:ro \
  -v "$PWD/graphhopper:/gh:ro" \
  -v "$PWD/bench/equivalence:/out" \
  looper-gh-harness /gh/config.yml /data/graph-cache /out/fixtures.json /out/results-java.json 7

# The verdicts.
npx tsx bench/equivalence/compare.mts                      # vs direct Java
AGAINST=results-core.json npx tsx bench/equivalence/compare.mts   # vs minimal core
npx tsx bench/equivalence/full-loops.mts                   # whole generation
```

To start the minimal core on :8991:

```sh
docker run -d --name looper-core -p 8991:8991 \
  -v looper_graph-cache-iom:/data/graph-cache:ro \
  -v "$PWD/graphhopper:/gh:ro" \
  --entrypoint java looper-gh-harness \
  -Xmx2g -Xms256m -cp /h/gh-harness.jar com.looper.routing.Serve /gh/config.yml /data/graph-cache 8991
```

Timings need a warm engine: measured immediately after a container restart the
same minimal core reads 0.86× the container, and warm it reads 1.26×. Run the
whole set through an engine once before believing any number from it, and set
`REPEATS=15` for a figure worth quoting.

## What "identical" means here

Distance at the precision the wire can express — `ResponsePathSerializer`
emits `Helper.round(distance, 3)`, so comparing the raw Java double against the
JSON number reports a difference on every fixture and measures Jackson rather
than the router. Plus: a SHA-256 of the 6-decimal coordinate sequence, the full
`edge_id` path-detail sequence, the snapped waypoints, and the routing weight.
`visited_nodes.sum` is compared too, which is the strongest of the lot — it says
the two searches settled the same nodes, not merely that they agreed on an
answer.

Engine-call count in `full-loops.mts` is **reported and not asserted**.
`diversityAwareEarlyStop` evaluates the candidate pool at wave boundaries while
candidates are routed concurrently, so latency changes which candidates have
landed when the stop trips. The same container gives 779, 763, 779, 763, 763
calls on five runs of `peel-5km` and returns byte-identical walks every time.
