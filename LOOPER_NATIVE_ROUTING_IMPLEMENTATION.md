# Looper native on-device routing — implementation report

## 1. Files changed

Everything new is in `ios/LooperKit/Sources/LooperKit/NativeRouting/`.

**New — routing engine (20 files)**

`GeographicBounds.swift`, `RoutingChunkID.swift`, `OSMData.swift`,
`RoutingLog.swift`,
`PedestrianAccessPolicy.swift`, `RoutingChunkCodec.swift`,
`RoutingChunkStore.swift`, `RoutingDataSource.swift`,
`RoutingDataManager.swift`, `RoutingAudit.swift`, `LocalWalkingGraph.swift`,
`LocalEdgeIndex.swift`, `LocalExploration.swift`, `WalkSearchGraph.swift`,
`WalkStateStore.swift`, `WalkSearch.swift`, `WalkUTurns.swift`,
`RouteQuality.swift`, `RouteDiversity.swift`, `LocalInstructions.swift`,
`LocalLoopRouter.swift`, `LoopRoutingEngine.swift`

**New — tests (6 files)**

`LocalRoutingFixtures.swift`, `LocalRoutingDataTests.swift`,
`LocalRoutingChunkingTests.swift`, `LocalRoutingSearchTests.swift`,
`OnDeviceRoutingTests.swift`, `RoutingProviderFailoverTests.swift`,
`LiveOverpassMeasurementTests.swift`

**Modified — five files, all in the iOS app**

| File | Change |
| --- | --- |
| `LooperKit/Sources/LooperKit/Models.swift` | Added `RoutingEngine.onDevice` and `serverValue`; marked the route model `Sendable` |
| `LooperKit/Sources/LooperKit/Networking.swift` | `LoopsHTTPClient: Sendable`. No change to the request, the response, or the URL |
| `Looper/Looper/App/AppModel.swift` | Routing-mode preference; requests go through `LoopRoutingEngine`; download progress; routing-data summary |
| `Looper/Looper/Screens/SettingsView.swift` | The Remote / On-device toggle; a downloaded-paths screen |
| `Looper/Looper/Screens/PlannerView.swift` | Uses `model.findingMessage` so the download state can be shown |

## 2. Backend files were untouched

```console
$ git diff --stat -- route-service web dist map-styles.json
(no output)

$ git status --porcelain | grep -v build
 M ios/Looper/Looper/App/AppModel.swift
 M ios/Looper/Looper/Screens/PlannerView.swift
 M ios/Looper/Looper/Screens/SettingsView.swift
 M ios/LooperKit/Sources/LooperKit/Models.swift
 M ios/LooperKit/Sources/LooperKit/Networking.swift
?? ios/LooperKit/Sources/LooperKit/NativeRouting/
?? ios/LooperKit/Tests/LooperKitTests/*
```

**NO CHANGES** to `route-service/`, `web/`, `dist/` or `map-styles.json`. No
endpoint was added, no proxy was added, no server configuration was touched,
and nothing sends `routingEngine=onDevice` to the service — `serverValue`
returns `nil` for it, so the request body is byte-identical to the one the
service has always been sent.

The Java Phase 10 implementation in
`route-service/gh-harness/src/main/java/com/looper/routing/direct/` was read as
the golden reference and not modified.

## 3. External OSM source

The **Overpass API**, contacted by the iPhone directly. Default endpoint
`https://overpass-api.de/api/interpreter`, behind:

```swift
protocol RoutingDataSource: Sendable {
    func fetchArea(_ bounds: GeographicBounds) async throws -> OSMData
}
```

Overpass is a **data source**. It is never asked for a route. Nothing below the
protocol knows a hostname; swapping in a commercial Overpass-compatible
endpoint changes one `URL` and nothing else in the store, the graph or the
router.

### Correction: what shipped first was fragile, and it broke

The first version of this work configured **one** endpoint, logged nothing to
the system log, and mapped several per-connection URL errors to "the device is
offline". All three were wrong, and they combined into a failure that presented
as *the app simply not downloading anything*:

1. Development measurement runs got the address **blocked by
   `overpass-api.de`**, which stops answering rather than refusing politely.
2. With one endpoint there was nowhere to fail over to.
3. Nothing was written to the unified log, so from inside the app the only
   symptom was a progress message that never resolved. `RoutingAudit` was
   collecting exactly the right numbers and showing them to nobody.
