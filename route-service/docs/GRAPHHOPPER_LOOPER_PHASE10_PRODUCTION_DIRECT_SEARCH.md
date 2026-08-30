# GraphHopper / Looper Phase 10 — Productionising the Direct Closed-Walk Search

## Decision

**READY FOR FIELD TESTING.**

Phase 9's search now runs inside the routing facade, over GraphHopper's own
graph, and is selectable from the iOS app. On the four normal fixtures it
offers **12 of 12 routes**, at **0.6% mean median distance error** against
Phase 3B's 5.1%, **mean quality 74.1** against 67.6, **0.00% repeated ground**
against 1.88%, **zero GraphHopper routing calls** against 978, and a
normal-ring wall time of **372 ms** against 1,092 ms.

The two things that stopped Phase 9 being an A are both settled by measurement:

```text
Douglas 5 km, end to end        371 ms  ->  176 ms      (target <= 300, strong <= 250)
peak search memory              137 MB  ->  5.26 MB     (exact, not a heap reading)
retained after the request         n/a  ->  4.62 MB
40 repeated requests, settled heap      33.5 MB, flat
```

Turn-by-turn instructions, duration and path details are generated from the
searched edge sequence without a second search, and the returned distance is
the searched distance to the metre on every fixture. The iOS app has a
persisted Routing Engine picker, sends the choice, shows which engine actually
answered, and records a local trial row per generation with an optional rating.

It is classified READY rather than as a production default because it should
not be one yet, and because three limits are measured rather than guessed at:
Peel falls back to Phase 3B at 2 km, 8 km and 10 km for want of three
*separable* walks; a start well outside the 2-core falls back everywhere it was
tried; and the u-turn work in §7 did not do what it was aimed at.

Production remains Phase 3B. `LOOPER_DIRECT_CLOSED_WALK_SEARCH` ships **off**.

---

## 1. Phase 9 reference

Phase 9's retained S2 beam, across the four normal-ring fixtures:

```text
offered routes:                 12 / 12
mean absolute distance error:   54 m
mean quality:                   73.2
mean repeated ground:           0.08%
GraphHopper routing calls:      0
normal-ring wall time:          771 ms
peak heap:                      137 MB per request
Douglas 5 km:                   371 ms
```

against Phase 3B:

```text
offered routes:                 12 / 12
mean absolute distance error:   216 m
mean quality:                   67.6
mean repeated ground:           1.88%
GraphHopper routing calls:      978
normal-ring wall time:          1,622 ms
```

The retained formulation — **stem + edge-simple circuit + stem**, beam 300,
band 100 m, per-node 3, compass-octant quota on — is carried over unchanged and
was not re-tuned. §12 confirms the port reproduces it.

Production's own flags are also unchanged: `LOOPER_PULLBACK_REUSES_PREVIOUS`,
`LOOPER_BACKTRACK_NEEDS_BUDGET`, `LOOPER_BUDGET_ONCE_PER_LEG`,
`ROUTING_CONCURRENCY=4`, `LOOPER_MODEL_REGISTRY`, `LOOPER_ROUTE_MEMO`. Nothing
in this phase touched Phase 4 closure reservation, Phase 5 full-shape
prediction, Phase 6 perimeter repayment, Phase 7 anchor families, Phase 8
pairwise anchors, GraphHopper's `round_trip`, waypoint routing, or any quality
or diversity threshold.

---

## 2. Java search architecture

The search moved into the process that owns the graph. Nothing is exported and
nothing is re-parsed.

```text
POST /looper/closed-walk                    com.looper.routing.Serve
        |
        v
DirectWalks.search
        |
        +-- LooperRoutingCore.exploreForWalk   bounded Dijkstra on the foot
        |                                      profile's own QueryGraph
        +-- new SearchGraph(subgraph)          2-core peel, degree-2 contraction,
        |                                      arcs, per-edge shape precompute
        +-- WalkSearch.run                     Phase 9's S2 beam over distance
        |                                      bands, on a StateStore
        +-- UTurns.count + octant quota        the gate's own shape and turn
        |                                      rules, applied early
        +-- DirectWalks.materialise            the searched edge sequence as a
                                               GraphHopper Path, then PathMerger
```

Five new files, all under `gh-harness/src/main/java/com/looper/routing/direct/`:

| file | what it owns |
|---|---|
| `SearchGraph.java` | the reduced request-local graph and its shape precompute |
| `StateStore.java` | partial walks, as primitive columns with a band lifecycle |
| `WalkSearch.java` | the S2 beam |
| `UTurns.java` | the acceptance gate's own u-turn measure, ported |
| `DirectWalks.java` | the stages above, and materialisation |
| `DirectBench.java` | the Java-side benchmark (§20, §21) |

One existing method was refactored rather than duplicated.
`LooperRoutingCore.exploreSubgraph` — the Phase 9 exporter — now delegates to a
new `exploreForWalk`, which returns the same `Subgraph` *and* the `QueryGraph`
the exploration ran on. That last part is the whole reason for the refactor: a
walk is materialised in the graph its virtual start node lives in, and a second
snap would produce a second QueryGraph with different virtual edge ids in which
the searched walk is not expressible. Phase 9's export path is byte-identical
through the delegation, and `bench/phase9/*` still runs.

Two edge identities are kept and they are not the same thing. **Graph ids**
address the QueryGraph and are what a `Path` is rebuilt from. **Physical ids**
are the base-graph edges a virtual edge is a piece of, and are what
repeated-ground accounting is done on. Phase 9 only ever needed the second.

---

## 3. Graph exploration and reduction

The bound is Phase 9's, derived rather than chosen, with no location in it:

```text
explorationShare = (1 + MAX_DISTANCE_ERROR) / 2 = 0.56
```

Both reductions are ported exactly and both are correctness-preserving:

- **2-core peel.** A rooted circuit cannot enter a dead end and come back out
  without retracing that edge in reverse, which the gate's `out-and-back-spur`
  rule makes fatal outside the 75 m doorstep window. Every leaf is peeled,
  repeatedly. What is peeled is kept, because the doorstep stem may run through
  it — `SearchGraph.stemTo` reconstructs it from the start-rooted shortest-path
  tree, read back out of the distance field in one pass rather than searched
  for again.
- **Degree-2 contraction.** A chain of degree-2 junctions offers no choice, so
  it becomes one super-edge carrying its metres, its geometry, the *graph* edge
  ids it is made of, the *physical* edge ids beneath those, entry and exit
  bearings, and its shoelace, drawn-length, bounding-box and radius
  contributions in the start's local metric frame.

The reduction reproduces Phase 9 exactly, which is the first evidence the port
is faithful:

| fixture | raw nodes | raw edges | 2-core nodes | 2-core edges | search nodes | search arcs | explore ms | reduce ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | 6586 | 8542 | 5317 | 7273 | 3006 | 9924 | 7.4 | 5.8 |
| douglas-3km | 4395 | 5868 | 3710 | 5183 | 2189 | 7324 | 4.3 | 3.3 |
| peel-5km | 1401 | 1733 | 1001 | 1333 | 596 | 1856 | 1.4 | 1.4 |
| onchan-5km | 3927 | 4816 | 2835 | 3724 | 1554 | 4886 | 3.6 | 2.1 |

