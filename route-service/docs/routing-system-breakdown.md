# Looper route-service: routing system breakdown

Prepared as a technical reference for external AI analysis. Covers the
loop-routing service at `route-service/` in the Walkabout repo as of commit
`c555a5b` on `new-maths`. All file paths are relative to `route-service/`.

Several numbers below are measured against the live Isle of Man engine rather
than estimated; those are marked **(measured)**. Where a claim rests only on
the synthetic benchmark it says so, because the benchmark has been wrong about
real behaviour more than once — see §12.

## 1. What this system does

Given a start point and a target walking distance or duration (optionally with
an ordered list of must-visit waypoints), the service returns up to 3 distinct
walking **loops** (start = end) that satisfy the target and read as a sensible
walk on a map — not a scribble, not a there-and-back, not three readings of the
same streets.

It is **not** a shortest-path service and does not expose GraphHopper's own
round-trip algorithm. It builds loops itself, on top of an ordinary
point-to-point pathfinder, because the pathfinder alone has no concept of "come
back a different way" or "look like a nice walk."

## 2. High-level architecture

```
Client (PWA / iOS app)
  │  POST /v1/loops { start, distanceKm|durationMinutes, waypoints?, exclude?, ... }
  ▼
route-service (Node/TypeScript, src/server.ts)
  │  validates, per-IP rate limit, per-request AbortController/deadline,
  │  optional exact-request cache (off), per-request RequestMetrics
  ▼
loops/generate.ts                                        [ORCHESTRATOR]
  │  generateLoops()                    ordinary loops
  │  generateBackboneWaypointLoops()    waypoint loops, current
  │  generateWaypointLoops()            waypoint loops, older fallback
  ▼
   ┌────────────────────────────┬─────────────────────────────┐
   ▼                            ▼                             ▼
loops/routing.ts          loops/waypoints.ts           loops/network.ts
buildLoopIncrementally()  backbone + slack DP          reachability probe (off)
   │                            │
   └────────────┬───────────────┘
                ▼
loops/avoidance.ts — buildAvoidanceAreas(), avoidanceCustomModel()
                ▼
GraphHopperClient (src/graphhopper.ts)  →  POST /route, GET /spt
                ▼
Self-hosted GraphHopper 11.0, one JVM per region
  (Isle of Man, England — src/regions.ts), pedestrian profile "foot"
```

Every finished candidate is measured and gated by `loops/quality.ts` — using
`loops/edges.ts` for overlap where the engine reported edge ids — and the
survivors are picked by `loops/diversity.ts`.

Supporting modules: `loops/flags.ts` (algorithm switches), `loops/metrics.ts`
(per-request cost telemetry), `loops/pareto.ts`, `loops/repair.ts`,
`loops/screening.ts`, `loops/cache.ts` — the last four all currently switched
off, see §11.

## 3. The underlying pathfinder: GraphHopper, deliberately without CH

- GraphHopper 11.0, self-hosted (`graphhopper/Dockerfile`,
  `graphhopper/config.yml`), one instance per region with its own OSM extract
  and heap (2 GB Isle of Man, 6 GB England — `docker-compose.prod.yml`).
- Single profile `foot`, defined by a **custom model**
  (`graphhopper/looper_foot.json`) replacing GraphHopper's stock `foot.json`:
  it zeroes out inaccessible/dangerous edges but deliberately **does not**
  apply the stock road-class preference, because a loop generator aiming in
  many directions needs "one residential street is as good as another".
- **Contraction Hierarchies is explicitly disabled** (`profiles_ch: []`). CH
  bakes one weighting into the graph and cannot accept the per-request custom
  models Looper's avoidance corridors depend on.
- **Landmarks** is enabled instead: valid as long as a request only ever
  *raises* edge cost, which is all the avoidance areas do.
- Requests set `'ch.disable': true`, and ask for ordinary **point-to-point**
  routes only — one call per leg, never GraphHopper's round-trip mode.
- Path details requested: `street_name`, `road_class`, **`edge_id`**. The last
  is what makes overlap measurable on the network (§6.1). It works against the
  live engine **(measured:** 42 of 43 candidates in a sample request were
  measured on edges, one fell back to geometry**)**.
- `GET /spt` (shortest-path tree) is used by the optional reachability probe
  (§9). It has its own short timeout and fails open.

