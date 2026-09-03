# Looper native on-device routing — architecture

Looper now has two routing engines. The existing hosted one is unchanged. The
new one runs entirely on the iPhone: it fetches raw OpenStreetMap path data for
a small area directly from an external OSM data provider, keeps it, builds a
walking graph from it, and searches that graph for the walk.

A toggle in Settings chooses between them, so the two can be compared on real
ground before either is chosen.

## The two paths

```text
REMOTE / CURRENT — unchanged
──────────────────────────────────────────────────────────────────
  iOS app
     │  HTTPS  POST /v1/loops
     ▼
  Looper route service            (Node, unchanged)
     │
     ▼
  Production loop generator             ──►  self-hosted GraphHopper
                                              (walking graph, OSM PBF)


ON-DEVICE / NEW — nothing of Looper's is involved
──────────────────────────────────────────────────────────────────
  iOS app
     │
     │  HTTPS  (only when a needed chunk is missing)
     ▼
  External OSM data provider           RoutingDataSource
  (Overpass API — a DATA source,       └─ OverpassRoutingDataSource
   never a routing engine)
     │  raw highway ways + referenced nodes
     ▼
  RoutingChunkStore                    persistent, on device
  └─ z14 chunks, automatic | pinned
     │
     ▼
  LocalWalkingGraph                    PedestrianAccessPolicy applied here
  └─ nodes / edges / adjacency / geometry / names
     │
     ▼
  LocalEdgeIndex ──► snap              on device, no service
     │
     ▼
  LocalExploration                     bounded Dijkstra, exact home distances
     │
     ▼
  WalkSearchGraph                      2-core peel + degree-2 contraction
     │
     ▼
  WalkSearch                           beam over distance bands
     │
     ▼
  RouteQuality ──► RouteDiversity      the same gate the remote engine uses
     │
     ▼
  LocalInstructions ──► routes
```

There is no arrow from the On-device path to any Looper service, and there is
no code path that could draw one: `OnDeviceLoopRoutingEngine` holds no HTTP
client for Looper's API, no API base, and no reference to
`RemoteLoopRoutingEngine`.

## Where the code lives

Everything new is in `ios/LooperKit/Sources/LooperKit/NativeRouting/`. No file
outside `ios/` was changed.

| File | What it is |
| --- | --- |
| `GeographicBounds.swift` | Areas, and the local metric frame every shape term uses |
| `RoutingChunkID.swift` | The spatial grid, and how much ground a walk needs |
| `OSMData.swift` | The raw OSM model, and the Overpass JSON reader |
| `PedestrianAccessPolicy.swift` | What Looper will walk on — one place, testable |
| `RoutingChunkCodec.swift` | The compact on-disk chunk format |
| `RoutingChunkStore.swift` | Persistent chunks, retention, eviction |
| `RoutingDataSource.swift` | The provider abstraction and the Overpass client |
| `RoutingDataManager.swift` | Coverage, request grouping, splitting into chunks |
| `LocalWalkingGraph.swift` | The compact graph and its builder |
| `LocalEdgeIndex.swift` | Spatial index and on-device snapping |
| `LocalExploration.swift` | Bounded Dijkstra; the request-local subgraph |
| `WalkSearchGraph.swift` | 2-core peel, degree-2 contraction, arcs, stems |
| `WalkStateStore.swift` | Where partial walks live during the search |
| `WalkSearch.swift` | The closed-walk beam search |
| `WalkUTurns.swift` | The gate's u-turn measure, inside the search |
| `RouteQuality.swift` | The acceptance gate |
| `RouteDiversity.swift` | Choosing and naming what is offered |
| `LocalInstructions.swift` | Turn-by-turn from the edges |
| `LocalLoopRouter.swift` | The engine, end to end |
| `LoopRoutingEngine.swift` | The seam, and both implementations |
| `RoutingAudit.swift` | Who was asked for what |

## The OSM data source

`RoutingDataSource` is a one-method protocol:

```swift
protocol RoutingDataSource: Sendable {
    func fetchArea(_ bounds: GeographicBounds) async throws -> OSMData
}
```