Every column matches Phase 9 §6 to the node. What has changed is the cost of
getting there: Phase 9 paid 1.1–7.7 ms of export **plus** a 0.23–0.97 MB
payload, ~3 ms of parse and 2.2–16.1 ms of TypeScript graph build. Phase 10
pays 1.4–7.4 ms of the same exploration and 1.4–5.8 ms of Java build, and there
is no payload at all.

The arcs also now carry the bearing leaving each super-edge and the bearing
arriving at it, which §7 uses. Phase 9 computed these and did not use them.

---

## 4. Beam-search port

`WalkSearch.run` is Phase 9's S2, moved rather than redesigned. Retained
without change:

```text
beam width            300
distance band         100 m
per-node survivors    3
diversity quota       on (compass octants, committed at
                      min(INITIAL_BEARING_METRES, 0.2 x target))
```

Retained exactly, and they are the only two prunes:

```text
a super-edge already spent is not offered as a move
distanceUsed + home[node] > maxMetres
```

`home` is the exploration's own Dijkstra distance, so the second is a true
lower bound and not an estimate of one. Everything else that limits the search
is beam selection, which is approximate by construction.

Retained in form: bands are **drained** rather than visited once. Most
super-edges are shorter than a band, so expanding a band produces states in the
same band, and processing each band once would silently discard most of the
search. Each pass applies the beam to whatever is currently in the band; the
band is finished only when it empties. Termination is not in doubt — no walk
may spend an edge twice, so depth is bounded by the edge count. A lower band
can never refill after being finished, because a state's distance is at least
its parent's.

Retained in form: the ranking proxy. Close the partial walk with a straight
line home and ask how round the result would be.

```text
perimeter = drawnSoFar + max(0, home[node] - home[root])
area      = |running shoelace| / 2
shape     = 4 * pi * area / perimeter^2
shortfall = max(0, minMetres - (distance + home[node])) / target
promise   = shape - shortfall - turnPenalty * tightTurns
```

The `turnPenalty` term is the only addition and is the subject of §7. With it
set to zero the ranking is Phase 9's exactly.

Retained incrementally, one constant-time update per arc: distance, the running
shoelace, drawn length, bounding box, maximum radius, depth, compass-octant
family, incoming arc, parent index. Because the shoelace accumulates over the
real edge geometry, the compactness of a **completed** walk is exact — the same
number `compactness()` returns — so `shapeless` is decided at the moment of
closure rather than after assembly.

Three implementation details differ from the prototype and none of them changes
what is searched. The beam's per-node cap uses a stamped counter array rather
than a `Map`, so a band costs no allocation. The band sort is an in-place
dual-array quicksort rather than boxing every candidate. The band keys live in a
`TreeMap` so the minimum is found in log time rather than by scanning.

**No new search algorithm was introduced.** S1 (exhaustive depth-first), S3
(multiple 2-core entries) and S4 (meeting frontiers) were rejected by Phase 9
with measurements and were not revisited.

---

## 5. State store and memory architecture

Phase 9's 137 MB was not a property of the search. The prototype pushed a
twelve-field JavaScript object per generated state into one array and never
freed it, so 643k state objects across the ring were retained for the whole
search when only the current and pending bands were live.

`StateStore` splits the columns by lifetime.

| column group | fields | bytes/state | lifetime |
|---|---|---:|---|
| reconstruction | parent index, incoming arc | 8 | the whole search |
| ranking | distance, shoelace, drawn, minX/maxX/minY/maxY, max radius, node, depth, family, tight turns | 52 | while the state's band is live |

Nothing is an object. Distances and the shoelace are `double` because the
distance band is a completion condition and the compactness of a closed walk is
claimed to be exact; the bounding box and radius are `float`, which at a 3 km
radius is a 0.2 mm quantisation and feeds a ratio the production gate
recomputes anyway. Depth is `short`, family and turn count are `byte`.

The incoming arc is stored rather than the super-edge, which costs the same 4
bytes and buys the arc's own entry and exit bearings — §7 needs them, and the
orientation of the traversal is then implied rather than stored separately.

The used-edge set is a `long[]` bitset over super-edges, marked by walking the
parent chain at expansion and unmarked afterwards, exactly as the prototype did.
The bands are growable `int[]`, and a band that has grown past 4,096 entries
releases its array when drained rather than holding the high-water mark for the
rest of the search.

---

## 6. Band lifecycle and release

States are appended in expansion order and bands are drained in increasing
order, so a state generated while band *k* was draining belongs to band *k* or
later. Each 4,096-state chunk therefore records the highest band key it holds,
and `releaseBelow(liveBand)` drops the ranking columns of every chunk entirely
behind the search — one comparison per chunk, called once per band pass. The
chunk currently being filled is never complete and is never freed.

What survives is the parent chain, which is all a closed walk needs to recover
its arcs. Measured at the retained operating point:

| fixture | states | chunks | chunks released | retained after search | peak live store |
|---|---:|---:|---:|---:|---:|
| douglas-5km | 276,347 | 68 | 66 | 4.62 MB | **5.26 MB** |
| douglas-3km | 144,849 | 36 | 34 | 2.52 MB | 3.16 MB |
| peel-5km | 99,967 | 25 | 23 | 1.26 MB | 2.54 MB |
| onchan-5km | 119,831 | 30 | 28 | 1.26 MB | 2.75 MB |

19 bytes per generated state at the peak, against the prototype's ~490. The
peak is measured from the store's own live columns rather than from a JVM heap
reading, because a heap reading moves when a collection happens to run and is
therefore useless as a per-request budget — §21 reports both and says which is
which.

---

## 7. U-turn handling — and what it did not buy

Phase 9's one quality regression against Phase 3B was u-turns: four across the
twelve offered walks against one. Two mechanisms were added, both derived from
the existing gate and neither harsher than it.

**During the search, a ranking discouragement.** A u-turn in the gate's terms
is a turn of at least `U_TURN_DEGREES` (150°) whose arms, ±45 m along the walk,
come back within `U_TURN_RETURN_METRES` (20 m) of each other. The first half of
that test is local to a junction and the arcs already carry their entry and
exit bearings, so a tight junction return costs `promise` a fixed 0.05. It is
a ranking term and never a prune: the proxy is not the gate's rule, and
rejecting on it would reject walks the gate would accept.

**At closure, the gate's own rule, exactly.** `UTurns.count` is a port of
`countUTurns` in `src/loops/quality.ts` — the same 15 m resample, the same
three-sample window either side, the same 150° and 20 m, the same "one
turn-around, not one per sample that can see it" 60 m separation. It runs on
the assembled metric line of a completed walk, stem included at both ends, and
a walk over `MAX_U_TURNS` is dropped before it can take one of the places
handed to the route service. Nothing about this is a new definition; the
production gate still re-measures every walk and still has the last word.

Measured on the normal ring, both mechanisms off against both on:

| turn aware | offered / 12 | closed walks | dropped on turns | offered u-turns | mean quality | ring search ms |
|---|---:|---:|---:|---:|---:|---:|
| off | 12 | 547 | 0 | **3** | 73.4 | 283 |
| **on** | 12 | 575 | 87 | **4** | **74.0** | 267 |

Per fixture:

| turn aware | fixture | offered | closed walks | dropped on turns | offered u-turns | quality | median err % |
|---|---|---:|---:|---:|---:|---:|---:|
| off | douglas-5km | 3 | 153 | 0 | 0 | 74.3 | 0.8 |
| off | douglas-3km | 3 | 127 | 0 | 1 | 76.0 | 0.1 |
| off | peel-5km | 3 | 123 | 0 | 2 | 66.0 | 2.3 |
| off | onchan-5km | 3 | 144 | 0 | 0 | 77.3 | 0.7 |
| on | douglas-5km | 3 | 153 | 25 | 0 | 74.1 | 0.7 |
| on | douglas-3km | 3 | 128 | 2 | 1 | 75.6 | 0.3 |
| on | peel-5km | 3 | 144 | 59 | 2 | **70.2** | **1.0** |
| on | onchan-5km | 3 | 150 | 1 | 1 | 76.3 | 0.4 |

**This did not do what it was aimed at, and it should be recorded as such.**
The offered u-turn count is 4 with the machinery on and 3 with it off, against
Phase 3B's 1. The gap to Phase 3B is not closed.

The reason is visible in the numbers rather than inferred. 87 walks across the
ring are dropped at closure for exceeding the gate's allowance — closely
matching Phase 9's 91 `u-turns` gate rejections, which is further evidence the
port is faithful — but every walk that *survives* has at most one u-turn, which
is exactly what the gate permits. The four u-turns in the offered set are four
legal walks each carrying one, not one bad walk carrying four. Making them go
away would mean preferring a zero-u-turn walk over a better one, which is a
change to `scoreRoute`'s weights and therefore a change to what Looper thinks a
good walk is. That is not a Phase 10 decision and was not made.

The machinery is retained and ships **on**, on the strength of what it did buy:
Peel's mean quality moves 66.0 to 70.2 and its distance error 2.3% to 1.0%,
because dropping 59 walks the gate would have refused leaves better ones in the
24 handed on. Ring quality is 74.0 against 73.4. It costs nothing measurable in
search time. `LOOPER_DIRECT_TURN_AWARE=false` reproduces the "off" row.

---

## 8. Edge-sequence reconstruction

A closed walk is recovered from its parent chain: two passes over the chain,
one to count the arcs and one to fill them in reverse. Nothing else is stored
per state, and this is what makes §6's release safe.

The full edge sequence handed to GraphHopper is:

```text
stem graph ids  ->  for each arc, the super-edge's graph ids in traversal order
                    (reversed when the arc runs the super-edge backwards)
                ->  stem graph ids, reversed
```

The stem is empty wherever the start is already inside the 2-core, which is
three of the four fixtures.

---

## 9. Geometry assembly

Nothing is re-routed. The edge sequence becomes a `com.graphhopper.routing.Path`
directly: `addEdge` for every id in order, `setFromNode` and `setEndNode` at the
snapped virtual node, `setFound(true)`. `Path.forEveryEdge` walks the sequence
node to node and re-fetches each edge in the traversal orientation, so the
geometry is GraphHopper's own `fetchWayGeometry` on the very edges the search
chose. Distance and time are then summed over `path.calcEdges()` using the
profile's own weighting (wrapped by the `QueryGraph`, so virtual edges are
priced correctly), and the `PathMerger` runs with `simplifyResponse(false)` so
the line that comes back is the network's geometry rather than a smoothed
version of it.

**P8's check — searched distance against returned route distance:**

| fixture | searched m | returned m | difference |
|---|---:|---:|---:|
| douglas-5km, best walk | 4995 | 4995 | 0 |
| douglas-3km, best walk | 2965 | 2965 | 0 |
| peel-5km, best walk | 4995 | 4995 | 0 |
| onchan-5km, best walk | 4979 | 4979 | 0 |

Zero on every walk of every fixture, which it must be: both numbers are the sum
of the same edges' own distances.

**No via points, no sparse anchors, no re-routing.** Phase 9's M3 control
measured what happens otherwise — given three corners of a walk known to be
good, GraphHopper returns something 1,486 m away at median, agreeing on 15% of
its edges, and none of twelve passes the gate. That result is why the
materialisation path here has no router in it.

A walk whose edge sequence the graph cannot replay is dropped and counted
rather than served. It has not happened on any fixture.

---

## 10. Duration

`weighting.calcEdgeMillis(edge, false)` over the oriented edge sequence, summed
onto the `Path` before the merger runs, so `PathMerger` reports it and
`InstructionsFromEdges` apportions it per instruction. On the foot profile this
comes out at 4.98 km/h — a 4,995 m walk is reported as 3,615 s — which is
GraphHopper's own foot speed and not a Looper estimate. The route service then
does exactly what it already does with a Phase 3B leg: reports the engine's
duration, and lets the app re-express it at the walker's own pace.

`durationSeconds` is populated on every returned route.

---

## 11. Instructions and path details

`PathMerger.doWork` with GraphHopper's own `InstructionsFromEdges` and
`PathDetailsBuilderFactory`, requesting the same three details
`src/graphhopper.ts` has always requested: `street_name`, `road_class`,
`edge_id`. No route search runs; instructions are read off the edges.

The response is then serialised by GraphHopper's own
`ResponsePathSerializer`, so each walk's `paths[0]` is **byte-for-byte the
shape the route service already parses**. `parseLeg` reads a searched walk with
the identical code it reads a routed leg with, and nothing downstream — the
step model, the maneuver mapping, the interval indices, the walk screen, the
spoken guidance — has any way of telling which engine produced it.

Measured on the Douglas 5 km walks: 50–84 instructions per walk over 213–341
points, with street names, `sign` codes, headings and intervals present; and
123–250 `edge_id` spans, which is what `measureTraversals` needs for
network-based overlap. `edge_id` maps a virtual edge back to the physical edge
it is a piece of — GraphHopper's `EdgeIdDetails` does this itself — so the
repeated-ground and route-to-route overlap measures see exactly what they see
on the Phase 3B path.

One instruction, from a real Douglas walk:

```json
{ "text": "Turn left onto Hill Street Lane", "street_name": "Hill Street Lane",
  "distance": 131.491, "time": 94673, "sign": -2, "interval": [3, 10] }
```

The wire cost is the honest weak point of this design and is not hidden. A walk
with full geometry, instructions and details is about 25 KB, so the facade's
answer scales linearly with how many walks are handed on:

| walks asked for | response bytes |
|---:|---:|
| 8 | 204 KB |
| 16 | 409 KB |
| **24** | **616 KB** |
| 40 | 1,014 KB |

24 is retained (`LOOPER_DIRECT_CANDIDATE_WALKS`). It is what buys the diversity
selector room to separate three, and on the loopback socket the whole exchange
including parse is inside the 40 ms that separates §20's in-process total from
§23's service wall time.

---

## 12. Reproducing Phase 9 (P24)