4. When it did fail, `cannotConnectToHost` was classified as `offline`, so the
   walker was told to *"Connect to download it"* while connected.

What changed, all in the data-source layer:

- **`Configuration.endpoints: [URL]`**, tried in order, moving on for a
  connection failure, a 429 or any 5xx. A commercial provider is still a
  one-element list and no other change.
- **`totalDeadlineSeconds`** (default 90 s). Three providers × two attempts ×
  a 70 s timeout is nearly eight minutes of a button reading "Downloading
  walking paths for this area…"; a real first download of a town takes well
  under a minute, so the budget is generous to success and merciless to
  failure.
- **`RoutingDataSourceError.providerUnavailable`**, distinct from `.offline`,
  with its own honest message and its own handling — only `.offline` produces
  the "not available offline" text.
- **Error classification corrected.** `networkConnectionLost` is per-connection
  and now fails over; treating it as device-level abandoned the provider search
  on the first dropped socket, silently defeating the failover.
- **`RoutingLog`**, the unified-log side of the audit the brief asked for.

Verified in the app. All three public providers were failing from the test
machine at the time, and the app now says so, promptly and correctly:

```text
coverage target=4000m radius=2240m required=25 cached=0 missing=25 requests=1
osm fetch begin source=Overpass bbox=54.1238,-4.5703,54.1882,-4.4604 providers=3
osm fetch failed host=overpass-api.de attempt=1 reason=Could not connect to the server.
osm fetch failed host=overpass-api.de attempt=2 reason=Could not connect to the server.
osm provider exhausted host=overpass-api.de
osm fetch host=overpass.kumi.systems status=500 attempt=1
osm fetch host=overpass.kumi.systems status=500 attempt=2
osm provider exhausted host=overpass.kumi.systems
osm fetch gave up attempts=4 reason=Tried 3 providers; last error was HTTP 500
coverage failed reason=Tried 3 providers; last error was HTTP 500
```

`RoutingProviderFailoverTests` covers all of it: failover on outage, on 429 and
on 5xx; a dropped connection moving on rather than aborting; a device-offline
error stopping immediately; the bounded deadline; the message not claiming the
walker is offline; and a failed fetch still being audited and still making zero
Looper routing calls.

## 4. Overpass query strategy

```text
[out:json][timeout:90];
way["highway"](SOUTH,WEST,NORTH,EAST);
(._;>;);
out body qt;
```

- `way["highway"](bbox)` — the ways whose geometry intersects the area.
- `(._;>;)` — every node those ways reference, **including nodes outside the
  box**. Without this a lane leaving the area arrives with its far end missing
  and the graph dead-ends at the edge of the request.
- `out body qt` — Overpass's cheapest ordering; nothing here depends on
  element order.

POSTed form-encoded. Parsing keeps only ways carrying a `highway` tag and only
the tags the access policy and the instruction generator read — in a typical
extract 95% of nodes are pure geometry, and an empty tag dictionary each is
most of the parse cost.

An Overpass `remark` naming a timeout or a memory limit is raised as an error
rather than read as "this area has no paths". Retries use exponential backoff
with jitter on 429/503/504; a 4xx or an offline error is not retried.

## 5. Spatial chunk design

Web Mercator XYZ at **zoom 14** — about **1,437 m** square at 54°N.

`RoutingChunkID { z, x, y }`, deterministic, filename-safe key `z-x-y`.

Required coverage for a target `D`: `D × (1 + 0.12) / 2 = D × 0.56` of network
distance, plus a 300 m chunk-boundary margin. Measured chunk counts around
Douglas: 3 km → 16, 5 km → 36, 8 km → 64.

**Zoom choice.** z14 was kept after measuring. z13 (~2.9 km chunks) would put a
5 km walk at 9–16 chunks instead of 36, but the same walk would then pull in
about 2.3× the ground, and eviction would work in 2.9 km blocks. 36 chunks is
one Overpass request either way — the grouping logic makes the chunk count
almost irrelevant to network cost — so the finer grid was kept for its finer
caching and eviction granularity.

**Request grouping.** Missing chunks are split into 4-connected components, so
two clusters either side of a cached town centre stay two requests rather than
one that re-fetches the middle. Each component is asked for whole when its
bounding box is at least 60% missing, and split down its longer axis when it is
not — otherwise a diagonal string of five chunks would request the 25-chunk
square it spans. Capped at 48 chunks per request.