`OverpassRoutingDataSource` implements it. Its endpoints are configuration, not
a constant, and nothing below the protocol knows a hostname. Moving to a
commercial Overpass-compatible provider is a one-element list and no change
anywhere else — not to the store, not to the graph, not to the router.

**Providers are a list, tried in order.** A single endpoint is a single point
of failure, and this was learned the hard way rather than designed in: a burst
of large bounding-box queries during development got the address blocked by
`overpass-api.de`, which does not refuse politely — it simply stops answering.
On-device routing then stopped working entirely, with no way to recover. The
source now works down its list, moving on for a connection failure, a 429, or
any 5xx, and gives up when a total deadline passes so a walker is never left
watching a progress message that means "everything I know about is broken".

The query, for a bounding box:

```text
[out:json][timeout:90];
way["highway"](SOUTH,WEST,NORTH,EAST);
(._;>;);
out body qt;
```

The recursion (`(._;>;)`) matters more than it looks. It brings back every node
the selected ways reference, **including nodes outside the box**. Without it a
lane that leaves the area would arrive with its far end missing and the graph
would dead-end at the edge of the request.

An Overpass `remark` naming a timeout or a memory limit is treated as an error
rather than as "this area has no paths". A truncated answer stored as if it
were complete is the one failure mode that would poison the cache and not show
up until somebody was standing in the rain.

Overpass is a data source. It is not consulted about routes, and it never
computes one.

## Walking access

Overpass returns motorways, private drives and footpaths side by side. Deciding
between them is the app's job, and `PedestrianAccessPolicy` is the only place
that decision is made. It handles the common highway classes, `foot`, `access`,
`oneway`/`oneway:foot`, `conveying`, barriers on nodes, and refuses
motorway-class infrastructure unconditionally — a `foot=yes` on a motorway is a
tagging error, not an invitation.

Access rules are applied when the **graph is built**, not when data is stored.
Chunks keep the tags the policy reads, so correcting a rule re-reads data
already on the phone instead of invalidating it.

GraphHopper's published `foot` behaviour is the reference for ambiguous OSM
semantics, so a walk found on the phone is walkable by the same rules as one
found on the server. GraphHopper is not linked, downloaded, run or called.

## Chunking

Routing data is stored as Web Mercator XYZ tiles at zoom 14 — about 1.4 km
square at Looper's own latitude.

**How much is needed.** A route of target `D` is accepted up to
`D × (1 + 0.12)`, and a closed walk's furthest point from the door is at most
half its own length away along the network. So nothing admissible ever sits
further than `D × 0.56` of network distance from the start:

| Target | Radius |
| --- | --- |
| 2 km | 1.12 km |
| 3 km | 1.68 km |
| 5 km | 2.80 km |
| 8 km | 4.48 km |
| 10 km | 5.60 km |

Data is acquired in *geographic* space rather than network space, and the two
are not the same — a walker going round a harbour covers more network metres
than the crow flies — so a 300 m chunk-boundary margin is added. That
over-fetches slightly, which is the safe direction: the alternative is a graph
that stops just short of where the search wanted to turn round.

**Acquisition.**

```text
required chunks  ──►  subtract what is stored  ──►  group what is left
                                                          │
                            connected components first, so two clusters
                            either side of a cached town centre stay two
                            requests rather than one that re-fetches the middle
                                                          │
                            a component is asked for whole when its bounding
                            box is at least 60% missing, and split down its
                            longer axis when it is not
                                                          ▼
                                                 one Overpass request each
                                                          │
                                                          ▼
                                        split into chunks, stored, reused
```

**Splitting.** Each chunk gets every way with at least one node inside it, and
every node those ways reference — including nodes belonging to neighbouring
chunks. That halo is what makes a chunk self-contained.

**Cross-chunk continuity.** Node identity is OSM's. A junction stored in two
chunks is the same integer in both, so merging chunks and building a graph
joins their ways automatically, with no geometric stitching and no seam. Tested
for a way crossing one boundary, a lattice spanning several in both directions,
and a start sitting exactly on the corner where four chunks meet.