**Consequence worth stating plainly:** every priority rule in the profile is a
multiplier at or below 1, and GraphHopper divides by priority — so the route it
returns can be physically *longer* than the shortest path, and is **not** a
lower bound on distance. Anything that refuses a request for being too long
needs a real floor; see §8.2.

### 3.1 What a call actually costs **(measured)**

| | ms per call |
|---|---|
| leg with no custom model | 20–46 |
| leg with 1–3 avoidance polygons | 34–60 |

No call ever carries more than 3 areas — the union merges corridors before
sending — so `MAX_AVOIDANCE_AREAS = 12` is never approached and lowering it
would do nothing. Polygons add roughly 45%, but the ~40 ms floor is
GraphHopper's flexible (non-CH) routing and is the dominant cost.

**The engine saturates at roughly 90 foot-legs per second.** Raising
per-request concurrency from 6 to 12 doubled achieved parallelism and doubled
per-call latency, leaving throughput flat-to-worse (92.6 → 77.1 calls/s) and
one fixture 2.6× slower. Latency is therefore bounded by *calls made × cost per
call*, and the only levers are sending fewer calls — not asking for more at
once. `ROUTING_CONCURRENCY` stays at 6, with that measurement recorded beside
it in `docker-compose.prod.yml`.

## 4. Candidate generation: deterministic multi-start sampling

`loops/candidates.ts`:

- `generateLoopAttempts(seed, count)` produces `count` (default 24 in
  production, `DEFAULT_ATTEMPT_COUNT = 16` otherwise) deterministic starting
  bearings, spread evenly round the compass with ±12° jitter.
- Seeded PRNG (`mulberry32`, `loops/random.ts`); seed derived from start
  coordinate (rounded to ~11 m), target distance and the client's `variation`.
  Same request → same loops; `variation + 1` → a different deterministic set.
- Attempts come in **mirrored pairs** — the same bearing clockwise and
  anticlockwise.
- **`spreadAcrossCompass(attempts)`** reorders the batch by bit-reversal of the
  pair index, so *any prefix* of the dispatched attempts already covers the
  compass rather than one arc of it. This matters because the generator stops
  partway (§7): in dispatch order, the first six attempts were the first
  quarter of the dial. Worth **−13.8% engine calls** with better-separated
  alternatives; on by default (`LOOPER_SPREAD_BEARINGS`).
- This is the only randomness in the system, and it is fully reproducible.

## 5. Building one candidate loop

`loops/routing.ts` — `buildLoopIncrementally(...)`: greedy incremental
construction with bounded local retries and geometric post-repair. The
shortest-path search itself is GraphHopper's, per leg.

1. **Corner count** — `CORNER_COUNTS_TO_TRY = [3, 2, 1, 4]`, stopping at the
   first shape that passes. The order *is* the cost: most ground wants a
   three-cornered ring, and starting there rather than at a two-legged
   there-and-back is **6% of all engine calls** for no change to what is
   offered. `LOOPER_NARROW_CORNER_SWEEP` narrows this to `[3, 2]` — a further
   26%, at about one walk in twenty and some separation; off, see §11.
   `LOOPER_PROGRESSIVE_CORNER_SWEEP` instead makes the sweep the *outer* loop:
   every bearing at three corners, then only the bearings that failed get two,
   and only what still fails gets one and four. Same shapes, same order, but a
   bearing that never works no longer pays for all four before any other
   bearing is asked a question. −8.7% calls, or −11.1% alongside
   `diversityAwareEarlyStop`, with no walk lost anywhere; off, see §11.
2. **Leg-by-leg construction** — remaining budget ÷ legs left decides how far
   the next leg aims, on a heading stepped round the compass. Live planning;
   the shape is not decided up front.
3. **Per-leg routing** (`routeLegAttempt`) — one point-to-point call, penalised
   against ground already walked (§5.1), plus the fix-ups below.
4. **Bounded per-leg retries** (`attemptLeg`, `DEFAULT_MAX_LEG_ATTEMPTS = 2`) —
   a leg overshooting its planned length by more than 1.4×, or backtracking
   onto the previous leg, is re-aimed shorter (×0.8) and further round (+20°).
5. **Join pullback** (`applyJoinPullback`) — where two legs meet at a turn
   sharper than 150°, both are undone and re-routed to a corner pulled 65% back
   toward the start. The fix for a corner in a cul-de-sac.