**Splitting the response.** Each chunk stores every way with at least one node
inside it, and every node those ways reference — including nodes in
neighbouring chunks. That halo makes each chunk self-contained.

An empty chunk is stored as an empty chunk, so open sea is not re-requested on
every walk from that beach.

## 6. Cache implementation

`RoutingChunkStore`, an actor over a directory in Application Support:
`index.json` plus one `<z>-<x>-<y>.lprc` per chunk.

The chunk format is hand-rolled binary with a string table — the same two dozen
tag keys repeat on every way in a chunk, and JSON stores `"highway"` in full
several thousand times. Coordinates are stored as scaled `Int32` (about 1 cm,
finer than OSM records, half the bytes of a `Double`). Measured at roughly a
fifth of the equivalent JSON.

The format carries a version. A chunk from an older generation is treated as
absent and re-fetched rather than migrated — for cache data that is both safer
and much less code.

Each chunk records id, data version, download date, last-used date, byte size,
retention, and node/way counts. A 64-chunk in-memory read-through cache avoids
re-decoding the same two dozen chunks on consecutive requests from one doorstep.

Eviction drops the coldest `automatic` chunks against a 192 MB budget. Pinned
chunks are neither counted nor candidates.

## 7. Future pinned offline areas

Supported by the data architecture today; only the UI is absent.

- `RoutingChunkStore.Retention` is `.automatic` or `.pinned`.
- `RoutingDataManager.downloadOfflineArea(bounds)` fills and pins, including
  chunks already present — the walker asked for the area, not for the part of
  it they had not visited yet.
- An automatic refetch of a pinned chunk stays pinned.
- `OnDeviceLoopRoutingEngine.downloadOfflineArea(_:onProgress:)` exposes it.

The router cannot tell how a chunk arrived, because there is nothing to tell:
it reads the store. Tested in
`testPinnedChunksSurviveEvictionAndAutomaticOnesDoNot` and
`testAnOfflineAreaDownloadPinsEverythingItCovers`.

## 8. Pedestrian filtering

One component, `PedestrianAccessPolicy`, applied when the **graph is built**,
not when data is stored — so correcting a rule re-reads data already on the
phone instead of invalidating it.

- Walkable by default: `footway`, `path`, `pedestrian`, `steps`, `residential`,
  `living_street`, `service`, `track`, `unclassified`, `tertiary`, `secondary`,
  `primary`, `road`, `bridleway`, `corridor`.
- Refused unconditionally: `motorway`, `motorway_link`, `trunk`, `trunk_link`,
  `construction`, `proposed`, `raceway`, `busway`, `platform` and the rest.
  A `foot=yes` on a motorway is a tagging error, not an invitation. The one
  exception OSM genuinely uses is `trunk` + explicit `foot=yes`.
- `foot` has the last word; then `access`, with `no`/`private`/`restricted`/
  `military`/`delivery`/`customers` blocking and `permissive`/`destination`/
  `designated` allowing.
- `cycleway` with nothing said about feet is **not** assumed walkable, matching
  GraphHopper's foot profile.
- `indoor=yes` and `area=yes` are excluded: a shopping centre's floor plan is
  not a route through a town.
- `oneway` is a traffic rule, not a walking rule — walkers use both pavements.
  Only `oneway:foot` restricts, plus `conveying` on an escalator.
- Node barriers: gates pass unless `locked=yes`; walls, fences, hedges,
  guard rails and kerbs block; stiles, kissing gates, bollards and cattle grids
  pass. A blocking node severs the way — the two sides get separate node
  identities.

GraphHopper's published foot behaviour was the reference for ambiguous
semantics. GraphHopper is not linked, downloaded, run, or called.

**What the policy actually excludes**, measured over the 7,262 ways the app
downloaded around Braddan and Douglas — 93% are walkable:

| Reason | Ways | Share |
| --- | --- | --- |
| `access=private` | 213 | 2.9% |
| motorway-class | 176 | 2.4% |
| `area=yes` | 37 | 0.5% |
| cycleway with no `foot` | 20 | 0.3% |
| `foot=no` | 12 | 0.2% |
| `access=no` / `customers` | 18 | 0.2% |
| `indoor=yes` | 2 | < 0.1% |

`access=private` is the largest single exclusion, and it is worth flagging
rather than burying — see limitation 11 in §23.

