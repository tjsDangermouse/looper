# What GraphHopper actually does for Looper

Audited against the running `looper-graphhopper-iom-1` container and the
GraphHopper source at tag `11.x`, commit `69e50f6e` — the `release 11.0`
commit, which is the same artifact `graphhopper/Dockerfile` pulls from Maven
Central. Every claim below was checked against one or the other; where the
existing documentation and the runtime disagreed, the runtime won and the
disagreement is recorded.

## Two corrections to the brief this work started from

**The profile is called `foot`, not `looper_foot`.** `looper_foot.json` is the
custom-model *file*; `graphhopper/config.yml` names the profile `foot` and
attaches the file via `custom_model_files`. `/info` reports one profile,
`foot`, and `GRAPHHOPPER_PROFILE` defaults to `foot` in
[config.ts](../src/config.ts#L45).

**Landmarks are active, including under Looper's avoidance models.** This was
the open question — `graphhopper/config.yml` says landmarks "give most of the
speed back", GraphHopper's own documentation warns they are no faster under a
request custom model, and `bench/probe-engine.mjs` was written to settle it and
records that both cannot be true. They are settled below: the config comment is
right, and the caveat applies to exactly one of Looper's three models.

## The request path

Looper sends one POST per leg from [graphhopper.ts](../src/graphhopper.ts#L84).
The body carries `ch.disable: true`, `points_encoded: false`,
`details: [street_name, road_class, edge_id]`, `snap_preventions: ['ferry']`,
instructions on, and a per-request `custom_model` whenever the leg is avoiding
ground already walked. It never sets `algorithm`, and never sets `lm.disable`.

```
POST /route  (route-service/src/graphhopper.ts)
   ↓
RouteResource.doPost                     web-bundle
   ↓  deserialises straight into GHRequest; applies routing.snap_preventions_default
   ↓  only when the body sets none — Looper always sets ['ferry'], so the
   ↓  config's `tunnel, bridge, ferry` default never applies to a Looper leg
GraphHopper.route → Router.route         core
   ↓
Router.createSolver
   ↓  chEnabled = false  (profiles_ch: [])
   ↓  lmEnabled = true   (profiles_lm: [foot]), and the request never disables it
LMSolver                                 Router.java:573
   ↓
Router.routeVia
   ├─ ViaRouting.lookup
   │     DefaultSnapFilter  →  SnapPreventionEdgeFilter(['ferry'])
   │     LocationIndexTree.findClosest      per point
   ├─ QueryGraph.create(graph, snaps)       virtual nodes and virtual edges
   ├─ LMSolver.createPathCalculator
   │     FindMinMax.checkLMConstraints(profile model, request model)
   │     LMRoutingAlgorithmFactory(landmarkStorage).setDefaultActiveLandmarks(8)
   │     → FlexiblePathCalculator
   ├─ ViaRouting.calcPaths                  one path per leg, in the given order
   │     AStarBidirection + LMApproximator(epsilon 1)
   └─ concatenatePaths → ResponsePath
         PathDetailsBuilderFactory: street_name, road_class, edge_id
         InstructionsFromEdges
   ↓
ResponsePathSerializer.jsonObject
```

## Routing mode: LM hybrid, definitively

`Router.createSolver` picks CH if any CH graph exists, else LM if any landmark
storage exists, else flexible. `profiles_ch` is empty and `profiles_lm` contains
`foot`, so every Looper request takes the LM branch. `ch.disable: true` is
therefore redundant but harmless — it guards a branch that could not have been
taken anyway.

The container's own log line says so directly, and is the least deniable
evidence available:

```
algo: , profile: foot, custom_model: null, ...
debugInfo: idLookup:0.0139s; , algoInit:2633 μs, astarbi|landmarks-routing:6 ms,
           path extraction: 168 μs, visited nodes sum: 240
```

`astarbi|landmarks-routing` is `AStarBidirection` running with an
`LMApproximator`.

## Routing algorithm: bidirectional A*, by default rather than by request

Looper sends no `algorithm`, so `AlgorithmOptions.getAlgorithm()` is empty and
`LMRoutingAlgorithmFactory.createAlgo` falls into the
`ASTAR_BI.equalsIgnoreCase(algoStr) || Helper.isEmpty(algoStr)` branch:
`AStarBidirection`, approximated by `LMApproximator.forLandmarks(...)` with
`epsilon` 1.

Traversal is `NODE_BASED`: `getAlgoOpts` chooses edge-based only when the
profile has turn costs, the profile declares none, and the graph agrees —
`properties.txt` records `graph.turn_encoded_values=[]`.

## Landmarks

| | |
|---|---|
| prepared landmarks | 16 (GraphHopper's default) |
| active per request | 8 (`RouterConfig.activeLandmarkCount`, never overridden) |
| preparation weighting | `LM_BFS\|custom\|CustomWeighting` over the profile model |
| storage | `landmarks_foot`, 3,145,828 bytes |
| subnetworks | 1 |

Measured effect, Douglas seafront to a point 1.5 km inland, median of seven:

| request | visited nodes, LM on | with `lm.disable` | LM's benefit |
|---|---|---|---|
| no custom model | 192 | 1,290 | **6.7×** |
| one real corridor at 0.05 | 1,888 | 4,162 | **2.2×** |
| one real corridor at 0.2 | 1,276 | 3,158 | **2.5×** |
| `distance_influence: 2000` | 620 | 620 | **none** |

The first three rows settle the open question: landmarks keep working under
Looper's avoidance models, and the config comment is correct.

The last row is the real finding, and it is the case GraphHopper's warning is
about. `LMApproximator` returns
`Math.max(lmApproximation, beelineApproximation.approximate(v))`, where the
landmark term is expressed in the units of the *prepared* weighting and is
never rescaled to the query weighting. Looper's lower-bound model
(`LOWER_BOUND_DISTANCE_INFLUENCE = 2000`, in
[avoidance.ts](../src/loops/avoidance.ts#L221)) adds roughly two weight units
per metre, so the prepared-weighting bound is technically valid and
numerically useless; the beeline term is the one doing the work, which is why
the count is identical with landmarks switched off. Nothing is broken — those
requests simply pay flexible-mode prices, and there are few of them.

## How a request custom model stays compatible with the prepared landmarks

`LMSolver.createPathCalculator` calls
`FindMinMax.checkLMConstraints(profile.getCustomModel(), request.getCustomModel(), lookup)`
before building the algorithm. It enforces exactly two things:

- every `multiply_by` in the request's `priority` and `speed` must evaluate
  within `[0, 1]`, so a request may only ever *raise* an edge's weight;
- the request's `distance_influence` must be at least the profile's.

An admissible heuristic stays admissible when weights only go up, which is why
the preparation remains valid. Looper's models satisfy this by construction —
`AVOID_PRIORITY` is 0.05, `RELAXED_AVOID_PRIORITY` is 0.2, and the profile's
`distance_influence` is unset, so 0. The comment in `config.yml` claiming
landmarks "stay valid as long as a request only ever lowers priority" is
describing this check, accurately.

The request model is combined with the profile's by `CustomModel.merge` in
`DefaultWeightingFactory.createWeighting`, then compiled by
`CustomModelParser.createWeightingParameters` — Janino generates and compiles a
Java class per distinct model — and wrapped in a `CustomWeighting`.

## Snapping and the query graph

`ViaRouting.lookup` builds a `DefaultSnapFilter` from the weighting and the
profile's `foot_subnetwork` flag, wraps it in `SnapPreventionEdgeFilter` for
Looper's `['ferry']`, and calls `LocationIndexTree.findClosest` once per point.
`QueryGraph.create` then inserts a virtual node per snap along with the virtual
edges either side of it, which is what lets a leg begin and end mid-edge.

The virtual-node position, not the requested coordinate, is what a leg actually
starts from; it is reported back as `snapped_waypoints` and is compared
exactly in the equivalence run.

## Graph and encoded values

35,088 nodes, 42,016 edges, one routable subnetwork of 77,152 edges plus one of
912 (`prepare.min_network_size: 200` marked 3,950 fragments as unroutable).

`config.yml` asks for ten encoded values. The import stores **seventeen**, in 9
bytes of flags per edge:

| asked for in config | added by GraphHopper itself |
|---|---|
| `foot_access`, `foot_priority`, `foot_average_speed`, `foot_road_access`, `hike_rating`, `mtb_rating`, `country`, `road_class`, `road_environment`, `surface` | `roundabout`, `car_access`, `road_class_link`, `max_speed`, `foot_network`, `ferry_speed`, `foot_subnetwork` |

The extra seven are pulled in as dependencies of the foot parsers, the
instruction generator and the subnetwork preparation. Two of them are
load-bearing for Looper whether or not anyone asked for them:
`foot_subnetwork` is what `DefaultSnapFilter` reads, and `road_environment` is
what `SnapPreventionEdgeFilter` reads to honour `snap_preventions: ['ferry']`.

Note that `foot_priority` is stored and then not used: `looper_foot.json`
deliberately replaces GraphHopper's road-class preference with its own, and
never references `foot_priority`. It costs 4 bits an edge to keep.

## What Looper requires — keep

| Subsystem | Why |
|---|---|
| `BaseGraph` + `EdgeKVStorage` | the graph, and `street_name` |
| OSM import (`OSMReader`, foot parsers, `OSMRoadClassParser` et al) | the brief forbids a bespoke importer, and access parsing is the hard part |
| the 17 encoded values above | 10 by config, 7 by dependency, at least 2 of those load-bearing |
| `PrepareRoutingSubnetworks` | `foot_subnetwork` gates every snap |
| `LocationIndexTree` | snapping |
| `SnapPreventionEdgeFilter`, `DefaultSnapFilter` | Looper sends `snap_preventions` on every leg |
| `QueryGraph` + virtual nodes/edges | every leg starts and ends mid-edge |
| `CustomWeighting`, `CustomModelParser`, Janino | avoidance is a per-request custom model |
| `FindMinMax.checkLMConstraints` | what makes LM legal under those models |
| `LandmarkStorage`, `PrepareLandmarks`, `LMApproximator`, `LMRoutingAlgorithmFactory` | 2.2–6.7× fewer settled nodes |
| `AStarBidirection`, `FlexiblePathCalculator`, `ViaRouting`, `BidirPathExtractor` | the search and the path |
| `PathDetailsBuilderFactory` for `edge_id`, `street_name`, `road_class` | `edge_id` is how [edges.ts](../src/loops/edges.ts) tells shared network from near-miss geometry |
| `InstructionsFromEdges` | the walk screen, and `sign` feeds the quality engine's u-turn test |

## What Looper never touches — candidates for removal

Confirmed unused by reading the request path, not by assumption:

| Subsystem | Evidence |
|---|---|
| Dropwizard, Jetty, Jersey, the web UI | the minimal core replaces all of it with ~100 lines of `com.sun.net.httpserver` and returns identical bytes |
| all CH classes (`CHPathCalculator`, `PrepareContractionHierarchies`, `AStarBidirectionCH`, …) | `profiles_ch: []`; `chEnabled` is false at construction |
| `RoundTripRouting` | Looper owns loop generation; the brief is explicit |
| `AlternativeRoute`, `AlternativeRouteCH` | requires `algorithm=alternative_route`; never sent |
| `Dijkstra`, `DijkstraBidirectionRef`, `AStar`, `DijkstraOneToMany` | unreachable: the LM factory accepts only `astar`, `astarbi`, `alternative_route`, and Looper sends none, taking the `astarbi` default |
| isochrone / SPT endpoints | `networkAwareSeeds` is `false` in `DEFAULT_FLAGS`, so `reachFrom` is never called |
| map matching, GTFS, navigation API | separate modules, not depended on |
| car / bike / truck profiles and their parsers | only `foot` is configured (`car_access` is still imported as a parser dependency) |
| elevation | `elevation: false` in the request; no provider configured |
| turn costs / turn restrictions | `graph.turn_encoded_values=[]`; traversal is node-based |
| `MaxSpeedCalculator`, country rules | `max_speed_calculator.enabled` and `country_rules.enabled` both default false |

`country` is the one to be careful with: `looper_foot.json` names it in the
German bridleway rule, so the encoded value must stay even though the country
*rule factory* is off.

## Dependency footprint

`graphhopper-core` 11.0 pulls: `hppc`, `janino` + `commons-compiler` (custom
model compilation), `jts-core`, Jackson core/databind/annotations/dataformat-xml
+ `jackson-datatype-jts`, `xmlgraphics-commons` + `commons-io`,
`osm-legal-default-speeds` + `kotlin-stdlib`, `osmosis-osm-binary` +
`protobuf-java`, `slf4j-api`.

`kotlin-stdlib` and `osm-legal-default-speeds` are there for
`MaxSpeedCalculator`, which is disabled. `xmlgraphics-commons` is for elevation
data, which is disabled. `osmosis-osm-binary` and `protobuf-java` are the PBF
reader, needed only at import time. None of these are on the routing path — a
later phase that separates import from serve could drop all of them from the
serving artifact.
