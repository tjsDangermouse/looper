# Phase 2 bench: GraphHopper under Looper's real workload

Findings live in
[docs/GRAPHHOPPER_LOOPER_PHASE2_PERFORMANCE.md](../../docs/GRAPHHOPPER_LOOPER_PHASE2_PERFORMANCE.md).

The one idea everything here is built on: **benchmark the mix, not the shapes.**
Phase 1's seventeen fixtures cover every request shape Looper sends, and they
were the right tool for proving two engines identical. They are the wrong tool
for deciding where a latency budget goes, because they were not chosen to be
representative — Phase 1's avoidance fixtures settle 3,300–5,400 nodes and the
median real avoidance call settles 604. So Phase 2 captures what the generator
actually asks for and replays that.

## The corpus

`capture.mts` runs the six production probes through a real route service with
`LOOPER_TRACE_FILE` set, and writes one JSONL record per engine call: the
purpose, the class of custom model, the points, the model itself, the wall time
and the settled-node count. 1,863 calls, and the per-fixture call counts
reproduce Phase 1's exactly.

The trace is production code (`src/loops/metrics.ts`) and is off unless
`LOOPER_TRACE_FILE` names a file; `LOOPER_TRACE_BODIES=1` adds the points and
model, which is what makes a record replayable and which is most of the file
size.

```sh
npx tsx bench/phase2/capture.mts     # writes corpus/*.jsonl (gitignored, 7 MB)
npx tsx bench/phase2/anatomy.mts     # the workload tables
```

## The experiments

| script | question |
|---|---|
| `com.looper.routing.Lab` | replays the corpus under named GraphHopper configurations — landmark counts, algorithms, `lm.disable`, response shapes |
| `com.looper.routing.Heuristic` | what the landmark bound is worth in weight units, against a Dijkstra's exact answer |
| `com.looper.routing.ModelCost` | what building a weighting from an avoidance model costs, on a cache hit and a miss |
| `transport.mts` | the same corpus from Node, serial, so the boundary can be separated from the engine |
| `prepare-landmarks.sh` + `landmark-sweep.sh` | prepared × active landmark matrix, one import per prepared count |
| `avoidance-strength.mts` | the weakest penalty that still returns the 0.05 path, per real request |
| `end-to-end.mts` | whole generations, medians, the only measurement that decides anything |

```sh
docker build -t looper-gh-harness gh-harness

docker run --rm -v looper_graph-cache-iom:/data/graph-cache:ro \
  -v "$PWD/graphhopper:/gh:ro" -v "$PWD/bench/phase2:/lab" \
  --entrypoint java looper-gh-harness -Xmx2g -Xms256m -cp /h/gh-harness.jar \
  com.looper.routing.Lab /gh/config.yml /data/graph-cache /lab/corpus \
    /lab/results/lab-matrix.json 5

./bench/phase2/prepare-landmarks.sh 16 32 64
./bench/phase2/landmark-sweep.sh
npx tsx bench/phase2/transport.mts
npx tsx bench/phase2/avoidance-strength.mts
npx tsx bench/phase2/end-to-end.mts
```

## Two traps this bench walks into if you let it

**A cold JVM is not slower by a little.** The first configuration in a Lab run
pays for compiling GraphHopper's search, its custom weighting and Jackson, and
every configuration after it inherits that free — worth about 7%, which is
larger than most of the effects being looked for, and it flatters whatever runs
last. `Lab` warms the whole corpus twice before the first measurement. The same
applies to a freshly started engine: the first `end-to-end.mts` comparison
reported a 64-landmark engine 22.8% slower purely because it had been up for
ninety seconds. Warm every engine against the whole corpus before timing any of
them.

**A killed `npx` leaves a live service.** `npx tsx` is three processes deep, so
killing the spawned one orphans a route service that keeps the port and keeps
writing to the trace file the next run is about to claim as its own. That failure
is silent and it corrupts the corpus. `service.mts` starts children in their own
process group, kills by group, and refuses to start on a port that is already
answering.

## Determinism

Engine-call count is reported and never asserted, as in Phase 1.
`diversityAwareEarlyStop` evaluates the candidate pool at wave boundaries while
candidates are routed concurrently, so arrival order — that is, latency — decides
which have landed when the stop trips. `peel-5km` gives 743–779 calls across runs
and returns byte-identical walks every time. What must match is the walks.

Route identity across configurations is a fingerprint over the full `edge_id`
sequence of all 1,863 calls, which is stronger than distance or a geometry hash:
it says the searches agreed on the same physical edges, not merely on a length.