## 9. Graph representation

Structure-of-arrays:

```text
nodes   nodeOSMID[]  nodeLat[]  nodeLon[]
edges   edgeFrom[]  edgeTo[]  edgeMetres[]  edgeForward[]  edgeBackward[]
        geometryStart[] → geometry[]  (flat lon/lat)
        edgeName[] → names[]   edgeRoadClass[]   edgeWayID[]
arcs    arcStart[] (CSR)  arcEdge[]  arcTo[]  arcForward[]
```

Only junctions become nodes; intermediate vertices are geometry. Each edge
carries endpoints, metres, walk direction, geometry, street name, road
classification, and the OSM way id — the physical identity that repeated-ground
accounting is decided on. Node identity is the OSM node id.

## 10. Chunk-boundary handling

Node identity is global, so merging chunks joins their ways automatically. No
geometric stitching, no seam.

Tested:

| Case | Test |
| --- | --- |
| Way crossing one boundary is stored whole in both chunks | `testAWayCrossingAChunkBoundaryIsStoredWholeInBoth` |
| The merged graph is one 3 km edge, not two stubs | `testTheGraphIsContinuousAcrossChunksAndTruncatedWithoutThem` |
| A 4 km lattice across several chunks in both directions is one network | `testALatticeSpanningManyChunksRoutesAsOneNetwork` |
| A start on the corner where four chunks meet reaches all four quadrants | `testAStartOnAFourChunkCornerStillSeesTheWholeNetwork` |

The last is the decisive one: exploring from the seam reaches every one of the
225 lattice junctions.

## 11. Snapping

`LocalEdgeIndex`, a uniform ~150 m grid over edge bounding boxes as a CSR,
queried outward a ring of cells at a time and stopping once no unexamined cell
can hold anything closer.

Snapping reaches the **interior** of an edge: junctions on a residential street
sit 80–150 m apart, so snapping to the nearest one can move the start further
than the width of the street the walker is on. A start mid-edge splits it into
two halves that both keep the base edge's identity — what GraphHopper's
QueryGraph does, so repeated-ground accounting still means what it meant.

Measured snap distances on real data: **under 10 m** at all three towns.

## 12. Local Dijkstra results

`LocalExploration` runs a bounded Dijkstra to `D × 0.56`, producing exact
`home` distances (which is what makes the search's distance prune exact rather
than heuristic), and reports diagnostics: nodes and edges loaded, nodes and
edges reached, snap distance, limit, elapsed ms, graph bytes.

On real data, from the town centres:

| Place | Target | Graph loaded | Explored | Snap |
| --- | --- | --- | --- | --- |
| Douglas | 3 km | 8,538 nodes / 10,568 edges | 3,757 nodes | < 10 m |
| Douglas | 5 km | 11,230 / 13,705 | 5,739 nodes | < 10 m |
| Douglas | 8 km | 12,326 / 14,918 | 9,824 nodes | < 10 m |
| Peel | 5 km | 2,038 / 2,460 | 1,280 nodes | < 10 m |
| Onchan | 5 km | 10,528 / 12,922 | 4,357 nodes | < 10 m |

## 13. Phase 10 algorithm port

Ported, not reinvented. The Java `direct` package was the golden reference and
was not modified. What was ported, and where:

| Reference | Swift |
| --- | --- |
| `SearchGraph.java` | `WalkSearchGraph.swift` |
| `StateStore.java` | `WalkStateStore.swift` |
| `WalkSearch.java` | `WalkSearch.swift` |
| `UTurns.java` | `WalkUTurns.swift` |
| `DirectWalks.java` | `LocalLoopRouter.swift` |
| `quality.ts` | `RouteQuality.swift` |
| `diversity.ts` | `RouteDiversity.swift` |

The operating point is unchanged: beam 300, 100 m distance bands, 3 survivors
per node, compass-octant diversity quota, 0.05 turn penalty, minimum
compactness 0.20, at most 1 u-turn, `MAX_DISTANCE_ERROR` 0.12, bounding-box
ratio 4.5, maximum shared fraction 0.55.

Both graph reductions are exact: the 2-core peel (a rooted circuit cannot enter
a dead end and come back out without a fatal reverse retrace) and degree-2
contraction. Both exact prunes are kept: a spent super-edge is not offered, and
`distance + home > max` is discarded. Bands are drained rather than visited.

