# GraphHopper minimal baseline report

Phase 1: can Looper's routing be served by GraphHopper's own code invoked
directly, instead of by GraphHopper's HTTP server, without changing a single
route?

Measured 2026-08-29 against `looper-graphhopper-iom-1` (warm, GraphHopper 11.0,
Isle of Man) on darwin/arm64, Docker Desktop, 7.65 GB container memory. All
timings are the median of fifteen runs after a warm-up call, on an engine that
has already served the whole fixture set at least once. That last condition
matters more than it sounds: measured against a JIT-cold JVM the same minimal
core reads 0.86× the container and against a warm one 1.26×, and neither number
is wrong — only one of them is about routing. Reproduce with:

```
node bench/equivalence/fixtures.mts          # build the shared fixtures
npx tsx bench/equivalence/http-baseline.mts  # the container
docker run ... looper-gh-harness ...         # the direct Java API
npx tsx bench/equivalence/compare.mts        # the verdict
npx tsx bench/equivalence/full-loops.mts     # whole-generation comparison
```

## Executive conclusion: **PASS**

Three engines were compared: the shipped GraphHopper container, GraphHopper's
Java API called in-process, and a minimal core (`LooperRoutingCore` behind ~100
lines of JDK HTTP, no Dropwizard). On all 17 low-level fixtures and all 6
full-generation fixtures, **every route is identical** — distance to the
precision the wire can express, geometry hash, complete edge-ID sequence,
snapped waypoints, routing weight, and settled-node count.

Performance is equivalent or better. Across the fixture set the direct Java API
is **1.6× faster** than the container (three rounds: 1.63×, 1.66×, 1.59×, each a
fresh JVM), and the minimal core over its own socket is **1.2–1.5× faster**
(1.16×, 1.46×, 1.35×, 1.26×). Whole-generation wall time is **1.09×** faster on
the minimal core. Nothing is slower, and there is no unexplained slowdown
anywhere.

No hard-stop condition was triggered. No routing logic was written: the
`LooperRoutingCore` facade configures GraphHopper and calls it, and implements
no search, no snapping and no weighting of its own.

Two claims in the brief were wrong and are corrected in
[GRAPHHOPPER_LOOPER_ARCHITECTURE.md](GRAPHHOPPER_LOOPER_ARCHITECTURE.md): the
profile is named `foot`, not `looper_foot`; and the long-open question of
whether landmarks survive a request custom model is now answered — they do, for
avoidance, and they do not for the lower-bound model.

## Configuration in force

From `graphhopper/config.yml`, unmodified:

```yaml
profiles:      [{ name: foot, custom_model_files: [looper_foot.json] }]
profiles_ch:   []
profiles_lm:   [{ profile: foot }]
graph.encoded_values: foot_access, foot_priority, foot_average_speed,
  foot_road_access, hike_rating, mtb_rating, country, road_class,
  road_environment, surface
import.osm.ignored_highways: motorway,trunk
prepare.min_network_size: 200
routing.max_visited_nodes: 1000000
routing.snap_preventions_default: tunnel, bridge, ferry
graph.dataaccess.default_type: RAM_STORE
```

Every Looper request sets `snap_preventions: ['ferry']`, so the config default
never applies to a real leg.

## Mode and algorithm, conclusively

| | |
|---|---|
| routing mode | **LM hybrid** (`Router.LMSolver`) |
| CH | **not built and not used** — `profiles_ch: []`, so `chEnabled` is false |
| LM | **active**, 16 prepared, 8 active per request |
| algorithm | **`astarbi`** — `AStarBidirection` + `LMApproximator`, epsilon 1 |
| chosen by | default, not by request: Looper sends no `algorithm` |
| traversal | `NODE_BASED` (`graph.turn_encoded_values=[]`) |
| weighting | `CustomWeighting`, profile model merged with request model |

The container's own log is the primary evidence:
`astarbi|landmarks-routing:6 ms, visited nodes sum: 240`.

## Landmarks under Looper's custom models

Douglas seafront → 1.5 km inland, median of seven, `visited_nodes.sum`:

| Request | LM on | `lm.disable` | LM benefit |
|---|---|---|---|
| no custom model | 192 | 1,290 | 6.7× |
| real corridor, `multiply_by 0.05` | 1,888 | 4,162 | 2.2× |
| real corridor, `multiply_by 0.2` | 1,276 | 3,158 | 2.5× |
| `distance_influence: 2000` | 620 | 620 | none |

Landmarks keep working under avoidance. They do nothing for the lower-bound
model, because `LMApproximator` expresses its bound in the prepared weighting's
units and never rescales it; with ~2 weight units per metre added, the bound is
valid and useless, and the beeline term carries the search. `config.yml`'s
comment is correct for the avoidance case, GraphHopper's documentation warning
is correct for the lower-bound case, and `bench/probe-engine.mjs`'s question is
now answered.

Compatibility is enforced by `FindMinMax.checkLMConstraints`: request models may
only multiply priority/speed by values in `[0,1]` and may only raise
`distance_influence`. Looper satisfies both by construction.

## A→B, via and avoidance comparison

17 fixtures, all Isle of Man, all sent as the exact bytes
`src/graphhopper.ts` builds. Avoidance corridors were generated once by
`buildAvoidanceAreas` and baked into the fixture file, so both engines answer
byte-identical polygons.

| Fixture | Distance m | Visited | Edges | GH service ms | Direct Java ms | Minimal core ms | Identical |
|---|---|---|---|---|---|---|---|
| `ab-douglas-short` | 1558.8 | 192 | 94 | 3.2 | 2.1 | 2.2 | yes |
| `ab-douglas-onchan` | 3548.6 | 418 | 173 | 3.0 | 1.9 | 2.1 | yes |
| `ab-promenade` | 542.7 | 140 | 37 | 2.9 | 2.0 | 2.7 | yes |
| `ab-laxey-dhoon` | 4008.0 | 190 | 34 | 2.3 | 0.9 | 1.8 | yes |
| `ab-peel` | 535.9 | 18 | 9 | 2.1 | 0.7 | 1.6 | yes |
| `ab-ramsey` | 907.2 | 62 | 22 | 2.1 | 0.6 | 1.3 | yes |
| `ab-open-space-snap` | 15754.4 | 2,180 | 88 | 3.9 | 2.1 | 2.9 | yes |
| `ab-long-island` | 18454.8 | 3,030 | 325 | 5.9 | 3.0 | 3.9 | yes |
| `via-3pt` | 3600.5 | 386 | 166 | 3.4 | 1.2 | 2.3 | yes |
| `via-4pt` | 5740.7 | 512 | 217 | 3.6 | 1.4 | 2.5 | yes |
| `via-5pt-loopish` | 7719.9 | 1,886 | 315 | 4.5 | 3.0 | 3.8 | yes |
| `cm-distance-influence` | 3537.3 | 2,242 | 169 | 4.4 | 3.4 | 3.5 | yes |
| `avoid-1leg-strong` | 4965.6 | 3,328 | 168 | 8.4 | 7.3 | 6.8 | yes |
| `avoid-1leg-relaxed` | 4965.6 | 3,466 | 168 | 8.4 | 5.9 | 7.3 | yes |
| `avoid-3leg-strong` | 5896.0 | 5,432 | 219 | 12.1 | 8.8 | 10.1 | yes |
| `avoid-3leg-via` | 6702.0 | 4,196 | 237 | 10.8 | 7.3 | 9.7 | yes |
| `avoid-rural` | 5766.2 | 364 | 73 | 3.0 | 1.0 | 2.1 | yes |
| **total** | | | | **83.9** | **52.7** | **66.8** | |

"Identical" is the conjunction of: distance at the wire's own precision
(`ResponsePathSerializer` emits `Helper.round(distance, 3)`), SHA-256 of the
6-decimal coordinate sequence, the full `edge_id` path-detail sequence, and the
snapped waypoints. It held on every fixture, and `visited_nodes.sum` matched
exactly on every fixture too — the searches did not merely agree on an answer,
they settled the same nodes getting there.