6. **In-leg spike reroute** (`findLegSpike`) — a short dead-end duck-in-and-back
   inside one leg is circled with a small avoidance disc and re-routed.
7. **Post-build trimming** (`joinAndTrimLegs` → `trimTinySpikes`) — any
   remaining backtrack under an 80 m round trip is spliced out of the finished
   geometry, bounded at `MAX_TOTAL_TRIM_METRES = 300`.
8. **`preAvoidGeometries`** — the builder can be seeded with ground to treat as
   already walked, which is how a local repair hands back the stretch a
   previous attempt doubled over.

### 5.1 What the fix-ups cost, and which earn it **(measured)**

The three speculative reroutes are **~43% of every engine call** — consistently,
at every start point sampled. Live keep rates:

| fix-up | attempted | kept | calls each |
|---|---|---|---|
| `join-pullback` | 337 | **69%** | 2 |
| `leg-budget` | 296 | **65%** | 1 |
| `spike` | 83 | **60%** | 1 |

All three earn their calls most of the time; total waste is ~12%. Two gates
trim the wasteful end, both on by default:

- **`LOOPER_PULLBACK_TURN_ONLY`** — a short branch straddling a leg seam is
  already spliced out for free by the tiny-spike trim, which reaches further
  (80 m) than the detector that triggers the pullback (~40 m). Spending two
  engine calls to route around something already removed buys nothing.
  **−6.4% calls**, identical walks, better separation.
- **`LOOPER_BUDGET_DETOUR_GATE`** — a leg only shortens under a weaker penalty
  if the penalty is what made it long. One running under `BUDGET_DETOUR_RATIO`
  (2×) its straight-line distance did not go round anything. **−1.8% calls**,
  and it raises the fix-up's own keep rate.

### 5.2 Anti-retrace: avoidance areas, not a global no-repeat constraint

`loops/avoidance.ts`:

- Every routed leg is buffered into a 25 m half-width corridor
  (`CORRIDOR_HALF_WIDTH_METRES`) with Turf; a 75 m circle round the start is
  cut out.
- Sent as a custom model: edges inside a corridor get `multiply_by: 0.05` —
  roughly a 20× cost penalty, **not** a block. A relaxed retry uses 0.2×.
- Soft and incremental by design: GraphHopper will still reuse penalised ground
  when nothing else is near the target length, which is intentional (a single
  bridge can be the only way through).
- **Merging is an optimisation that may fail.** `@turf/union` throws on
  degenerate geometry — a walk doubling back along exactly the same line — and
  that exception used to escape and fail the *whole request* with a 500 rather
  than losing one candidate. Union and difference are now both fail-open: where
  corridors cannot be merged they are sent separately, and where the doorstep
  circle cannot be cut out it is not cut out.
- `shortestPathCustomModel()` asks for the shortest route rather than the
  preferred one, via `distance_influence: 2000`. Used only where a genuine
  distance floor is needed (§8.2).

## 6. Quality scoring and hard rejection gate

`loops/quality.ts` — every candidate is measured from its own geometry;
GraphHopper's instructions are a secondary signal for U-turns only.

**Hard rejections** (any one refuses the candidate) — unchanged from before this
work:

| Check | Threshold |
|---|---|
| Distance error | > 12% of target |
| Duration error | > 15% of target (time mode) |
| Repeated corridor | > 12% of distance retraced |
| Short backtrack | any reverse run under 500 m that isn't a real feature |
| U-turns | > 1 |
| Leg balance | middle leg > 45% or < 8% (3+ leg shapes) |
| Bounding-box elongation | ratio > 4.5 |
| Compactness | isoperimetric < 0.20 |
| Start stub | > max(150 m, 4% of distance) and < 500 m |
| Doesn't return to start | > 40 m gap |

Weighted score (ranking only, 0–100): overlap 35%, closeness 25%, shape 20%,
balance 10%, simplicity 10%.

### 6.1 Overlap is measured on the network, not by proximity

`loops/edges.ts`. The geometric measure asks whether two stretches pass within
17.5 m running roughly parallel — a street's width, so it cannot tell a pavement
from the one opposite, a back lane from the road it runs behind, or a towpath
from the road above it.