Three things differ, and each is a consequence of the graph underneath rather
than a change to the algorithm:

1. **One edge identity instead of two.** The Java kept QueryGraph ids and base
   ids separately. Here a subgraph edge id addresses geometry and `physical`
   addresses ground; they diverge only at the start-split edge, and diverge the
   same way.
2. **The band map is a flat array.** Bands are drained in increasing order and
   a state's band is never below the one it was generated in, so a forward
   cursor over an array is exactly the Java's `TreeMap`, without the tree.
3. **The search budget is 2,000,000 expansions**, not 4,000,000 — a phone's
   battery is a constraint a server does not have. No fixture has reached it.

The state store's split lifetimes are kept: parent and arc for the whole
search; ranking columns released chunk by chunk as bands pass. Measured peak
state storage on real data: **2.3–4.9 MB**.

## 14. Route reconstruction

The searched edge sequence **is** the route. Nothing is re-routed and nothing
is sent anywhere — Phase 9 measured that handing a searched walk back to a
router as via points returns something 1,486 m away at median, agreeing on 15%
of its edges, with none of twelve passing the gate.

Geometry is assembled from the subgraph edges in walking order — stem out, the
circuit, stem back — each oriented the way it was walked. Legs come from the
subgraph rather than the base graph, which matters at exactly one place and
matters a lot there: a walk starting mid-street begins on half an edge, and
only the subgraph holds the half. Distance is the sum of edge metres; duration
uses 5 km/h, GraphHopper's foot speed, so two engines' answers of the same
length quote the same time.

## 15. Navigation instructions

Generated on-device from edge geometry, incoming/outgoing bearings, street
names and junction topology. Thresholds: <20° continue, <45° bear, <120° turn,
<160° sharp, otherwise turn around; plus arrival.

Emitted into the app's existing `Step` model, following its convention that a
step's instruction is the manoeuvre at its *start* and the step carries the
road it then walks — so `turnKind`, `tidySteps`, `reverseRoute`, the walk
screen, the spoken guidance and the Watch all work unchanged. A road bending
round is not an instruction; consecutive edges on the same road with no real
turn become one step. An unnamed stretch still gets a usable instruction, and
steps are named as steps.

Real routes produced 22–104 steps depending on length.

## 16. The Remote / On-device seam

```swift
protocol LoopRoutingEngine: Sendable {
    func generateLoops(_ request: LoopRequest) async throws -> LoopResponse
}
```

`RemoteLoopRoutingEngine` wraps the existing `requestLoops` — same URL, same
body, same response handling, unchanged.

`OnDeviceLoopRoutingEngine` uses only `RoutingDataManager`,
`RoutingChunkStore`, `LocalWalkingGraph` and `LocalLoopRouter`. It holds **no**
`LoopsHTTPClient`, **no** API base, and **no** reference to the remote engine.
Its initialiser cannot be given one. The engine is chosen in exactly one place,
`AppModel.findRoutes()`.

The rest of the app consumes the same `Route` model from either, so the map,
walk screen, guidance, Watch and favourites behave identically. A `Route`
carries `routingEngine`, so a saved favourite remembers which engine drew it.

## 17. The toggle

Settings → Temporary testing:

```text
Routing engine
  ○ Remote / Current      ← default
  ● On-device / New
```

Persisted under `routing-mode`, defaulting to `.remote`. When Remote is
selected a second row still chooses between the service's own two generators
(Current / Direct search) — a choice *within* Remote, not an alternative to it,
and hidden when On-device is selected because nothing is being asked of the
service at all then.

Also added: **Downloaded walking paths** — areas stored, how many are kept for
offline, bytes on the phone, the last on-device search's diagnostics, and a
clear button.

## 18. First-download measurements

Real Overpass, cold cache, from each town centre:

| Place | Target | Radius | Chunks | Cached | Missing | Requests | Downloaded | Ways | Nodes | Stored |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Douglas | 3 km | 1,680 m | 16 | 0 | 16 | 1 | 4.0 MB | 5,925 | 26,541 | 1.0 MB |
| Douglas | 5 km | 2,800 m | 36 | 0 | 36 | 1 | 5.3 MB | 7,789 | 36,893 | 1.4 MB |
| Douglas | 8 km | 4,480 m | 64 | 0 | 64 | 2 | 6.3 MB | 8,662 | 45,700 | 1.7 MB |
| Peel | 5 km | 2,800 m | 36 | 0 | 36 | 1 | 1.3 MB | 1,398 | 10,106 | 0.4 MB |
| Onchan | 5 km | 2,800 m | 30 | 0 | 30 | 1 | 5.0 MB | 7,291 | 35,477 | 1.4 MB |