Coverage of the required cases: no avoidance (`ab-*`), normal multiplier
(`avoid-1leg-strong`, `avoid-3leg-strong`), relaxed multiplier
(`avoid-1leg-relaxed`), distance-influence lower bound
(`cm-distance-influence`), multiple polygons (`avoid-3leg-*`, three areas),
avoidance combined with via points (`avoid-3leg-via`), 2/3/4/5-point routes,
and an open-moorland snap 9.8 km from the nearest fixture point
(`ab-open-space-snap`).

Snapping and query-graph behaviour are covered implicitly and exactly: the
snapped waypoints match on all 17, and mid-edge starts are the normal case for
every one of these fixtures. As a separate check, the facade's standalone
`snap()` was asserted against the snapping the router performed inside the same
request — it agrees on 17 of 17. That check caught a real defect during this
work: the first version of `snap()` omitted `SnapPreventionEdgeFilter`, which
the router applies.

## Full Looper generation

The route service was started twice, identical but for
`GRAPHHOPPER_IOM_URL`, and given the six established production-probe requests
at production's 24 candidates.


| Fixture | Routes | Distances m | Container ms | Minimal core ms | Engine calls | Identical |
|---|---|---|---|---|---|---|
| `douglas-5km` | 3 | 5064, 4930, 4446 | 670 | 602 | 291 / 291 | yes |
| `douglas-3km` | 3 | 3011, 2768, 2702 | 385 | 358 | 215 / 215 | yes |
| `peel-5km` | 3 | 4877, 4727, 4885 | 944 | 955 | 763 / 763 | yes |
| `onchan-5km` | 3 | 4850, 5034, 5295 | 236 | 245 | 181 / 181 | yes |
| `wp-one` | 1 | 6911 | 165 | 150 | 34 / 34 | yes |
| `wp-two` | 1 | 9410 | 1048 | 853 | 379 / 379 | yes |
| **total** | | | **3448** | **3163** | | |

Identical route counts, distances, quality scores and geometry on all six.

**One caveat, recorded rather than smoothed over.** An earlier run showed
`peel-5km` making 763 engine calls against the container and 743 against the
core, with identical routes. That is not an engine difference: re-running
`peel-5km` five times against *the same* container gave 779, 763, 779, 763, 763
calls while returning byte-identical walks every time. `diversityAwareEarlyStop`
evaluates the candidate pool at wave boundaries and candidates are routed
concurrently, so which have landed when the stop trips depends on arrival order,
and therefore on latency. Engine-call count is reported by
`full-loops.mts` and deliberately not asserted; the walks are what must match,
and they do.

## Runtime footprint

| | GraphHopper container | Minimal core |
|---|---|---|
| source OSM PBF | 6,045,187 B | same |
| graph directory | 10,538,519 B | same bytes, mounted read-only |
| — of which `landmarks_foot` | 3,145,828 B | same |
| — of which `edges` | 2,097,252 B | same |
| jar | 47,346,509 B | **14,666,311 B** |
| Docker image | 519 MB | 454 MB |
| container restart → `/info` answers | 1.6 s | **0.6 s** |
| graph load alone (in-process) | not separable from startup | 0.40–0.51 s |
| heap in use after load | not comparable | 27 MB (post-`System.gc()`) |
| container RSS, idle | 808 MiB | **578 MiB** |

Both JVMs run `-Xmx2g -Xms256m`, so RSS reflects heap growth policy more than
need; the 27 MB figure is the honest measure of what the loaded graph and
landmarks actually occupy. Graph: 35,088 nodes, 42,016 edges.

## What GraphHopper actually needs for Looper

Keep: `BaseGraph` + `EdgeKVStorage`; the OSM importer and foot parsers; the 17
encoded values the import stores; `PrepareRoutingSubnetworks`;
`LocationIndexTree`; `DefaultSnapFilter` + `SnapPreventionEdgeFilter`;
`QueryGraph` with virtual nodes and edges; `CustomWeighting` +
`CustomModelParser` + Janino; `FindMinMax.checkLMConstraints`;
`LandmarkStorage` + `PrepareLandmarks` + `LMApproximator` +
`LMRoutingAlgorithmFactory`; `AStarBidirection` + `FlexiblePathCalculator` +
`ViaRouting` + `BidirPathExtractor`; path details for `edge_id`, `street_name`,
`road_class`; `InstructionsFromEdges`.