With `edge_id` details, the question stops being geometric: two routes share
ground if and only if they walked the same edges, length-weighted. Used for
internal retrace, route-to-route similarity, and locating the longest repeated
section. Geometry remains the truth for shape, spikes, bounding boxes,
compactness, avoidance corridors and rendering — and remains the per-route
fallback wherever edge ids are missing. `QualityReport.overlapSource` says which
was used, and `RequestMetrics` counts both.

On by default (`LOOPER_EDGE_OVERLAP`).

## 7. Choosing what to offer

`loops/diversity.ts` — `selectDiverseRoutes(candidates, limit = 3, maxShared = 0.55)`:

- Ranked by quality score, two-pass greedy: pass 1 requires a different 45°
  compass octant *and* ≤ 55% shared ground; pass 2 drops the octant rule.
- `selectPreferredDiverseRoutes` exposes pass 1 alone — the same code path, not
  a second implementation of the rule.
- `sharedFraction(a, b)` uses edges where both routes have them and geometry
  otherwise; `mutualSharedFraction` takes the worse of both directions, because
  containment is not symmetric.
- Labels are compass names, disambiguated by length when two picks share an
  octant.

## 8. Orchestration

`generateLoops(request, options)`:

1. Seeded attempts (§4), spread across the compass, run through a bounded
   worker pool (`mapWithConcurrency`, concurrency 6).
2. **Early stop** — dispatch stops once `EARLY_STOP_PASSING_COUNT = 5`
   candidates have passed. Already-dispatched attempts finish; nothing is
   cancelled mid-flight and no permit is leaked.
3. If fewer than 3 pass, exactly **one** re-aim retry: rescale from observed
   pace (time mode) or from the median distance actually returned. The target a
   walk is *judged* against never moves.
4. Up to `MAX_DISCOVERY_BATCHES = 3` further fresh-bearing batches if diversity
   still cannot fill three offers.
5. If nothing passes but something passes the three *essential* checks
   (distance, duration, closure), a walk that doubles back is offered with
   `RETRACES_WARNING` — never mixed alongside a clean loop.
6. Otherwise empty + `NO_CLEAN_LOOP_WARNING`.

### 8.1 Waypoint mode, rebuilt around a backbone

`generateBackboneWaypointLoops()` (`LOOPER_WAYPOINT_BACKBONE`, on by default),
with `loops/waypoints.ts` doing the maths. The problem is treated as a length
problem rather than a shape problem:

```
anchors   a0 = start, a1…am = the walker's pins, a(m+1) = start
backbone  B = Σ routeCost(ai, a(i+1))     the walk you cannot avoid
slack     Δ = K − B                        what there is to spend
```

1. **One direct route per gap.** These are both the backbone and the "spend
   nothing here" option, so nothing is paid for twice.
2. **A doorstep pin is handed back.** If `B < 10%` of the target
   (`PIN_CONSTRAINT_SHARE`) the pins constrain nothing and the ordinary loop
   generator does a better job; the older path takes over.
3. **Feasibility** (§8.2) before any refusal.
4. **Per-gap alternatives** — `DETOUR_SHARES = [0, 0.35, 0.7, 1.2, 2]` of that
   gap's share of the slack, each on both sides, placed by
   `guideForDetour(...)` as an isoceles detour over the gap and **corrected for
   the network stretch measured on that gap's own direct route** (a crow-flight
   detour comes back longer than asked, by the local stretch).
5. **Slack allocation** — a bucketed dynamic programme (`allocateSlack`) picks
   one option per gap. Bounded by the table rather than the gap count:
   `bucketMetres` 2% of target, `maxBuckets` 96, `keepPerState` 3.
   `BACKBONE_ASSEMBLY_LIMIT = 24` combinations are assembled and measured.
6. **Shape is a bar to clear, not a ranking.** Each combination is scored on
   the crow-flight ring its anchors and guides describe (`ringShapeOf`), and the
   whole ranked set is ordered in tiers — right length *and* encloses ground,
   encloses ground, right length, neither. Plans enclosing nothing are kept
   last rather than discarded, so a pin down a single lane still gets an honest
   there-and-back.
7. **Assembled walks are joined *and trimmed*** (`joinAndTrimLegs`) and then
   face every ordinary gate except leg balance, which a pin makes meaningless.