Loaded graph, and what the search did:

| Place | Target | Graph | Walkable ways | Super-edges | Closed walks | Offered | Search | Total | Peak |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Douglas | 3 km | 8,538 n / 10,568 e | 5,562 / 5,925 | 3,009 | 76 | 3 | 921 ms | 1,029 ms | 2.3 MB |
| Douglas | 5 km | 11,230 / 13,705 | 7,281 / 7,789 | 4,239 | 86 | 2 | 1,890 ms | 2,041 ms | 3.0 MB |
| Douglas | 8 km | 12,326 / 14,918 | 7,957 / 8,553 | 6,507 | 174 | 2 | 3,824 ms | 4,096 ms | 4.9 MB |
| Peel | 5 km | 2,038 / 2,460 | 1,317 / 1,398 | 849 | 36 | 2 | 458 ms | 539 ms | 1.8 MB |
| Onchan | 5 km | 10,528 / 12,922 | 6,836 / 7,291 | 2,933 | 98 | 3 | 749 ms | 876 ms | 2.4 MB |

Sample routes, Douglas 3 km: *South-west loop* 2,980 m (22 steps), *North
loop* 2,978 m (42 steps), *South loop* 3,104 m (35 steps).

### In the app, on the simulator

The engine was also run from the app itself, with the toggle set to On-device
and the default Isle of Man start (Braddan), 4 km. The app contacted Overpass
directly, and its own container ended up holding:

```console
$ ls "…/Library/Application Support/RoutingChunks"
24 × .lprc + index.json   —   1.4 MB
```

No Looper routing call was made. The routing **data** path is therefore proved
in the real app and not only in tests. That run offered no loops, which §23
covers — it is the finding, not a failure of the plumbing.

**This is the number the architecture exists to produce.** A 5 km walk in
Douglas costs a **5.3 MB download and 1.4 MB stored** — the streets around
Douglas. The Isle of Man PBF alone is tens of megabytes and a GraphHopper graph
built from it is larger again; England is gigabytes. Nothing of that kind is
downloaded, and the acquisition layer has no way to request it.

Measured on macOS (arm64). On-device timings will differ; §24 has this as the
first thing to measure on real hardware.

## 19. Warm and offline measurements

A second request over ground already stored makes **zero** HTTP requests, to
anybody, and the routing data is read from disk (then from an in-memory cache
on subsequent requests within a session).

Asserted in `testOnlyMissingChunksAreFetchedAndTheSecondRequestIsFree`, which
fails if the transport is touched at all, and in the live measurement, which
re-runs the whole coverage check against an endpoint pointed at an invalid host
so that any request would fail loudly.

The built graph is cached between requests keyed by the chunk set, so a second
set of loops from the same doorstep skips graph construction entirely.

**Partial reuse, measured.** Asking Douglas for 5 km after a 3 km request found
16 of the 36 chunks already stored and fetched only the 20 missing — 2.6 MB
instead of 5.3 MB. It took 8 Overpass requests to do it, because 20 chunks
forming a *ring* around a cached core is genuinely not one rectangle: the
component's bounding box is only 56% missing, so the splitter divided it rather
than re-fetch the middle. That is the grouping rule working as designed, and it
is the right trade — but a ring is its worst case, and if field use shows rings
are common the dial to revisit is the 60% fill threshold.

## 20. Airplane-mode test

Automated end to end in
`testACachedAreaRoutesWithNoNetworkAtAllAndAfterARestart`:

1. On-device selected, Douglas, 3 km.
2. The app fetches only the required chunks from the OSM data source.
3. Stores them.
4. Generates three routes locally.
5. **The store is discarded and rebuilt from the same directory** — which is
   exactly what a force-quit and relaunch produces.
6. The transport is replaced by one that fails the test if it is used at all.
7. The same walk is requested again.

Result: three routes, with instructions, and:

```text
Overpass HTTP calls        = 0
Looper routing HTTP calls  = 0
GraphHopper HTTP calls     = 0   (there is no GraphHopper client on the phone)
```

