# On-device router vs remote GraphHopper — divergence diagnosis

Forensic write-up of **why the on-device walking router puts loops on carriageways
where remote GraphHopper stays on the pavement**, and a proposed fix for the
dominant cause that mirrors GraphHopper's own mechanism.

- **Evidence:** local GraphHopper 11.0 (`localhost:8989`, `route-service/graphhopper/looper_foot.json`),
  GraphHopper 11.0 source (tag `11.0`), on-device engine via `Phase4ParityTests`
  diagnostics + a leg-by-leg trace, live Overpass + the Aug-2026 IoM import.
- **On-device state:** reverted baseline `5731c54` (the `classSwitchPenaltyMetres`
  hysteresis from `796d342` / `a9dd895` is out).
- **Reference ground:** Bucks Road A42 / Upper Church Street, Douglas
  (`sidewalk:both=separate` — pavements mapped as their own `footway=sidewalk` ways).

---

## 1. What is NOT the cause (each ruled out with proof)

### 1.1 The cost function / priority / speed / distance_influence — IDENTICAL
- GraphHopper 11 `CustomWeighting.calcEdgeWeight`: `weight = seconds / priority
  + distanceCosts`. No base/vehicle weighting under `weighting: custom`.
  `distanceCosts = distance × distance_influence / 1000`; GH 11's default
  `distance_influence` when the custom model omits it is **0**.
  ⟹ `weight = (distance / speed) / priority`.
- GraphHopper's own returned numbers for the Bucks Road leg: `distance 640.102 m`,
  `time 460876 ms`. `640.102 / (5000/3600) = 460.873 s` — matches `time` to 3
  decimals ⟹ **flat 5 km/h, no per-way speed variation**. `weight/time = 1.0371`
  = the footway/carriageway mix.
- On-device `LocalLegRouter.cost` = `distance × (1/priority)`, priority ∈
  {1.0 pedestrian way, 1/0.8 = 1.25 carriageway} — same values as `looper_foot.json`.
  `argmin(Σ distance/priority)` is **byte-identical**.
- **`foot_priority` is genuinely unused.** GH 11 `CustomModelParser` seeds the
  priority function from `GLOBAL_PRIORITY = 1` and appends only the custom model's
  own `priority` rules; it wires up an encoded value only if its name textually
  appears in the model. `looper_foot.json` never mentions `foot_priority`.
  `FootPriorityParser` runs at import but its output is never read by the
  weighting. ⟹ GraphHopper gives footways no boost and roads no penalty beyond
  the explicit ×0.8 — exactly like the device.
- Empirically: override the ×0.8 so footway == carriageway → GraphHopper's Bucks
  Road leg drops 85% → 54% pavement; invert it → 0%. Its entire pavement
  preference **is** the ×0.8, which the device reproduces.
- Turn / u-turn costs: none on either.

### 1.2 Graph connectivity of the reported streets — FINE
Rebuilding the on-device junction logic (`usage[id] >= 2` → graph node) over the
Bucks Road bbox: **458 edges, one component.** The Bucks Road carriageway, all
23 Bucks Road `footway=sidewalk` edges, and the `footway=crossing` connectors are
all in it. Same for Upper Church Street: 8 carriageway + 12 sidewalk edges, one
component. The pavement is fully present and fully connected to its carriageway.
`minNetworkSize:200` pruning ruled out (`prune=0` == `prune=200`).

### 1.3 `sidewalk=separate` is not a block
GraphHopper `foot_access` is TRUE on the Bucks Road carriageway (forcing GH to
prefer primary roads yields a 100%-carriageway route). Same on-device. Soft ×0.8
preference on both.

### 1.4 On the Bucks Road *leg*, the engines are already at parity
GraphHopper 640 m / 84.6% pavement; on-device (pin-to-pin) 679 m / 84.3%. Same
~7 m + ~87 m service-road stubs at the endpoints; one ~10 m mid-route hop
on-device. That is the whole leg-level difference.