8. **Separation falls back once, and stops** — 55%, then
   `WAYPOINT_RELAXED_SHARED = 0.8`. Pins force shared ground; three walks that
   are 95% the same walk are one walk with two extra taps to dismiss.

**Guide points may move; pins may not.** `LOOPER_GUIDE_POINT_PULLBACK` (off,
§11) applies the ring builder's own corner repair at a guide that landed in a
cul-de-sac. Nothing anywhere moves a coordinate the walker chose, and the tests
assert every pin reaches the engine exactly as given rather than assuming it.

**Diagnostics.** Waypoint mode has eight ways of giving up and they all reach
the walker as the same sentence, so `Diagnostics` carries `stage`
(`unreachable`, `over-plan`, `doorstep-pin`, `no-allocation`, `all-rejected`,
`backbone`, `reused-natural`, `legacy-guides`, `legacy-empty`), the rejection
tally, and — when the backbone hands over to the older generator —
`backboneStage`, `backboneRejections` and `backboneShapes`, so the newer code's
failure is not lost behind the older one's outcome.

`generateWaypointLoops()` remains as the fallback: reuse an ordinary loop that
already passes the pins, else pin-only, else one global guide point.

### 8.2 Feasibility needs a real floor

The profile's preferred route is not a lower bound (§3), so refusing on it can
refuse a walk that is actually walkable. The floor is therefore established
properly — with `shortestPathCustomModel()` — **only when the ordinary routes
already look too long**, which keeps the extra calls off every request that was
never going to be refused. `fitsInPlan(backbone, target, maxError, tolerance)`
allows `FEASIBILITY_TOLERANCE = 5%` for snapping, and the doubt goes the
walker's way.

## 9. Optional: network-aware seeding

`loops/network.ts` (`LOOPER_NETWORK_AWARE_SEEDS`, off). One `GET /spt` probe
summarises reach and network stretch per 30° sector, and candidate bearings
with real network behind them are dispatched first. Deliberately a *reordering*
and never a cull — a quarter of the unpromising bearings are still tried,
because one probe at one budget does not get to veto a direction.

Worth −13% on a seafront start and −11% on a promenade, and one extra call
everywhere else, netting −0.5% across the fixture mix. Worth switching on for a
coastal region and measuring there.

## 10. Concurrency, load control and telemetry

- **Per-request concurrency** (`ROUTING_CONCURRENCY`, 6) — see §3.1 for why it
  is not higher.
- **Global ceiling** (`src/concurrencyLimiter.ts`,
  `GRAPHHOPPER_MAX_CONCURRENCY` 24 / `GRAPHHOPPER_MAX_QUEUE` 100) — a semaphore
  shared across every request. Beyond the limit, calls queue; beyond the queue,
  they are refused. Proven by test not to leak a permit when work throws, when
  a waiter aborts, when the queue is full, or across a 200-request burst mixing
  all three.
- `LimiterBusyError` maps onto the existing 503 path; no new client-facing
  error shape.
- Per-IP rate limit, 20/minute (`src/http/rateLimit.ts`).
- One `AbortController` per request ties a 25 s deadline to client-disconnect;
  every engine call and queued wait observes it.
- **`loops/metrics.ts`** records, per request: engine calls by purpose (`leg`,
  `leg-relaxed`, `leg-budget`, `spike`, `join-pullback`, `waypoint-direct`,
  `waypoint-leg`, `repair`, `network-summary`, `screen`), routed legs (which is
  *not* the same as HTTP calls), engine ms bucketed by avoidance-polygon count,
  fix-up attempted-vs-kept, candidate and rejection counts, early-stop reason,
  overlap source, and offered-route quality. No coordinate reaches it, so it is
  logged in production as `cost`.

## 11. Feature flags

Every significant algorithm change has its own switch (`loops/flags.ts`, env
names in `.env.example`), and each arrived off. Two unproven changes enabled
together produce a regression nobody can attribute.

**On:**

| flag | why |
|---|---|
| `edgeOverlap` | the only measure that can tell a back lane from the road behind it |
| `spreadCandidateBearings` | −13.8% calls, better separation |
| `pullbackTurnOnly` | −6.4% calls, identical walks |
| `budgetDetourGate` | −1.8% calls, better fix-up keep rate |
| `waypointBackbone` | −85% calls on waypoint requests; hits the target ~4× closer |
| `progressiveCornerSweep` | −8.7% calls offline, **−15.2% on production**, identical walks |
| `diversityAwareEarlyStop` | +11.7% on its own; **−8.3% more** on top of the sweep, and the only thing that helps the worst case (Peel, −16.4%) |