The Java engine against the Phase 9 prototype's own recorded runs, read from
`bench/phase9/results/offline.json` rather than retyped.

**Route outcome:**

| fixture | offered P9 / P10 | mean abs error P9 / P10 | mean quality P9 / P10 | repeated % P9 / P10 | u-turns P9 / P10 |
|---|---|---|---|---|---|
| douglas-5km | 3 / 3 | 29 m / 58 m | 73.5 / 74.1 | 0.00 / 0.00 | 1 / 0 |
| douglas-3km | 3 / 3 | 23 m / 16 m | 75.4 / 75.6 | 0.00 / 0.00 | 1 / 1 |
| peel-5km | 3 / 3 | 145 m / 48 m | 66.2 / 70.2 | 0.33 / 0.00 | 2 / 2 |
| onchan-5km | 3 / 3 | 17 m / 16 m | 77.8 / 76.3 | 0.00 / 0.00 | 0 / 1 |

**Search cost, and the graph both searched:**

| fixture | explored nodes P9 / P10 | reduced search nodes P10 | states P9 / P10 | expanded P9 / P10 | closed walks P9 / P10 | dropped on turns P10 | search ms P9 / P10 |
|---|---|---:|---|---|---|---:|---|
| douglas-5km | 6586 / 6586 | 3006 | 277,915 / 276,347 | 133,194 / 131,074 | 188 / 153 | 25 | 367 / 130 |
| douglas-3km | 4395 / 4395 | 2189 | 150,330 / 144,849 | 71,580 / 69,854 | 133 / 128 | 2 | 118 / 52 |
| peel-5km | 1401 / 1401 | 596 | 99,897 / 99,967 | 55,798 / 55,453 | 124 / 144 | 59 | 70 / 33 |
| onchan-5km | 3927 / 3927 | 1554 | 115,147 / 119,831 | 62,143 / 64,589 | 142 / 150 | 1 | 94 / 42 |

The explored graphs are identical to the node. The reduced search graphs
(3006 / 2189 / 596 / 1554) match Phase 9 §6 exactly. States generated agree
within 0.5% to 4%, and expansions within 1.6% to 4% — the residual is the
turn-penalty term in §7's ranking, which reorders states within a band without
changing which are admissible.

Three routes per fixture at both. Distance error is better at three of four and
worse at Douglas 5 km (29 m to 58 m, both far inside the ±600 m band). Quality
is better at three of four. Peel is materially better on both, for the reason
§7 gives.

Exact route identity was not expected and does not hold: a beam is an ordered
process and the two orderings differ. The divergences that were investigated
are the closed-walk counts, and they reconcile — Douglas 5 km's 153 against 188
is 153 kept plus 25 dropped on turns, and Peel's 144 against 124 is what the
turn-penalty ranking changes about which walks the beam carries to closure.

---

## 13. Engine selection

One enum, resolved in one place, carried as a value.
`src/loops/engine.ts`:

```ts
export type RoutingEngine = 'remote' | 'direct'
export const DEFAULT_ROUTING_ENGINE: RoutingEngine = 'remote'
export function resolveRoutingEngine(input: {
  requested?: RoutingEngine
  serverDefault: RoutingEngine
  hasWaypoints: boolean
  directAvailable?: boolean
}): EngineChoice
```

There is deliberately no boolean threaded through the generator asking "am I
the new one". `generateLoops` is the `remote` engine and does not know that;
`generateDirectLoops` is the `direct` engine and does not know about the other.
`server.ts` resolves the choice once, before anything is generated, and
dispatches.

**Precedence, in one place:**

```text
ordered user waypoints          ->  remote, always
an explicit request engine      ->  that engine
LOOPER_DIRECT_CLOSED_WALK_SEARCH ->  direct when true
otherwise                       ->  remote (Phase 3B)
```

Waypoints come first and are not negotiable: an ordered pin list is a different
object from a rooted circuit and Phase 10 does not redesign waypoint routing.
The server flag sets the *default* rather than gating the engine — a client
asking explicitly for `direct` gets it either way, which is what lets the iOS
toggle work against a server still defaulting to Phase 3B.

One further guard is not in the brief and is load-bearing: the region's facade
is asked whether it can search walks at all. `GET /info` now advertises
`looper_closed_walk` beside `looper_model_registry`, and the shipped
GraphHopper container advertises neither. A region behind a plain container
resolves to `engine-unsupported` and is served by Phase 3B rather than failing.
The answer is cached with the graph version and re-asked every five minutes,
alongside the check that already existed.

**New flag:** `LOOPER_DIRECT_CLOSED_WALK_SEARCH`, default `false`. Documented
in `.env.example` with the precedence above; present in both compose files.
Three sizing knobs sit beside it — `LOOPER_DIRECT_CANDIDATE_WALKS` (24),
`LOOPER_DIRECT_MIN_ROUTES` (3), `LOOPER_DIRECT_TIMEOUT_MS` (10,000) — and
`LOOPER_DIRECT_TURN_AWARE` (true) exists only so §7 reproduces.

The engine is part of the route cache key, under `generation`. Two engines
answer the same question with different walks, and a cache that cannot tell
them apart would make an A/B test meaningless.

---

## 14. The common route response

Both engines return the same `LoopRoute[]`: `id`, `label`, `distanceMeters`,
`durationSeconds`, `targetDifferencePercent`, GeoJSON `geometry`, `steps` and
`quality`. The direct path builds them from the same `parseLeg` output the
remote path builds them from, is labelled by the same `labelRoutes`, selected
by the same `selectDiverseRoutes` at the same `MAX_SHARED_FRACTION`, and judged
by the same `analyseRouteQuality` with no threshold relaxed. Nothing was
normalised afterwards because nothing diverged.

Developer metadata is beside the routes and never inside them, so a route means
the same thing whichever engine drew it and the app has nothing to branch on:

```json
{
  "routes": [ … ],
  "engine": {
    "routingEngine": "direct",
    "requestedEngine": "direct",
    "engineReason": "requested",
    "generationMs": 208,
    "searchStates": 276347,
    "searchClosedWalks": 153,
    "searchTurnRejections": 25,
    "searchOfferedWalks": 3,
    "searchMs": 144.1,
    "searchPeakBytes": 5259264,
    "searchRetainedBytes": 4620288,
    "searchStemMetres": 0,
    "offered": { "medianDistanceErrorPercent": 0.7, "maxPairSharedEdgePercent": 44.8, … }
  }
}
```

`engineReason` is one of `requested`, `server-default`, `waypoint-fallback`,
`engine-unsupported`. `fallbackReason` appears when Direct Search ran and handed
the request back. `offered` is the same `measureOffered` both engines report, so
a paired benchmark compares one measurement rather than two derivations of it.

The whole block is optional: a service that predates it sends nothing, and the
iOS client reads that as `remote`, which is what it is. `contracts/loop-api/v1.md`
carries the request field and the response block.

---

## 15. iOS — the toggle and its persistence

**Settings → Temporary testing → Routing engine**, an inline `Picker` in the
section the navigation diagnostics already live in:

```text
Routing Engine
   Remote / Current
 • Direct Search / New
```