**Still to do on hardware:** the same sequence on a real iPhone with airplane
mode actually engaged, including opening the walk/navigation screen. The
automated test proves the routing stack needs no network; it cannot prove the
OS-level behaviour of the app around it. This is the first item in §24.

## 21. Uncached-offline test

`testAnUncachedAreaOfflineSaysSoRatherThanRoutingRemotely`: networking refuses
every request, the area has no chunks, On-device is selected.

Result: `AcquisitionError.dataUnavailableOffline` —

> Routing data for this area isn't available offline yet. Connect to download
> it, or switch to Remote routing.

Not a silent remote route. A `LoopsHTTPClient` that fails the test if touched
is present throughout and is never touched.

## 22. Proof of zero Looper routing requests

Three independent mechanisms:

1. **Structural.** `OnDeviceLoopRoutingEngine` holds nothing that could reach
   Looper's service. There is no code path to construct.
2. **Measured.** `RoutingAudit` counts Overpass requests (at the data source)
   and Looper routing requests (at the HTTP client, via
   `AuditingLoopsHTTPClient`, which the app now wraps around its real client).
   `testTheOnDeviceEngineNeverReachesTheLooperRoutingService` runs two full
   local requests and asserts `looperRoutingCallCount == 0`, that
   `overpassCallCount > 0` (it did do work), and that every endpoint contacted
   was the configured OSM provider — then runs the *remote* engine through the
   same audit and asserts the counter goes to 1, so a zero is a real zero and
   not a broken counter.
3. **Guarded.** A `ForbiddenLoopsClient` that fails the test on any call is
   present in the offline tests.

## 23. Known limitations

1. **Fewer than three loops are often offered, for two distinct reasons.**
   This is the headline finding. It is a property of the search-and-select
   stage, not of the data architecture. Counts below are from real data.

   **(a) The diversity selector, in a dense town.** Douglas 5 km closes 86
   walks; 24 are rejected on u-turns, 5 by the gate, and **19 pass the gate** —
   but only 2 survive the rule that offered walks share no more than 55% of
   their ground and leave by different streets. There is no shortage of good
   walks; there is a shortage of *different* ones, because Douglas funnels
   every loop through the same few streets.

   **(b) The gate's doorstep-spur rule, from a residential address.** The app's
   default start sits on a street peeled out of the 2-core, giving a 169 m
   doorstep stem walked out and back. The gate rejects a start stub longer than
   `max(150 m, 4% of the route)` unless it is over 500 m. So:

   | Target | Stub limit | Closed walks | Passed gate | Offered |
   | --- | --- | --- | --- | --- |
   | 3 km | 150 m | 82 | 0 | 0 |
   | 4 km | 150 m | 98 | 0 | 0 |
   | 5 km | 200 m | 96 | 13 | 2 |

   Every walk under about 3.75 km from that address fails on `start-spur`
   alone, because 169 m > 150 m. At 5 km the limit rises past 169 m and walks
   start passing. The cliff is exact and reproducible.

   Finding (b) independently reproduces a result recorded from earlier work on
   this codebase — the same address, the same 169 m, the same rule — which is
   good corroboration that the port behaves like the engine it was ported from.

   Both rules are the route service's own, ported unchanged, and **neither was
   relaxed** — a local engine offering walks its remote counterpart would
   refuse would look better in testing for exactly the wrong reason. Whether
   the remote engine hits (b) as hard from the same address is an open question
   this work did not test, and worth answering early: if it does, the dial to
   revisit is `spurLimitMetres`' 150 m floor **in the route service**, which is
   outside this task's boundary.
2. **Search time is 0.5–4 s** on macOS for 3–8 km. Unmeasured on device, and
   8 km is the case to watch.
2a. **The "Downloading walking paths…" message can sit for up to 90 seconds**
   before failing, when providers are unresponsive. Bounded now, but still a
   long silence: it does not say which attempt it is on. Threading the provider
   attempt through `LoopDataProgress` would fix it and was left out as scope.
3. **The public Overpass endpoints are not dependable, and this bit.** A
   handful of 5–8 km bounding-box queries over a few minutes was enough to get
   the address blocked by `overpass-api.de` — it escalated 504 → connection
   refused, and stayed refused. At the time of writing all three configured
   public providers were failing from the test machine (`overpass-api.de`
   refusing connections, the other two returning 500/502) while the general
   internet was fine.

   The app now survives this properly and reports it accurately, but **no
   amount of failover makes three volunteer instances a production backend**.
   Moving to a commercial Overpass-compatible provider should happen before any
   wider testing, not before release. It remains untested against a real
   commercial provider.

   A consequence worth knowing: while all providers are down, On-device routing
   works **only** for areas already cached. That is correct behaviour, and it
   is also the strongest argument for building the Offline Areas UI sooner
   rather than later — the store, retention and download method are already
   there.
