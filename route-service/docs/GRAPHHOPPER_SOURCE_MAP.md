# GraphHopper source map

Which GraphHopper code Looper's routing depends on, so that a later phase that
copies or extracts any of it knows what it is copying and what notice has to
travel with it.

**Version.** GraphHopper 11.0. The container pulls
`com.graphhopper:graphhopper-web:11.0` from Maven Central
(`graphhopper/Dockerfile`); the routing core module pins
`com.graphhopper:graphhopper-core:11.0` and `graphhopper-web-api:11.0`
(`gh-harness/pom.xml`). Both correspond to upstream tag `11.x` at commit
`69e50f6e2cfaf0a8e69752df9953ee5f1ac276a4` ("release 11.0", 14 October 2025).

**Licence.** GraphHopper is Apache License 2.0. Every file listed below carries
the standard GraphHopper GmbH contributor-licence header.

**Current status: nothing has been copied or modified.** As of this phase all
GraphHopper code is consumed as an unmodified Maven dependency. The
`Copied?` column exists for the phase that may change that; it currently reads
`no` on every row, and that is the finding, not an omission. Because no source
is redistributed, the obligation today is limited to preserving the
`NOTICE`/attribution shipped with the artifacts — which is satisfied by
depending on the published jars — plus the attribution in
`gh-harness/NOTICE.md`.

If any row ever changes to `yes`, that file's Apache-2.0 header must be kept
verbatim, the modification stated in a `NOTICE` file, and this table updated in
the same change.

## Routing path

All paths relative to the repository root of `graphhopper/graphhopper` at
`69e50f6e`.

| Source file | Class | Purpose for Looper | Used as | Copied? |
|---|---|---|---|---|
| `core/.../GraphHopper.java` | `GraphHopper` | load graph, hold index/LM/profiles | dependency | no |
| `core/.../GraphHopperConfig.java` | `GraphHopperConfig` | the deserialisation target for `config.yml` | dependency | no |
| `core/.../routing/Router.java` | `Router`, `Router.LMSolver`, `Router.FlexSolver`, `Router.Solver` | mode selection; proves LM hybrid is chosen | dependency | no |
| `core/.../routing/ViaRouting.java` | `ViaRouting` | ordered via points, one path per leg | dependency | no |
| `core/.../routing/FlexiblePathCalculator.java` | `FlexiblePathCalculator` | runs the algorithm per leg | dependency | no |
| `core/.../routing/AStarBidirection.java` | `AStarBidirection` | **the search** | dependency | no |
| `core/.../routing/AbstractNonCHBidirAlgo.java`, `AbstractBidirAlgo.java` | — | its base classes | dependency | no |
| `core/.../routing/BidirPathExtractor.java`, `PathExtractor.java` | — | path extraction | dependency | no |
| `core/.../routing/lm/LMRoutingAlgorithmFactory.java` | `LMRoutingAlgorithmFactory` | picks `astarbi` when no algorithm is named | dependency | no |
| `core/.../routing/lm/LMApproximator.java` | `LMApproximator` | the landmark heuristic; `max(lm, beeline)` | dependency | no |
| `core/.../routing/lm/LandmarkStorage.java` | `LandmarkStorage` | 16 landmarks, `landmarks_foot` | dependency | no |
| `core/.../routing/lm/PrepareLandmarks.java` | `PrepareLandmarks` | preparation at import | dependency | no |
| `core/.../routing/lm/LMPreparationHandler.java` | `LMPreparationHandler` | wiring from `profiles_lm` | dependency | no |
| `core/.../routing/weighting/custom/CustomWeighting.java` | `CustomWeighting` | **the weighting** | dependency | no |
| `core/.../routing/weighting/custom/CustomModelParser.java` | `CustomModelParser` | compiles the model via Janino | dependency | no |
| `core/.../routing/weighting/custom/FindMinMax.java` | `FindMinMax` | `checkLMConstraints`: why LM stays legal under avoidance | dependency | no |
| `core/.../routing/DefaultWeightingFactory.java` | `DefaultWeightingFactory` | merges profile + request custom models | dependency | no |
| `web-api/.../util/CustomModel.java` | `CustomModel` | `merge`; the avoidance model's Java shape | dependency | no |
| `core/.../routing/querygraph/QueryGraph.java` | `QueryGraph` | **virtual nodes and edges**; mid-edge starts | dependency | no |
| `core/.../storage/index/LocationIndexTree.java` | `LocationIndexTree` | **snapping** | dependency | no |
| `core/.../routing/util/DefaultSnapFilter.java` | `DefaultSnapFilter` | excludes unroutable subnetworks | dependency | no |
| `core/.../routing/util/SnapPreventionEdgeFilter.java` | `SnapPreventionEdgeFilter` | honours `snap_preventions: ['ferry']` | dependency | no |
| `core/.../storage/BaseGraph.java` | `BaseGraph` | graph storage | dependency | no |
| `core/.../storage/EdgeKVStorage.java` | `EdgeKVStorage` | `street_name` | dependency | no |
| `core/.../routing/util/parsers/*` | foot parsers, `OSMRoadClassParser`, … | **OSM import**; access parsing | dependency | no |
| `core/.../reader/osm/OSMReader.java` | `OSMReader` | PBF import | dependency | no |
| `core/.../routing/subnetwork/PrepareRoutingSubnetworks.java` | `PrepareRoutingSubnetworks` | `foot_subnetwork` | dependency | no |
| `core/.../util/details/PathDetailsBuilderFactory.java` | — | `edge_id`, `street_name`, `road_class` | dependency | no |
| `core/.../routing/InstructionsFromEdges.java` | `InstructionsFromEdges` | walk instructions and `sign` | dependency | no |
| `web-api/.../GHRequest.java`, `GHResponse.java`, `ResponsePath.java` | — | request/response model | dependency | no |
| `web-api/.../jackson/Jackson.java`, `ResponsePathSerializer.java` | — | the exact wire format | dependency | no |

## Referenced during the audit but not depended on

`web-bundle/.../resources/RouteResource.java` was read to establish what the
HTTP layer adds to a request before the router sees it — the answer is the
snap-prevention default and nothing else that Looper triggers. The minimal core
reimplements that one rule in `LooperRoutingCore.routeJsonBody`; no code was
copied.

## Looper's own code in the seam

| File | What it is |
|---|---|
| `gh-harness/src/main/java/com/looper/routing/LooperRoutingCore.java` | the narrow facade; configures and calls GraphHopper, implements nothing |
| `gh-harness/src/main/java/com/looper/routing/Harness.java` | the equivalence benchmark |
| `gh-harness/src/main/java/com/looper/routing/Serve.java` | JDK HTTP transport so a TypeScript caller can reach the core |