Native controls, no screen redesigned, and the whole section — picker, trials
list and badge — disappears with `RoutingTrialLog.includedInThisBuild`.

Persistence uses the mechanism every other preference in `AppModel` uses: a
`@Published` property with a `didSet` writing to `UserDefaults` under
`routing-engine`, read back in the property's initialiser. Select Direct
Search, close the app, reopen it, and Direct Search is still selected. The
default is `.remote`.

Normal loop generation sends the selection.
`LooperKit.requestLoops(… routingEngine: RoutingEngine? = nil …)` encodes it
with `encodeIfPresent`, so a client that has not chosen sends a body byte-identical
to the one it has always sent. Nothing else about the request differs, and the
request implementation is not duplicated.

Verified: `swift build`, `xcodebuild` for the simulator and for a generic iOS
Simulator destination all succeed; the app installs and launches on the
simulator. There is no UI-automation tool on this machine (`idb` is not
installed and `simctl` cannot tap), so the picker and badge were exercised
through unit tests over the request and response contract rather than by
driving the screens — five tests in
`LooperKit/Tests/LooperKitTests/RoutingEngineTests.swift`, covering the engine
being sent, being omitted when unset, being read back, a waypoint fallback
being surfaced, and a service that reports no engine at all. All 122 LooperKit
tests pass.

---

## 16. Waypoint fallback

A request carrying ordered waypoints is answered by Phase 3B whatever engine
was asked for. The decision is `resolveRoutingEngine`'s and is taken before any
generation starts; `generateDirectLoops` also refuses one outright, which is
belt and braces rather than a second rule. The answer reports
`routingEngine: "remote"`, `requestedEngine: "direct"`,
`engineReason: "waypoint-fallback"`.

It is not an error and does not read as one. The route screen's badge shows
`REMOTE` with the note *"waypoints use the current engine"* in secondary text.
Nothing is spoken, nothing is coloured as a warning, and the walker is not
told the app failed at anything.

**Regression check** — the two waypoint probes, asked for both engines:

| fixture | engine asked | engine used | wall ms | routes | median err % | quality | repeated % | GH calls |
|---|---|---|---:|---:|---:|---:|---:|---:|
| wp-one | remote | remote | 113 | 1 | 15.2 | 57.2 | 0.4 | 34 |
| wp-one | **direct** | remote | 117 | 1 | 15.2 | 57.2 | 0.4 | 34 |
| wp-two | remote | remote | 636 | 1 | 17.6 | 51.3 | 0.3 | 285 |
| wp-two | **direct** | remote | 607 | 1 | 17.6 | 51.3 | 0.3 | 285 |

Identical, to the call. Asking for Direct Search on a waypoint request changes
nothing at all about the answer.

---

## 17. Failure fallback

Direct Search answers a request whole or hands it back. It never mixes its
walks with Phase 3B's, and it never offers fewer than a whole answer while
Phase 3B could serve one. Both halves of that are deliberate: a mixed set is a
set nothing has judged for diversity *as a set*, with two different notions of
what a leg is inside one answer, and it would make an A/B walk in the field a
comparison between two blends rather than between two engines.

The reasons it hands back, all of them recorded:

| `fallbackReason` | when |
|---|---|
| `waypoints` | ordered pins reached the direct path (the selector normally catches this first) |
| `search-no-network` | the start snapped to nothing |
| `search-no-circuit` | the 2-core is empty after peeling |
| `no-closed-walk` | the search closed nothing |
| `gate-rejected-all` | walks were found and the production gate refused every one |
| `too-few-diverse` | fewer than `LOOPER_DIRECT_MIN_ROUTES` survived the diversity selector |
| `search-timeout` / `search-transport` / `search-server` | the facade did not answer, including the 404 from one that does not know the endpoint |

The whole request then runs Phase 3B exactly as it would have. The response
carries `requestedEngine: "direct"`, `routingEngine: "remote"` and the reason,
and the service logs a `direct-fallback` line with the closed-walk and offered
counts. Nothing falls back silently.

The cost is honest and worth stating: a fallback pays for both engines. At Peel
10 km that is 2,559 ms against Phase 3B's own ~2,450 ms — the search itself is
109 ms of it, so the overhead is small in relative terms and real in absolute
ones.

`LOOPER_DIRECT_MIN_ROUTES` defaults to 3, which is the strict reading of P22.
Setting it to 1 would let Direct Search answer with what it found; that was not
made the default because a two-walk answer from the new engine beside a
three-walk answer from the old one is not a comparison.

---

## 18. The developer engine badge

A single small row above the route list on the choices screen:

```text
DIRECT   176 ms
```

`REMOTE` on a faint white ground, `DIRECT` on a faint accent one, with the
service's own `generationMs` beside it, and — only when the engine that
answered is not the engine that was asked for — one line of secondary text
saying why. It is `.caption2`, it is grey, and it sits under the error line and
above the waypoint hint. It is not a production element and it disappears with
the rest of the testing section.

The route model also carries its own provenance:
`Route.routingEngine` is stamped from the answer's report, so a saved favourite
and the walk screen both know which engine drew the line, and the badge is
correct even for a route reopened later.

---

## 19. Logging and test telemetry

**Server side.** The existing structured log gains `engine` on every `loops`
line, and a `direct-fallback` warn line with the reason, closed-walk count and
offered count. The direct path logs the facade's own stage timings. No
coordinate is added to anything that was not already logging one, and the
existing coarse-location rule is unchanged.

**Device side.** `RoutingTrialLog` — deliberately the same shape as the
`NavigationLogger` that is already there: a JSON file in Application Support, a
plain-text export shared through the standard iOS sheet, nothing leaving the
device until the tester chooses to send it, and no analytics backend. One row
is written the moment a set of walks arrives, capturing everything P19 asks for:

```text
timestamp, routing engine, requested engine, engine reason, fallback reason,
mode, activity, requested distance, every generated route distance,
round-trip ms, service generation ms, search ms, closed walks,
whether waypoints were present, start coordinate (3 dp, ~100 m),
which route was selected
```

The start is rounded to three decimal places on purpose: enough to tell Peel
from Onchan, not enough to be a record of anyone's front door.

**Rating (P20).** Settings → Routing engine trials lists the rows; opening one
gives a verdict — `Good` / `Acceptable` / `Bad` — a multi-select of the issue
categories the brief names (distance wrong, poor shape, unpleasant path,
retracing, navigation/instruction issue, not meaningfully different, other) and
a free-text note, with the generation's own numbers shown underneath so the
rating is made against what was actually produced. Export is a tab-separated
file with a header row: small enough to paste into a message, regular enough to
open in a spreadsheet.

This is under 300 lines of Swift and adds no backend, no account and no network
call. It is capped at 300 trials.

---

## 20. Java benchmark (P23)

`DirectBench`, median of five warm runs per fixture after a warm-up run,
`-Xmx4g`, inside the harness container against the same graph volume the
service uses.