### 1.5 `sidewalk:both=yes` streets — correct on both engines
Ballabrooie Way (246 m), Westminster Drive, Mount Bradda etc. have pavements that
are **not** separately mapped. GraphHopper walks the carriageway centreline there
too (`road_class=unclassified`). Neither engine synthesises sidewalks. `pave%`
counts it against both; the on-device loop only *looks* worse because Looper
routes loops through more of these residential streets.

---

## 2. The dominant cause — mis-snapped ring aims + un-weighted snap stubs

### 2.1 Ring corner aims land far off the walkable network
`LocalRingRouter.buildRingCandidate` sets each corner aim to
`LocalGeo.destination(from, plannedLength, bearing)` — a raw lat/lon —
**identical to the remote generator** (`route-service/src/loops/routing.ts:417`,
same `destination(from, plannedLength·…, bearing)`).

In coastal / hilly Douglas these aims routinely land **100–500 m off the
walkable network** (Douglas Bay, cliffs, rail cuttings). Leg-by-leg trace of a
4 km loop from Bucks Road / Christian Road:

```
[ring] committed leg 1127m carr=484m  from{way=25988779 residential CARR d=6m}   aim{way=1165867448 cycleway CARR d=311m}
[ring] committed leg 2460m carr=1342m from{way=171810366 cycleway CARR d=23m}    aim{way=25988779 residential CARR d=6m}
[ring] committed leg 1406m carr=1018m from{way=1449697251 service CARR d=5m}     aim{way=25988779 residential CARR d=6m}
[ring] committed leg 1123m carr=707m  from{way=1165867448 cycleway CARR d=311m}  aim{way=883387741 footway d=3m}
```

`d=` is the snap distance. `LocalEdgeIndex.snap` (`maximumMetres` 500, **no
pedestrian preference**) grabs the geometrically nearest edge — usually a
carriageway / service road / cycleway.

### 2.2 `LocalLegRouter` emits raw carriageway geometry OUTSIDE the weighted A*
- **`half(snappedEdge)`** — `LocalLegRouter.swift` ~`:209-216, :334-361, :375-396`
  — the walk from the snapped mid-edge point to whichever tower node the A*
  leaves from, drawn as a `WalkLeg` **before/after** the search. On a long
  carriageway edge this is up to ~half the edge (100–250 m).
- **`alongOneEdge`** — `LocalLegRouter.swift:191-193` — when `source.edge ==
  target.edge`, `route()` returns a direct walk along that one edge with **no A*
  at all**.
- **The departure/arrival seed is un-weighted.** The A* seeds the source edge's
  tower nodes with `distance = entry.metres × sourcePenalty` and scores arrivals
  with `entry.metres × targetPenalty` — **`entry.metres` (the half-edge length)
  is never multiplied by `graph.edgeWeight[edge]`**. So entering/leaving via a
  carriageway edge is priced at 1.0× instead of 1.25×, making the carriageway
  stub artificially cheap.

### 2.3 GraphHopper handles the identical mis-snapped aim differently
GraphHopper's `QueryGraph` inserts a **virtual node** at the snapped point,
splitting the edge into two **virtual edges** that carry the *real edge's weight*
scaled by the fraction. The routing algorithm runs on that overlay from virtual
node to virtual node. There is **no raw stub** — the whole leg, including the
approach to the snap, is chosen by the weighted search, so the ×0.8 pulls it off
the carriageway within metres of the snap.

**Measured, same doorstep → same-distance (~450 m) off-network aim:**
GraphHopper 817 m / **20% carriageway**; on-device 1127 m / **43% carriageway**.

### 2.4 Contributor — the start doorstep snaps to the carriageway
Every traced leg starts `from{way=25988779 residential CARR d=6m}` — the
Bucks Road / Christian Road doorstep snapping to the Harris Terrace carriageway
centre-line, not the pavement. So every generated loop begins and ends on the
carriageway.

### 2.5 Why the LEG router is fine but the LOOP router is not
`LocalLegRouter` on its own is only called with real user pins that sit on or
beside the network, so its `half()` stubs are a few metres. `LocalRingRouter`
calls it 8–12× per candidate with bearing-placed aims that routinely miss the
network by hundreds of metres, and each miss becomes 100–250 m of carriageway.