An empty chunk is stored as an empty chunk. Open sea is a fact about the world,
and recording it stops the same fruitless request being made on every walk from
that beach.

## Cache, and offline areas

Every chunk carries its id, format generation, download date, last-used date,
size, and a retention flag:

- `automatic` — fetched because a route needed it. Evictable, coldest first,
  against a byte budget.
- `pinned` — fetched because the walker asked for the area offline. Never
  evicted automatically. An automatic refetch of a pinned chunk stays pinned.

**The future Offline Areas feature is a screen, not a redesign.** It will call
`downloadOfflineArea(bounds)`, which fills and pins *this same store*. The
router cannot tell how a chunk arrived, because there is nothing to tell: it
reads the store. Both the method and the retention distinction exist and are
tested now; only the UI is absent.

## The local graph

Structure-of-arrays, not a graph of objects: node coordinates, edge endpoints,
lengths, direction flags, geometry offsets, a name table, and a CSR adjacency.
A search area is tens of thousands of edges, and a class per edge would spend
more time in reference counting than in searching.

Only junctions become nodes; a way's intermediate vertices are geometry.
Keeping them as nodes would multiply the search space by the vertex density of
the survey, which varies tenfold between a straight road and a winding lane.

A way is cut where its data runs out, and a blocked node (a locked gate, a wall
mapped as a point) genuinely severs it — the two sides get separate node
identities, so no route can pass through.

Each edge carries: endpoints, metres, walk direction, geometry, street name,
road classification, and the OSM way it came from — the physical identity that
"this walk has already spent this ground" is decided on.

## Snapping

On the device, against a uniform spatial grid over the edges, expanding a ring
of cells at a time and stopping once no unexamined cell can hold anything
closer. The result addresses a point **along** an edge, not the nearest
junction: junctions on a residential street sit 80–150 m apart, so snapping to
one can move the start further than the width of the street the walker is on.

A start mid-edge splits that edge into two halves that both keep the base
edge's identity — the same thing GraphHopper's QueryGraph does, for the same
reason: repeated-ground accounting must still mean what it meant.

## Search

The closed-walk algorithm validated by the routing prototype, ported without
re-tuning.

```text
bounded exploration    Dijkstra to D × 0.56; home distances are exact
2-core peel            a rooted circuit cannot enter a dead end and come back
                       out without retracing, so every leaf peels — exactly
degree-2 contraction   a chain of degree-2 junctions offers no choice; each
                       becomes one super-edge carrying its metres, geometry
                       and underlying edge ids
beam search            beam 300, 100 m distance bands, 3 survivors per node,
                       compass-octant diversity quota
prunes (exact)         a super-edge already spent is not offered;
                       distance + home > max is discarded
ranking                close the walk with a straight line home and ask how
                       round it would be, less a shortfall and turn penalty
closure                shape, bounding box and u-turns measured exactly
selection              octant quota, then the gate, then diverse selection
materialisation        the searched edge sequence IS the route
```

Bands are drained rather than visited: most super-edges are shorter than a
band, so expanding a band produces states in the same band.

Partial walks live in a store split by lifetime — parent and arc for the whole
search, ranking columns only while their band is live — so memory stays in
megabytes rather than the 137 MB the first prototype reached.

**The searched walk is the answer.** Nothing is re-routed and nothing is sent
anywhere. Geometry, distance, duration and instructions are all built from the
edges the search chose.

## Judging what is offered

`RouteQuality` is the route service's `quality.ts`, ported with no threshold
relaxed: distance error, repeated corridors, out-and-back spurs, u-turns,
bounding-box ratio, compactness, doorstep stub, and returning to the start.

That fidelity is the point. The app now has two engines, and a comparison is
only meaningful if both are judged by the same gate. A local engine offering
walks its remote counterpart would have refused would look better in testing
for exactly the wrong reason.

`RouteDiversity` then picks at most three that share no more than 55% of their
ground and prefer different ways out of the door, and names them by compass
bearing — the same rules, and for searched walks it measures shared ground on
the network rather than by proximity, because a searched walk knows its edges.

## Instructions