## What can be discarded

Demonstrated discardable — the minimal core runs without it and returns
identical bytes: Dropwizard, Jetty, Jersey and the web UI (a 32.7 MB jar
saving, 230 MiB of RSS, and a 1.6 s → 0.6 s warm start).

Discardable on evidence from the request path: all CH classes;
`RoundTripRouting`; `AlternativeRoute`; `Dijkstra`/`DijkstraBidirectionRef`/
`AStar`/`DijkstraOneToMany` (unreachable — the LM factory accepts only
`astar`, `astarbi` and `alternative_route`); isochrone and SPT endpoints
(`networkAwareSeeds` is `false`, so `reachFrom` is never called); map matching;
GTFS; the navigation API; car/bike/truck profiles; elevation; turn costs;
`MaxSpeedCalculator` and country rules.

Third-party weight that is import-time-only or disabled-feature-only, and so
could leave a serving-only artifact: `osmosis-osm-binary` + `protobuf-java`
(PBF reading), `kotlin-stdlib` + `osm-legal-default-speeds`
(`MaxSpeedCalculator`, disabled), `xmlgraphics-commons` + `commons-io`
(elevation, disabled).

Care needed: `country` must stay as an encoded value — `looper_foot.json`
references it in the German bridleway rule — even though the country *rule
factory* is off. `foot_priority` is stored and genuinely unused (4 bits/edge),
because `looper_foot.json` replaces the road-class preference entirely.

## Recommended Phase 2

**Answered.** See
[GRAPHHOPPER_LOOPER_PHASE2_PERFORMANCE.md](GRAPHHOPPER_LOOPER_PHASE2_PERFORMANCE.md).
The first recommendation below was the right question and the answer is no: a
preparation that anticipates avoidance is not expressible, because GraphHopper
keys one landmark storage per profile and a request cannot select among several.
The same trick *does* work for the lower-bound model through a dedicated
profile — 2.27× fewer nodes, route-identical — but that model turns out to have
zero production calls. And the premise underneath both was too generous to the
engine: measured against the real call mix rather than these fixtures,
GraphHopper spends 19% of what Looper calls engine time, and the search itself
4%. No engine configuration moves whole-generation latency at all.

The evidence points somewhere slightly different from where the brief expected.

Removing the server bought a 3.2× smaller jar, 230 MiB, and a 2.7× faster warm
start, and it did buy some speed — but much less than it looks. The 1.6×
in-process figure is mostly HTTP and JSON, which Looper would have to pay again
over any IPC boundary; over an actual socket it falls to 1.2–1.5×, and
whole-generation wall time gains only 1.09× because the generator's own
concurrency already hides most per-leg latency. The routing engine is not the
bottleneck: on this graph a plain leg is 1–5 ms.

So the next question is not "how do we make the engine faster". Two candidates,
in order of evidence:

1. **Establish what makes avoidance legs cost 3–5× a plain leg**, since they are
   the bulk of generation work. The table shows it is search, not polygon
   arithmetic: `avoid-3leg-strong` settles 5,432 nodes against 418 for the same
   endpoints unavoided. Landmarks help there (2.2×) but much less than on plain
   legs (6.7×), because the corridors push the route away from the geometry the
   prepared bound assumes. Whether a preparation that anticipates avoidance is
   possible is a real question and is answerable with the harness that now
   exists.

2. **Then, and only then, size and portability.** The measured floor for a
   serving-only artifact is roughly a 14.7 MB jar, a 10.5 MB graph and ~27 MB of
   live heap for the Isle of Man. That is already small. What is not yet known
   is how much of the 14.7 MB is import-only code, and that is a
   dependency-splitting exercise rather than a rewrite.

What the evidence does **not** support is starting a source fork. Nothing was
copied, nothing needed to be, and `GraphHopper as a library` was sufficient for
every Phase 1 goal — which is the answer to the question the brief left open.