---

## 3. Smaller proven differences (tag-dependent; do NOT apply to the reported streets)

| # | tag / case | GraphHopper 11 | on-device | effect |
|---|---|---|---|---|
| 3.1 | `access=private` / `restricted` / `foot=private` | `foot_access=false` ⟹ **hard block**, removed from routing *and* the snap filter | `pricedValues` ⟹ routable at **×0.1 (10× cost)** | a private pavement / cut-through is a wall on the server, a mild detour on the device — opposite handling |
| 3.2 | `access=customers` / `delivery` | falls through to `foot_access=true`, full priority | `pricedValues` ⟹ ×0.1 (10× cost) | GraphHopper walks a `customers` pavement; the device bails to the carriageway |
| 3.3 | `highway=cycleway` with no `foot` / `segregated` tag | `cycleway` ∈ `allowedHighwayTags` ⟹ routable, `road_class=CYCLEWAY` ⟹ ×0.8 | `decide` → `.blocked("cycleway-no-foot")` | a shared-use promenade mapped this way is usable for GraphHopper, **invisible** to the device |
| 3.4 | `highway=corridor` | not in `allowedHighwayTags` ⟹ blocked | `walkableHighways` contains it ⟹ routable ×0.8 | flips a choice where an arcade / covered corridor is the link |
| 3.5 | `area=yes` / `indoor=yes` | access parser does not block | `decide` blocks outright | flips a choice where a pedestrian square is the link |
| 3.6 | `highway=steps` speed | `MEAN_SPEED - 2` = **3 km/h** ⟹ ~1.67× per-metre cost | no speed term ⟹ flat, weight 1.0 | GraphHopper avoids a stepped pavement route more than the device |
| 3.7 | `trunk` / `trunk_link` | `import.osm.ignored_highways` drops `trunk` entirely; `trunk_link` imported & routable | `forbiddenHighways` blocks both unless `foot` explicitly allowed | niche on the Isle of Man |
| 3.8 | subnetwork pruning | per-profile, directed, whole-planet, one pass | undirected union-find, windowed to loaded chunks | rare, edge-of-search-area only |
| 3.9 | chunk-seam cuts | none (planet import) | a way's run is cut where a node's coords are missing from loaded chunks | device-only data artifact near the search boundary |
| 3.10 | snapping candidate filter | `DefaultSnapFilter` — nearest edge with **finite weight** (accessible); no priority preference | `LocalEdgeIndex.snap` — nearest edge by raw distance; only tunnels/bridges demoted | equivalent except as a consequence of 3.1 |

None of 3.1–3.3 apply to the Bucks Road / Upper Church Street sidewalks — those
ways are untagged. They flip road/pavement choices elsewhere.

---

## 4. Which of these makes the route visibly "jump into a road"

1. **§2 — ring-corner mis-snap + `half()` / `alongOneEdge` (on-device only, dominant).**
   Near every corner of a generated loop, an aim snaps to a carriageway and
   100–250 m of it is emitted as raw un-optimised geometry. Route jumps onto the
   road at corners.
2. **§2.4 — doorstep snaps to the carriageway (on-device only).** Loop starts and
   ends on the road for a few metres.
3. **§1.2 residual / §3.9 — unmapped crossings / chunk seams in the Overpass
   snapshot (data, minor, both engines).** Crossing a side street uses ~5–15 m of
   its carriageway where no `footway=crossing` way is present.
4. **The ×0.8 near-tie flip-flop (both engines, inherent to the shared cost
   model).** Where a carriageway segment is >25% shorter than the parallel
   pavement between two shared points, the road wins that block. `looper_foot.json`'s
   own header documents this.

§3.1–3.3 do **not** cause a jump — they make the device steadily prefer a road
over a specific restricted / shared-use pavement.

---

## 5. Proposed fix for §2 — mirror GraphHopper's `QueryGraph` virtual nodes