Generated on the device from edge geometry, incoming and outgoing bearings,
street names and junction topology: continue, bear left/right, turn left/right,
sharp left/right, turn around, **cross**, arrive. They fit the app's existing
`Step` model and its convention that a step's instruction is the manoeuvre at
its *start*.

Deliberately modest. Field testing decides what guidance needs to say, and
instructions elaborated before anyone has walked behind them tend to be
elaborate in the wrong places.

**Crossing is the one manoeuvre field testing has already asked for.** A walker
was told to "turn right" where there was no turning: the route was crossing the
road, and a crossing was being described as two corners — a right onto ten
metres of unnamed tarmac and a left off it again. Three things had to change:

- **A crossing has to be knowable.** `PedestrianAccessPolicy.isCrossing(tags:)`
  reads `footway=crossing` and its relatives; `LocalWalkingGraph` keeps the
  answer per edge, along with the name of the carriageway incident to the
  crossing's own endpoint — which is the road being crossed, readable from the
  graph's own topology because a crossing way is cut *at* the road it crosses.
  It is deliberately **not** a `RoadClass` case: a crossing genuinely is a
  footway for access and weighting, and folding it into the class enum would
  silently move `isPedestrianWay` and the `pave=NN%` telemetry's own definition.
- **A manoeuvre has to be judged over ground, not over one vertex.** A crossing
  leaves the kerb at right angles, so its first two coordinates read as a square
  turn however straight the walk through them is. Bearings are now measured over
  twelve metres either side of the junction.
- **A crossing is one instruction, however many edges it is.** Cut at the
  carriageway, a kerb-to-kerb crossing routinely arrives as two edges. The run
  collapses into a single "Cross \<road\>" — the manoeuvre that begins the far
  side — and `tidySteps` will never fold it away, which it otherwise would,
  since both pavements of one street carry the street's name.

**Junctions and juts.** A pavement routinely juts sideways just before a
junction to reach the dropped kerb, so the walk does not cross square: it jogs
aside, crosses, and jogs back. Every jog was a corner, and every corner was
called out. Three further rules answer that:

- **A short leg that leaves the walk heading the way it came in is geometry.**
  `LocalInstructions.isKink` absorbs it. The test is two-sided on purpose — it
  asks where the walk *heads* either side, not how sharp the leg's own corners
  are — so a jut is absorbed and a genuine short turn onto a short street is
  not. Distance alone would delete the second.
- **Headings come from the nearest substantial leg, never from a window.** This
  is the dog-leg's own lesson: the twelve metres either side of a crossing can
  be *entirely* jut and crossing, so a window measures the very distortion it is
  meant to see past. Two five-metre juts at sixty degrees swung a windowed
  heading by 22° and lost a straight crossing.
- **A crossing taken along the line of travel is a junction; across it, a change
  of side.** `RouteQuality.crossingRuns` classifies every crossing as
  `.junction` or `.sideSwap`, and a junction crossed with the walk carrying
  straight on says so — "Cross the junction and carry straight on" — while a
  side-swap keeps "Cross \<road\>". The classifier is shared with the
  measurement below, so what is said and what is counted cannot drift apart.

Nothing here changes a route. The crossing flag is not read by the cost model,
and `RouteQuality.pavement` gained `crossings`, `crossingsPerKm`, `crossBacks`,
`sideSwapCrossings` and `junctionCrossings` while leaving `hops` exactly as it
was. That last point is the whole reason the counters exist: `hops` counts
pavement-to-carriageway transitions, so a walk that hops to the far pavement and
back never leaves pedestrian ground and scores **zero** — which is why every
measurement taken before this, including the sweep that chose
`looper_foot.json`'s multiplier, was blind to the swapping walkers actually
complain about.

**`sideSwapCrossings` is the number to drive down**, not `crossings`. A junction
crossing is a walker crossing a side road on the way past it, and charging for
it would buy detours around junctions — the 0.1 multiplier's mistake in a new
place. Making the two separable is what the next change needs: grouping the two
pavements and their carriageway into one street, so the cost model can charge a
side-swap and leave a junction alone.

## The engine seam

```swift
protocol LoopRoutingEngine: Sendable {
    func generateLoops(_ request: LoopRequest) async throws -> LoopResponse
}
```