| fixture | subgraph explore | graph reduce | search | judge | route + instruction assembly | **total** | states expanded | states generated | closed walks | gate passes handed on | offered |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | 7.4 | 5.8 | 131.0 | 2.2 | 11.1 | **161.2** | 131,074 | 276,346 | 153 | 24 | 3 |
| douglas-3km | 4.3 | 3.3 | 50.9 | 1.1 | 5.0 | **64.9** | 69,854 | 144,848 | 128 | 24 | 3 |
| peel-5km | 1.4 | 1.4 | 35.5 | 1.7 | 5.0 | **45.1** | 55,453 | 99,966 | 144 | 24 | 3 |
| onchan-5km | 3.6 | 2.1 | 39.0 | 1.7 | 3.7 | **51.7** | 64,589 | 119,830 | 150 | 24 | 3 |

Milliseconds. `judge` is the exact compactness, bounding-box and u-turn tests
plus the octant-quota selection over every closed walk. `assembly` is route
geometry, duration, instructions and path details for all 24 handed on — about
0.4 ms per walk, and instruction generation is the bulk of it.

GraphHopper **routing calls: 0**, at every fixture. The only GraphHopper work is
the bounded exploration in the first column.

Ring total, in process: **323 ms**. Phase 9's was 771 ms.

---

## 21. Memory benchmark (P27)

| fixture | states generated | peak live store | retained after search | bytes/state at peak | JVM heap delta (noisy) |
|---|---:|---:|---:|---:|---:|
| douglas-5km | 276,346 | **5.26 MB** | 4.62 MB | 19.0 | 0.0–35.6 |
| douglas-3km | 144,848 | 3.16 MB | 2.52 MB | 21.8 | 16.8–17.8 |
| peel-5km | 99,966 | 2.54 MB | 1.26 MB | 25.4 | 9.4 |
| onchan-5km | 119,830 | 2.75 MB | 1.26 MB | 22.9 | 11.5 |

Against Phase 9's 137 MB peak at Douglas 5 km: **26x**.

The last column is reported and then set aside. It is
`totalMemory - freeMemory` sampled per band against a baseline taken before the
search, and it moved between 0.0 MB and 35.6 MB for the *same* Douglas 5 km
search across runs, depending on whether a collection happened to run inside
the window. That is exactly why the store's own live-column high-water mark is
the number this phase reports: it is exact, it is GC-independent, and it is the
thing that could grow with every state ever generated.

**Growth is not proportional to every state ever generated.** 68 chunks are
allocated at Douglas 5 km and 66 are released during the search; what is left is
the parent chain, 8 bytes a state.

**Repeated requests, same fixture, heap read after a collection each time:**

| request | offered | settled heap |
|---:|---:|---:|
| 4 | 24 | 34.5 MB |
| 8 | 24 | 33.5 MB |
| 12 | 24 | 33.5 MB |
| 20 | 24 | 33.5 MB |
| 32 | 24 | 33.5 MB |
| 40 | 24 | 33.5 MB |

Flat from the eighth request to the fortieth. Nothing accumulates.

---

## 22. Retained Phase 3B behaviour

Phase 3B is unchanged and is still production. The evidence is that its own
numbers reproduce to the call:

| | Phase 9's captured reference | this checkout |
|---|---:|---:|
| offered routes, normal ring | 12 / 12 | 12 / 12 |
| GraphHopper calls, normal ring | 978 | **978** |
| mean quality | 67.6 | **67.63** |
| mean repeated ground | 1.88% | **1.88%** |
| u-turns across the offered ring | 1 | **1** |
| wp-one / wp-two calls | 34 / 285 | **34 / 285** |

Nothing in `generate.ts`, `routing.ts`, `quality.ts`, `diversity.ts`,
`avoidance.ts`, `waypoints.ts` or `edges.ts` was changed. `LoopRequest` gained
one optional field that the generator never reads and `LoopResponse` gained one
optional block beside the routes. `LooperRoutingCore.exploreSubgraph` was
refactored to delegate and returns the same record it always did.

All 506 route-service tests pass, `npm run lint` and `npm run typecheck` are
clean, and all 122 LooperKit tests pass.

---

## 23. Paired benchmark: Phase 3B against Direct Search (P25)

One service, one facade, alternating engines, median of three warm rounds after
a warm pass. All six production probes.

### Normal ring

| fixture | engine | actual | wall ms | routes | median err % | quality | repeated % | u-turns | overlap % | edge overlap % | GH calls | states | search ms | peak store |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | remote | remote | 349 | 3 | 8.0 | 69.3 | 0.27 | 0 | 37.8 | 38.5 | 238 | — | — | — |
| douglas-5km | **direct** | direct | **176** | 3 | **0.7** | **74.1** | **0.00** | 0 | 53.9 | 44.8 | **0** | 276,347 | 136.4 | 5.14 MB |
| douglas-3km | remote | remote | 113 | 3 | 6.5 | 66.8 | 1.30 | 0 | 25.8 | 4.5 | 96 | — | — | — |
| douglas-3km | **direct** | direct | **75** | 3 | **0.3** | **75.6** | **0.00** | 1 | 73.8 | 49.2 | **0** | 144,849 | 50.4 | 3.09 MB |
| peel-5km | remote | remote | 508 | 3 | 2.3 | 70.0 | 1.97 | 1 | 28.0 | 27.0 | 530 | — | — | — |
| peel-5km | **direct** | direct | **55** | 3 | **1.0** | **70.2** | **0.00** | 2 | 44.2 | 41.1 | **0** | 99,967 | 32.5 | 2.48 MB |
| onchan-5km | remote | remote | 122 | 3 | 3.6 | 64.4 | 3.97 | 0 | 17.4 | 15.5 | 114 | — | — | — |
| onchan-5km | **direct** | direct | **66** | 3 | **0.4** | **76.3** | **0.00** | 1 | 23.9 | 24.3 | **0** | 119,831 | 41.5 | 2.69 MB |

### Waypoint probes — regression checks

See §16. Identical to the call under both engines.

### Normal-ring totals

| engine | offered / 12 | mean median err % | mean quality | mean repeated % | u-turns | GraphHopper calls | ring wall |
|---|---:|---:|---:|---:|---:|---:|---:|
| Phase 3B | 12 | 5.1 | 67.63 | 1.88 | **1** | 978 | 1,092 ms |
| **Direct Search** | **12** | **0.6** | **74.05** | **0.00** | 4 | **0** | **372 ms** |

Direct Search is better on coverage (equal), distance error (8x), quality
(+6.4), retracing (all of it), routing calls (all of them) and wall time (2.9x).
It is worse on two axes and both are stated plainly:

**U-turns, 4 against 1.** §7 measures this and does not fix it. Every offered
walk carries at most one, which the gate permits.

**Separation between the offered walks.** Geometric worst-pair overlap is
53.9% / 73.8% / 44.2% / 23.9% against Phase 3B's 37.8% / 25.8% / 28.0% / 17.4%.
Douglas 3 km at 73.8% is above the 55% bar on the geometric measure. It is
inside it on the measure the selector actually used — 49.2% on the network,
which is what `selectDiverseRoutes` prefers when both routes report edge ids —
so nothing was let through that the production rule refused. But the two
measures disagreeing by 24 points is a real finding: a searched walk and its
neighbour can run the same corridor on opposite pavements, which the network
measure sees as different edges and the eye sees as the same street. Phase 9
saw the same effect (48.8% at Douglas 3 km) and it has not got better. **This is
the thing to watch on the first real walks**, and it is exactly what §19's
"not meaningfully different" issue category is there to capture.