**Principle:** the snapped point must be a first-class node in the weighted
search, with connections to the network priced like the edge it sits on, so the
*entire* leg — including the approach to the snap — is chosen by the A*. No
geometry is emitted outside the search.

All changes are in
`ios/LooperKit/Sources/LooperKit/NativeRouting/LocalLegRouter.swift` (the
`route(from:to:…)` overload). `LocalEdgeIndex.snap` / `.split()` are unchanged —
GraphHopper's snap is also nearest-edge; the fix is in what the router does with
the snap.

### 5a. Weight the entry/exit half-edges *(minimal, do first — ~4 lines)*
GraphHopper's virtual edge weight = `realEdgeWeight × fraction`. On-device the
seed and the arrival key must gain the same `edgeWeight` factor:

- departure seeding: `seed = entry.metres * (weighted ? graph.edgeWeight[source.edge] : 1) * sourcePenalty`
- arrival key (both the `wanted`-loop seed *and* the final `best` selection):
  `... + entry.metres * (weighted ? graph.edgeWeight[target.edge] : 1) * targetPenalty`

`entry.metres` stays the true length in the returned `WalkLeg` (`half()` reads
`snap.metresFromStart` / `.metresToEnd`, untouched) — only the *search cost*
changes. Effect: a carriageway snap is priced 1.25×, so the search prefers the
shorter stub and prefers a route that leaves the carriageway sooner.

### 5b. Stop `alongOneEdge` bypassing the weighted search
GraphHopper's `QueryGraph` keeps **both** virtual nodes on one edge and still
runs the algorithm — the direct along-edge walk is just one option it weighs.
Replace the unconditional early return:

```swift
if source.edge == target.edge, let direct = alongOneEdge(source, target, graph: graph, index: index) {
    return direct                      // ← current: unweighted bypass
}
```

with: compute `alongOneEdge` as a **candidate**, run the A* as well (it must
genuinely explore the network for the same-edge case — see 5c), and return
whichever has the lower **weighted** cost
(`direct.metres * edgeWeight[source.edge] * sourcePenalty` vs the A* result's
weighted cost). Keep `alongOneEdge` unconditionally only when the shared edge
`isPedestrianWay` (there is nothing better to find).

### 5c. Full version — a QueryGraph overlay *(the faithful port; supersedes 5a+5b)*
Add `source` and `target` as **temporary virtual nodes**:

- each gets two temporary arcs, to the two tower nodes of its snapped edge,
  weighted `halfMetres * graph.edgeWeight[edge] * penalty` (the direction the
  half allows, per the existing `edgeForward` / `edgeBackward` check);
- run **one** A* from the source virtual node to the target virtual node over the
  CSR adjacency plus these temp arcs (a small `[Int: [(to, cost, edge)]]` sidecar
  the relaxation checks alongside `arcStart`/`arcEdge`);
- read the path back including the temp arcs; the terminal temp arcs become the
  `half()` stubs, but now they were *chosen* by the weighted search.

This unifies 5a and 5b and matches GraphHopper edge-for-edge:
mid-edge start, mid-edge end, and same-edge start/end all go through one
weighted search with correctly-priced virtual edges. `LocalEdgeIndex.split()`
already produces the stub geometry.

### 5d. Contributor (§2.4) falls out for free
Once 5a–5c land, the doorstep's carriageway snap is a properly-weighted virtual
stub the search leaves immediately — no separate change needed.