- `RemoteLoopRoutingEngine` wraps the existing `requestLoops` — same URL, same
  body, same response handling. It is retained as a baseline, and a baseline
  that quietly drifted would be worth nothing.
- `OnDeviceLoopRoutingEngine` uses only `RoutingDataManager`,
  `RoutingChunkStore`, `LocalWalkingGraph` and `LocalLoopRouter`.

The rest of the app consumes the same `Route` model from either, so the map,
the walk screen, the spoken guidance, the Watch and saved favourites all behave
identically. The only thing a field test compares is the walk.

Settings:

```text
Routing engine
  ○ Remote / Current      (default)
  ● On-device / New
```

The preference persists. Remote always uses the production service as
deployed; On-device performs every routing decision on the phone.

## Offline behaviour

When On-device is selected and chunks are missing:

- **Online, provider answers** — download, store, route locally. The planner
  says *"Downloading walking paths for this area…"*.
- **Genuinely offline** — fail with *"Routing data for this area isn't
  available offline yet. Connect to download it, or switch to Remote routing."*
- **Online, but no provider answers** — a *different* failure, and it must stay
  different: *"The map data service isn't responding, so walking paths for this
  area can't be downloaded right now."* Telling somebody with four bars of
  signal to connect to a network sends them looking for a fault they do not
  have.

That distinction is drawn from the URL error, and where it is drawn matters.
`notConnectedToInternet` and `dataNotAllowed` are device-level and abort
everything. `networkConnectionLost`, `timedOut`, `cannotConnectToHost` and
their relatives are *per connection* and move to the next provider — reading a
dropped socket as "the device is offline" abandons the search for a working
provider on the first host that drops one, which defeats the endpoint list
entirely and does it silently.

It never silently uses the remote router. A comparison in which the engine can
change without anyone noticing is not a comparison.

Once the chunks are cached, routing needs **zero** network requests — to
Overpass, to Looper, to anybody.

## Auditing

`RoutingAudit` records Overpass requests (endpoint, bounding box, request and
response bytes, ways, nodes, attempts, duration) and, separately and at a
different layer, every routing call the app makes to Looper's own service. In
On-device mode the second count must be zero, and it is a measurement rather
than a claim.

All of it is **also written to the unified log**, via `RoutingLog`. That is not
decoration: the provider outage above was invisible from inside the app for
exactly as long as the audit was collecting the right numbers and showing them
to nobody. Categories are split so one question can be asked at a time.

```console
# live, from a simulator
xcrun simctl spawn booted log stream \
  --predicate 'subsystem == "com.woollams.Looper"' --level info

# from a real iPhone
log collect --device --last 10m
```

A failing acquisition now reads like this, which is a diagnosis rather than a
symptom:

```text
coverage target=4000m radius=2240m required=25 cached=0 missing=25 requests=1
osm fetch begin source=Overpass bbox=54.1238,-4.5703,54.1882,-4.4604 providers=3
osm fetch failed host=overpass-api.de attempt=1 reason=Could not connect to the server.
osm provider exhausted host=overpass-api.de
osm fetch host=overpass.kumi.systems status=500 attempt=1
osm fetch gave up attempts=4 reason=Tried 3 providers; last error was HTTP 500
```

`routing.remote` is the category that must stay silent in On-device mode — and
a silence nobody can see is not evidence of anything, which is why the line is
written on the remote path.

## Responsible use of the data provider

The public Overpass endpoints are volunteer-run and are not anyone's production
backend. So: cache aggressively; never re-download a valid chunk; group
adjacent missing chunks into one bounding-box request; fetch only when a route
actually needs data, never while a start point is being dragged; retry with
exponential backoff and jitter, and never retry a 4xx or a device-offline
error.

This is not theoretical. Development measurement runs — a handful of 5–8 km
bounding boxes over a few minutes — were enough to get the address blocked by
`overpass-api.de`. The failover list makes the app survive that; it does not
make the traffic acceptable, and it is not a licence to generate more of it.

The path to a commercial endpoint is a configuration change. It is not, and
must not become, a Looper proxy.