---

## 24. Smoke tests: 2, 3, 5, 8 and 10 km (P28)

Direct Search requested at every row; a `remote` engine column is the automatic
fallback working.

| start | km | engine | fallback | routes | mean err % | quality | u-turns | closed walks | states | search ms | peak store | wall ms |
|---|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas | 2 | direct | — | 3 | 1.4 | 80.4 | 0 | 152 | 98,944 | 31.0 | 2.27 MB | 51 |
| douglas | 3 | direct | — | 3 | 0.5 | 75.6 | 1 | 128 | 144,849 | 51.4 | 3.09 MB | 79 |
| douglas | 5 | direct | — | 3 | 1.2 | 74.1 | 0 | 153 | 276,347 | 129.9 | 5.14 MB | 175 |
| douglas | 8 | direct | — | 3 | 4.5 | 64.9 | 1 | 204 | 423,742 | 284.3 | 8.05 MB | 353 |
| douglas | 10 | direct | — | 3 | 5.9 | 62.4 | 1 | 129 | 506,671 | 405.6 | 6.59 MB | 478 |
| peel | 2 | **remote** | too-few-diverse | 3 | 3.9 | 66.4 | 0 | 84 | — | 6.9 | — | 241 |
| peel | 3 | direct | — | 3 | 5.2 | 63.6 | 1 | 84 | 54,533 | 14.6 | 1.55 MB | 28 |
| peel | 5 | direct | — | 3 | 1.0 | 70.2 | 2 | 144 | 99,967 | 32.7 | 2.48 MB | 58 |
| peel | 8 | **remote** | too-few-diverse | 3 | 7.1 | 60.1 | 2 | 80 | — | 83.4 | — | 2,058 |
| peel | 10 | **remote** | too-few-diverse | 3 | 6.5 | 62.4 | 0 | 103 | — | 108.8 | — | 2,559 |
| onchan | 2 | direct | — | 3 | 1.4 | 79.4 | 0 | 87 | 38,376 | 9.3 | 1.34 MB | 20 |
| onchan | 3 | direct | — | 3 | 1.0 | 80.0 | 0 | 108 | 66,022 | 18.1 | 1.76 MB | 34 |
| onchan | 5 | direct | — | 3 | 0.3 | 76.3 | 1 | 150 | 119,831 | 41.3 | 2.69 MB | 67 |
| onchan | 8 | direct | — | 3 | 3.6 | 68.3 | 1 | 64 | 197,110 | 85.0 | 3.92 MB | 135 |
| onchan | 10 | direct | — | 3 | 0.6 | 72.9 | 1 | 86 | 281,640 | 140.9 | 6.00 MB | 193 |

Three routes at every one of the fifteen. No search failure, no state
explosion, no runaway memory: states grow roughly linearly with target and peak
store stays under 8 MB at the largest.

Two things are worth naming rather than glossing.

**Cost grows with target, and 10 km is where it starts to matter.** Douglas
10 km is 478 ms end to end, 406 ms of it search, against 175 ms at 5 km. That
is inside any reasonable budget but it is 2.7x, and the exploration bound is
0.56 x target so the searched region grows with the square.

**Quality falls at long targets.** Douglas drops from 74.1 at 5 km to 64.9 at
8 km and 62.4 at 10 km, and mean distance error rises from 1.2% to 5.9%. The
walks still pass the gate. This is not a defect discovered here — Phase 3B has
the same shape of problem — but it does mean the direct engine's advantage is
largest at the 3–5 km lengths the fixtures were built around.

**Peel falls back at 2, 8 and 10 km.** Every one is `too-few-diverse`: the
search found 80–103 closed walks and the diversity selector could not separate
three. Phase 9's oracle established that Peel holds exactly three mutually
diverse qualifying walks *at 5 km*; there is no reason it should hold three at
every length, and this is the same finding at other distances rather than a new
failure. The fallback served three routes each time.

---

## 25. Starts outside the 2-core (P29)

Five 5 km requests at increasing remove from a circuit. `stem m` is what the
search measured, not what was assumed.

| start | what it is | engine | fallback | stem m | routes | quality |
|---|---|---|---|---:|---:|---:|
| Douglas centre | already in the 2-core | direct | — | 0.0 | 3 | 74.1 |
| Peel | snaps outside the core | direct | — | **60.3** | 3 | 70.2 |
| Niarbyl | coast road end | **remote** | gate-rejected-all | 0.0 | **0** | — |
| Point of Ayre | the northern tip | **remote** | gate-rejected-all | **151.6** | 2 | 47.9 |
| Sulby glen | single lane up a valley | **remote** | too-few-diverse | 0.0 | 2 | 40.0 |

The behaviour is exactly what Phase 9's rejection of prototype S3 predicted.
Inside the core, no stem and the best results. At the doorstep, a 60.3 m stem —
inside the gate's own 75 m exemption, costing nothing, and three routes. Past
it, at Point of Ayre's 151.6 m, the stem metres become reverse retracing the
gate charges for, and every closed walk is refused: 37 found, none accepted.

**Direct Search does not force a poor circuit from a start far outside the
core. It hands the request back.** Phase 3B then answers with what it can, which
at these three starts is nothing, two walks and two walks — Phase 3B finds this
ground hard too, and Niarbyl has no 5 km loop either engine can offer.

The stem is a doorstep, not a structure, and that remains the retained design.
No new stem allowance was introduced; the 75 m is the gate's own.

---

## 26. Dense-graph sanity test (P30)

There is no denser fixture in the imported data. The stack imports the Isle of
Man; the England extract is configured but not imported on this machine, and the
brief says not to add a map region for this phase.

The largest search this data can pose is Douglas at 10 km — 506,671 states over
an exploration bounded at 5,600 m, in 406 ms at 6.59 MB peak store, with three
routes offered. That is reported as what it is: the biggest available case, not
a city test.

**This is a genuine gap.** A dense European city centre would have several times
Douglas's junction density inside the same radius, and the beam's cost is in
arcs expanded rather than in area. Nothing here says the search behaves well
there, and nothing here says it does not. It is named in §27.

---

## 27. Known limitations

1. **No dense-city measurement.** §26. The largest graph tested is Douglas at
   10 km. This is the biggest unknown carried into field testing.
2. **U-turns are not improved.** §7. Four across the offered ring against
   Phase 3B's one, and the mechanism built to close it did not. Closing it
   properly means changing `scoreRoute`'s simplicity weight, which is a change
   to what Looper thinks a good walk is and was out of scope.
3. **Geometric separation between offered walks is worse than Phase 3B's**, and
   at Douglas 3 km the geometric measure (73.8%) and the network measure
   (49.2%) disagree by 24 points. §23. Real walking is the test.
4. **Quality degrades above about 5 km.** §24. 74.1 at 5 km, 62.4 at 10 km.
5. **A fallback pays for both engines.** §17. Up to ~2.6 s at Peel 10 km.
6. **Peel cannot always supply three separable walks**, and neither can a start
   well outside the 2-core. §24, §25. The fallback covers both; the cost is the
   latency in (5).