**Off, with the evidence:**

| flag | measurement |
|---|---|
| `guidePointPullback` | −35% calls and eliminates U-turn rejections, but one fixture drops 3 walks → 1. A product trade; see §12 |
| `keepPinnedSpurs` | correct in isolation and it costs the walker every waypoint walk: production went 2–3 routes → **0**, `out-and-back-spur` refusing 20 of 24. Needs a structural-spur exemption in the gate first |
| `narrowCornerSweep` | −26% calls, costs ~1 walk in 20 and some separation |
| `networkAwareSeeds` | −13% coastal, +1 call elsewhere, −0.5% net |
| `localRepair` | 4 in 5 repairs succeed for +1.7% calls, and the *offered* walks get no better |
| `paretoArchive` | correct and harmless; candidate pools too small for a front to bind |
| `twoStageScreening` | HTTP calls flat, **path searches +37%** — one request for a whole ring saves round trips, not the engine's work |
| `requestCache` | correct by construction; deliberately not enabled |

## 12. Measurement

Two tools, and they disagree in ways worth knowing about.

- **`npm run bench`** (`bench/`) — 20 deterministic scenarios over five
  synthetic pedestrian networks with real nodes, edges and Dijkstra, emitting
  GraphHopper-shaped JSON parsed by the service's own `parseLeg`. Supports
  `--flags`, `--compare`, `--save`, `--concurrency`. Call counts and route
  quality are exact and machine-independent; wall clock is not.
- **`bench/probe-production.sh`** — a handful of ordinary route requests
  against the live service, printing ms/call, parallelism, fix-up keep rates,
  polygon-cost buckets and the waypoint stage.

**The benchmark has been wrong about real behaviour three times.** Its engine
originally snapped to junctions, where GraphHopper snaps to the middle of an
edge — and that single difference is what creates the dead-end joins the
fix-ups exist to repair. The fixtures showed 3.2% of calls on join pullbacks
and no spikes at all; production showed 25–29% and 2–4%. It now snaps to edges
and reproduces the real profile (24.3%), but the lesson stands: **prefer the
probe.**

## 13. What this system deliberately does *not* do

- No Contraction Hierarchies (§3) — a considered tradeoff.
- No global whole-route optimisation. No genetic algorithms, annealing, ILP or
  orienteering solvers. Greedy construction with bounded local repair.
- No use of GraphHopper's round-trip or alternative-route algorithms.
- No point-of-interest or scenic scoring. Geometry-only quality is the sole
  shaping signal beyond distance, waypoints and exclusions.
- **No caching.** `loops/cache.ts` exists, is complete and tested — bounded
  LRU, TTL, keyed on graph version, region, profile, profile version, algorithm
  flags, generation settings and every request field at full coordinate
  precision — and is **switched off by product decision**, not by oversight.
- No horizontal GraphHopper scaling — one JVM per region.
- No structural-retrace allowance. See `chokepoints-spike.md`: the signal is
  already available for free (a leg that came back `relaxed`, or whose spike
  reroute failed, has demonstrated there is no way round), but relaxing the
  retrace gate is the riskiest change available and the only fixtures are ones
  whose chokepoints we placed ourselves.

## 14. Known open items

- **Suburban waypoint pins still fail** — `out-and-back-spur` 23 of 24 on the
  fixture. Cul-de-sac ground puts guide points down dead ends longer than the
  80 m trim budget. `guidePointPullback` addresses it but trades route count;
  needs a real-ground A/B.
- **Waypoint requests offer 1–2 walks, not 3**, on the live engine. Fixed from
  "returns nothing", not finished.
- **Standard loops are now ~1.4 s** for a 5 km Douglas request, and Peel — the
  worst ground measured — went from 10.6 s to **1.8 s**. Almost none of that
  came from the call count, which barely moved: it came from finding that the
  engine was never the constraint. GraphHopper answers 793 calls a second at
  this concurrency, a leg costs it ~5 ms and 190 nodes, and the service was
  getting 90 a second because it spent up to 85 ms of its own single-threaded
  CPU building anti-retrace corridors before each call. See the Phase 9 report.
  The remaining ~11-16 ms a call, against an engine floor near 5 ms, is what is
  left to chase.