### Verification
- **Trace harness:** re-add the `LOOPER_TRACE_LEGS` instrumentation
  (`LocalRingRouter.buildRingCandidate` committed-leg print + `LocalLegRouter`
  snap print — see this doc's git history / the plan file) and re-run
  `Phase4ParityTests/testInvestigateBucksRoadLoop`. The same
  doorstep→off-network-aim leg should drop from ~43% carriageway toward
  GraphHopper's ~20%.
- **Parity harness:** `LOOPER_LIVE_OVERPASS=1 LOOPER_PARITY_OUT=… swift test
  --filter Phase4ParityTests` then `npx tsx route-service/bench/parity.ts
  --ondevice …` — the on-device Douglas-loop `pave%` and `sameWalk%` columns
  should move toward the remote column in `bench/results/parity-4a.md`.
- **Unit:** a synthetic fixture — a long carriageway edge with a parallel,
  connected footway; two points snapped mid-carriageway 200 m apart; assert the
  weighted leg is >90% pavement (currently 0% via `alongOneEdge`).
- **App:** rebuild + relaunch on the simulator, generate a Douglas loop, confirm
  the route no longer jumps onto the carriageway at corners.

### What this fix deliberately does NOT do
- No priority-aware snapping — GraphHopper doesn't do that; 5a–5c make it
  unnecessary.
- No change to the cost model, the ×0.8, or the ring aim placement — those match
  remote already.
- No new on-device-only heuristic (unlike the reverted `classSwitchPenaltyMetres`).

---

## 6. Implementation attempt — RESULT: §5 does not move the needle

`5a` (weight the stub seeds by `edgeWeight`) was implemented and measured on the
`Phase4ParityTests` harness. **Zero effect.** The stub metres on a real ring
leg are only a few metres (the aim snaps close, or the search picks the near
tower node anyway), so pricing them 1.25× vs 1.0× changes no decision. Reverted.

`5b`/`5c` (the `alongOneEdge` / virtual-node work): on closer analysis the
"same-edge carriageway with a useful parallel route" case **does not exist** —
any node a parallel way shares with a carriageway splits that carriageway edge,
so `source.edge == target.edge` only when the edge is one genuinely
junction-free stretch, where the direct walk *is* correct (GraphHopper does the
same). Not implemented.

### What the implementation attempt DID uncover — §3.1 is the real mechanism for the worst legs

Tracing a single leg from the Bucks Road doorstep to an aim ~500 m off the
network in Douglas Bay: the aim's geometrically-nearest edge is
`way 38256630 = highway=service access=private surface=concrete` — the
**private concrete breakwater / harbour road**.

- **Deployed GraphHopper** (`FootAccessParser` with `block_private = true`)
  removes that way from routing **and from the snap filter**, so the bay aim
  snaps to the nearest *public* edge (~500–680 m away, on land near the
  promenade) and GraphHopper routes there almost entirely on pavement
  (measured: 16–23% carriageway).
- **On-device** (`PedestrianAccessPolicy` prices `access=private` at ×10 but
  keeps it in the graph and snappable) snaps the bay aim **onto the private
  breakwater road**, then `half()` + the A* walk a long carriageway to reach it
  (measured: 43–65% carriageway).

Blocking `access=private`/`restricted` on-device (to match deployed GraphHopper)
was implemented and measured. It **made the offered loops slightly worse** —
`douglas-prom-4km` lost 11 points of pavement — because it also removed private
ways that were genuinely useful pavement links, and the bay aims then snapped to
the *ferry* route instead (`half()` of a 130 km ferry edge = 579 m). Reverted.

### Net conclusion

**None of §5, nor blocking `access=private`, improves the offered-loop pavement
share.** The garbage off-network legs (§2, §3.1) are mostly rejected by the ring
generator's overshoot check before they reach an offered loop. The residual
offered-loop carriageway is:

1. **`sidewalk:both=yes` streets** — ~10–15 pts. GraphHopper walks these too;
   a `pave%` metric artifact, not a divergence (§1.5).
2. **The heuristic loop generator picking different loops than remote**
   (`sameWalk%` 25–53% on mid-size Douglas fixtures) — the same candidate
   algorithm over two deterministic searches on two slightly different graphs
   fans out to different, individually-valid loops.
3. **`douglas-5km`** — a persistent ~30-point outlier (54% vs remote's 84%) not
   explained by any of the above. Needs the three remote offers laid beside the
   three on-device offers, street by street.

The productive next step is **not** another leg-router change — it is (3):
eyeball `douglas-5km`'s offered loops directly. Everything upstream of the
offered set (cost, connectivity, access, snapping) has been ruled out or shown
not to matter to what actually gets offered.