7. **The wire payload is 616 KB per request** at 24 candidate walks. §11.
   Negligible on a loopback socket, not negligible if the facade is ever moved
   off the route service's own host.
8. **Waypoints are untouched.** An ordered pin list has no representation in a
   rooted-circuit search and Phase 10 did not design one.
9. **`time` mode has no re-aim.** Phase 3B re-measures and resizes once when a
   duration target is missed; the direct engine targets metres and, if the
   resulting durations fail the gate, hands the request back to Phase 3B, which
   does have the retry. It works — 60 minutes from Douglas returns three walks
   of 4,866–5,036 m in 3,509–3,653 s, on the direct engine — but on ground
   where GraphHopper's foot speed and the walker's pace disagree, time-mode
   requests will fall back more often than distance-mode ones. Only spot-checked;
   there is no time-mode fixture in the probe set.
10. **The iOS screens were not driven by UI automation.** §15. Built, launched
    and covered by contract tests; the picker and badge themselves were read
    rather than tapped.

---

## 28. Exact reproduction

From `route-service/`, with the GraphHopper container on `:8989`.

```sh
# The facade, carrying the direct engine
docker build -t looper-gh-harness gh-harness
docker rm -f looper-core 2>/dev/null || true
docker run -d --name looper-core -p 8991:8991 \
  -v looper_graph-cache-iom:/data/graph-cache:ro -v "$PWD/graphhopper:/gh:ro" \
  --entrypoint java looper-gh-harness -Xmx2g -Xms256m \
  -cp /h/gh-harness.jar com.looper.routing.Serve /gh/config.yml /data/graph-cache 8991
curl -s localhost:8991/info    # capabilities must include looper_closed_walk

# P23, P27 - the Java engine alone: every stage, exact memory, and a leak check
docker build -t looper-phase10 gh-harness
docker run --rm --entrypoint java \
  -v looper_graph-cache-iom:/data/graph-cache:ro \
  -v "$PWD/graphhopper:/gh:ro" -v "$PWD/bench/phase10:/work" \
  looper-phase10 -Xmx4g -Dlooper.direct.leakRuns=40 -cp /h/gh-harness.jar \
  com.looper.routing.direct.DirectBench /gh/config.yml /data/graph-cache \
  /work/fixtures.json /work/results/java-bench.json 5

# P25 - Phase 3B against Direct Search, alternating, on the six probes
npx tsx bench/phase10/paired.mts

# P6 - what turn awareness is worth, on and off
npx tsx bench/phase10/turns.mts

# P28, P29, P30 - 2/3/5/8/10 km, and starts at increasing remove from the core
npx tsx bench/phase10/smoke.mts

# P24 - against the Phase 9 prototype's own recorded runs
npx tsx bench/phase10/compare9.mts

# One request, by hand, either engine
curl -s -X POST localhost:8991/looper/closed-walk -H 'content-type: application/json' \
  -d '{"lat":54.1506,"lng":-4.4816,"targetMetres":5000,"wanted":24}' | head -c 400

# verification
npm run typecheck && npm run lint && npm test
(cd ../ios/LooperKit && swift build && swift test)
(cd ../ios/Looper && xcodegen generate && xcodebuild -project Looper.xcodeproj \
  -scheme Looper -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build build)
```

Generated artifacts:

```text
bench/phase10/results/java-bench.json
bench/phase10/results/paired.json
bench/phase10/results/turns.json
bench/phase10/results/smoke.json
bench/phase10/results/compare9.json
```

Knobs: `REPEATS`, `GH_URL`, `PORT` for the TypeScript benchmarks;
`-Dlooper.direct.{wanted,beam,band,perNode,quota,turnAware,leakRuns}` for the
Java one. Service knobs are in `.env.example` under "The direct closed-walk
engine".

To try it in the app: point `LOOPER_API_BASE` at a service whose
`GRAPHHOPPER_IOM_URL` is the facade above, then Settings → Temporary testing →
Routing engine → Direct Search / New.

---

## 29. What the brief asked not to change

Untouched, and verified untouched by §22's reproduction: Phase 4 closure
reservation; Phase 5 full-shape prediction; Phase 6 perimeter repayment
(`LOOPER_PERIMETER_RETENTION` still default off); Phase 7 anchor families;
Phase 8 pairwise anchors; GraphHopper's `round_trip`; every quality and
diversity threshold; waypoint routing; Phase 3B itself. No searched walk is
re-routed through sparse anchors. No Isle-of-Man-specific constant, sector or
bound was added, and nothing was tuned for Peel — Peel's improvement in §7 is a
consequence of applying the gate's own u-turn rule earlier, and the same rule
changes Onchan by one walk and Douglas by none. Direct Search is not the
default. No fallback is silent.

---

## 30. Recommendation

**READY FOR SUSTAINED iOS FIELD TESTING.**

Every condition the brief set for that classification is met and measured:

```text
3 normal routes remain reliable   12/12 on the ring, 15/15 across 2-10 km at
                                  Douglas and Onchan, with the fallback
                                  covering the six cases that fell short
memory is bounded                 5.26 MB peak, 4.62 MB retained, flat over
                                  40 repeated requests
instructions work                 50-84 per walk with street names, signs,
                                  headings and intervals, built from the
                                  searched edges without a second search;
                                  duration populated; the existing iOS
                                  instruction parsing is untouched because the
                                  wire shape is unchanged
the iOS toggle works              persisted, sent, honoured, and the answer
                                  says which engine ran
fallback works                    seven named reasons, all logged, all visible
                                  in the response, waypoints always Phase 3B
performance is practical          176 ms at Douglas 5 km against a 300 ms
                                  target and a 250 ms strong bar; 372 ms for
                                  the whole normal ring against Phase 3B's 1,092
```

What to do next, in order:

1. **Walk it.** The three things that cannot be settled offline are whether the
   direct walks are *pleasant*, whether two of them being 74% geometrically
   overlapped reads as two walks or as one, and whether the instructions make
   sense on the ground at a junction the search chose rather than a router did.
   §19's rating exists for exactly these and its "not meaningfully different"
   category is the one to watch.
2. **Do not flip the server default.** Leave
   `LOOPER_DIRECT_CLOSED_WALK_SEARCH=false` and let the app ask. A default
   flipped before the walking is done makes the walking uninterpretable.
3. **Then decide about the two known regressions** — u-turns and geometric
   separation — with real walks rather than with metrics. Both have a clear
   lever (`scoreRoute`'s simplicity weight; `selectDiverseRoutes` preferring the
   worse of the two overlap measures rather than the network one), and both
   levers change what Looper thinks a good walk is, which is a decision that
   should be made on evidence from the ground.
4. **Measure a dense city before shipping anywhere that is one.** §26.

Phase 9 said the algorithm question was answered and that Phase 10 was
engineering. That turned out to be true: no new search idea was needed, the
formulation ported without incident, and both of the reasons Phase 9 withheld an
A are now numbers rather than concerns. What is left is not research either. It
is walking.