- **415 and 162 were never the same measurement**, and the gap is not a
  discrepancy to reconcile. 415 is a production Douglas probe; 162 is the
  synthetic straight-line fixture in `test/generate.test.ts`, on different
  ground with `DEFAULT_ATTEMPT_COUNT = 16` rather than production's 24. The
  candidate count is not the difference either: `urban-5km-production-width`
  raises the cap to 24 and costs **exactly** what `urban-5km` costs, because
  the early stop fires long before the cap binds. The difference is the ground.
- **A pin can still be trimmed out of the walk it was routed through.**
  `keepPinnedSpurs` fixes that and costs every waypoint walk on real ground,
  because the spur it preserves is what `out-and-back-spur` refuses — see the
  Phase 8 addendum. The gate needs to tell a spur held open by a pin from one
  the walk fell into; until then the trim keeps precedence, and the walker gets
  a walk whose last few metres are drawn generously rather than no walk.
- **Neither waypoint correctness fix shows on the synthetic bench.** The
  duration-mode re-aim is exactly neutral across all 21 scenarios, because the
  synthetic networks walk at almost exactly the assumed pace; the pin work was
  neutral there too, and production overturned it. Waypoint changes want the
  probe, not the bench.
- **Peel still costs the most calls**, at 810 for 1.8 s. It passes only 4
  candidates in 24, so it is the case both stopping rules serve worst, and
  fix-ups are a quarter of its calls (`join-pullback` alone 206). Worth
  revisiting only if calls start mattering again: at ~11 ms each they no longer
  dominate the way they did.
- **A Douglas 3 km costs 207 calls where it cost 150**, from the corridor shapes
  changing in Phase 9 — smaller corridors steer less hard, so more candidates
  are built. Unexplained rather than understood, and the only figure in the
  probe set that moved the wrong way. Everything else is within a few per cent.
- `GRAPHHOPPER_MAX_CONCURRENCY` / `GRAPHHOPPER_MAX_QUEUE` remain untuned
  against a load test.
- Horizontal GraphHopper replicas + a service-level admission queue.

## Appendix: key files

| File | Role |
|---|---|
| `src/server.ts` | HTTP surface, request lifecycle, abort/deadline, limiter and cache wiring |
| `src/config.ts` | All tunable knobs and flag defaults, env-configurable |
| `src/graphhopper.ts` | GraphHopper client: `/route`, `/spt`, response and path-detail parsing |
| `src/regions.ts` | Region bounds → which engine serves a start point |
| `src/concurrencyLimiter.ts` | Global cross-request ceiling on the engine |
| `src/loops/generate.ts` | Orchestration: batching, retries, early stop, both waypoint generators |
| `src/loops/candidates.ts` | Seeded bearing/direction sampling and compass spreading |
| `src/loops/routing.ts` | Incremental leg-by-leg construction, fix-ups, join/spike repair, trimming |
| `src/loops/waypoints.ts` | Backbone, per-gap alternatives, slack DP, ring shape, feasibility |
| `src/loops/avoidance.ts` | Walked ground → custom model; fail-open merging; shortest-path model |
| `src/loops/quality.ts` | Geometry-derived scoring and the hard gates |
| `src/loops/edges.ts` | Length-weighted overlap on network edges |
| `src/loops/diversity.ts` | Final 3-of-N selection |
| `src/loops/flags.ts` | Algorithm switches and their shipped defaults |
| `src/loops/metrics.ts` | Per-request cost telemetry, coordinate-free |
| `src/loops/network.ts` | Reachability probe and bearing bias (off) |
| `src/loops/repair.ts`, `pareto.ts`, `screening.ts`, `cache.ts` | Implemented, tested, off |
| `bench/` | Synthetic networks, scenarios, runner, production probe |
| `graphhopper/config.yml`, `graphhopper/looper_foot.json` | Engine configuration and custom walking profile |

## Related documents

- `routing-baseline.md` — the Phase 0 audit: control flow, call-count ceilings,
  and why the profile's route is not a distance lower bound.
- `routing-report.md` — phase-by-phase implementation report, including the
  addenda recording what production said and which conclusions it overturned.
- `chokepoints-spike.md` — structural vs avoidable retracing: design and
  benchmark plan, deliberately not implemented.