4. **Chunk data is never refreshed.** A stored chunk is valid forever until
   evicted. There is no age-based invalidation, so a newly-mapped path will not
   appear until the chunk is evicted or the data version is bumped.
5. **No Offline Areas UI.** The store, retention and download method exist and
   are tested; the screen does not.
6. **Ordered waypoints take a separate path.** The closed-walk search has no
   answer to them, so they are not asked to: `LocalWaypointRouter` routes the
   backbone gap by gap on the raw graph with `LocalLegRouter` and spreads the
   slack with `LocalWaypointPlanner`, a port of the service's `waypoints.ts`.
   Judged by the same gate, one tolerance apart, and that tolerance is the
   service's own. (The route service's own `direct` generator still declines
   them and falls back to `remote`; it has GraphHopper locally, so the
   fallback is invisible and cheap.)
7. **No turn restrictions.** OSM turn-restriction relations are not read.
   Little practical effect on foot, but it is a real omission.
8. **Instructions are basic** by choice — no roundabout counting, no exit
   numbering, no distance-to-turn phrasing beyond what the app already derives.
9. **Chunk node ids are stored as raw `Int64`.** Delta-and-varint encoding
   would cut stored size materially and was left out to keep the codec simple.
10. **`AppModel` still holds `apiBase` and an HTTP client** because the remote
    engine needs them. The *engine* does not, which is where the guarantee
    lives, but the model is not itself proof of anything.
11. **`access=private` is excluded, and that may diverge from the remote
    engine — a decision worth taking deliberately.** The brief asked for
    private roads to be handled and for pedestrian-prohibited roads to be
    rejected, so they are. But earlier work on this codebase recorded that the
    remote direct engine reads GraphHopper's weighting only as an access
    filter and therefore *searches* private ways at true length, and that
    excluding them broke agreement with the golden oracle. Measured here,
    `access=private` is 2.9% of ways around Douglas — the largest single
    exclusion, though smaller than the ~10% that earlier note recalled.

    If the two engines disagree on this, a Remote-vs-On-device comparison is
    confounded by a difference that has nothing to do with the search. Resolve
    it before drawing conclusions from field results, and resolve it by
    deciding which behaviour is *correct* — routing a walker up somebody's
    drive is not obviously a feature — rather than by making one match the
    other. Changing the remote side is outside this task's boundary.

## 24. Next steps for field testing

1. **Run the airplane-mode acceptance test on hardware**, exactly as specified:
   Douglas, 5 km, force-quit, airplane mode, relaunch, three routes, open the
   navigation screen. Release-blocking.
2. **Measure on-device timings** for 3/5/8 km, and memory under a real search.
   If 8 km is slow, the search budget and beam are the dials, and both are
   already parameters.
3. **Walk both engines from the same doorstep** and rate them in the existing
   Routing engine trials screen, which now records on-device answers with the
   local search's own numbers.
4. **Chase the offer rate**, which now has two specific questions rather than
   one vague one. Does the remote engine also return nothing from a 169 m
   cul-de-sac at 3 km? And in Douglas, are the 19 gate-passing 5 km walks
   genuinely 17 repeats of two walks, or is 55% too strict for a town with one
   harbour? Whether two good loops beat three similar ones is a question for
   the ground, not for the gate.
5. **Check instructions against reality** — particularly at junctions where a
   path meets a road at an angle, and on steps.
6. **Watch the download** on cellular: 5.3 MB for Douglas 5 km is fine on
   Wi-Fi and worth confirming is acceptable on a phone plan.
7. **Try a commercial Overpass-compatible endpoint before any wider testing** —
   promoted from "before release" after the public instances proved
   undependable in the space of a single day's work. One-element `endpoints`
   list, no other change.
8. **Watch the log while field testing.** `log collect --device --last 10m`,
   subsystem `com.woollams.Looper`. Every acquisition and every local search
   writes a line, and `routing.remote` staying silent is the on-device
   guarantee being observed rather than assumed.
