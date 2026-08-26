# Looper route-service: routing system breakdown

Prepared as a technical reference for external AI analysis. Covers the loop-routing service at `route-service/` in the Walkabout repo as of commit `e1702d6` on `main`. All file paths are relative to `route-service/`.

## 1. What this system does

Given a start point and a target walking distance or duration (optionally with an ordered list of must-visit waypoints), the service returns up to 3 distinct walking **loops** (start = end) that satisfy the target and read as a sensible walk on a map — not a scribble, not a there-and-back, not three readings of the same streets.

It is **not** a shortest-path service and does not expose GraphHopper's own round-trip algorithm. It builds loops itself, on top of an ordinary point-to-point pathfinder, because the pathfinder alone has no concept of "come back a different way" or "look like a nice walk."

## 2. High-level architecture

```
Client (PWA / iOS app)
  │  POST /v1/loops { start, distanceKm|durationMinutes, waypoints?, exclude?, ... }
  ▼
route-service (Node/TypeScript, src/server.ts)
  │  parses & validates request, per-IP rate limit, per-request AbortController/deadline
  ▼
loops/generate.ts  — generateLoops() / generateWaypointLoops()   [ORCHESTRATOR]
  │  fans out many independent "attempts" (candidate loops)
  ▼
loops/routing.ts   — buildLoopIncrementally()                    [LOOP BUILDER]
  │  builds one candidate loop leg-by-leg
  ▼
loops/avoidance.ts — buildAvoidanceAreas(), avoidanceCustomModel()
  │  turns already-walked ground into a GraphHopper "avoid" custom model
  ▼
GraphHopperClient (src/graphhopper.ts)  →  HTTP POST /route
  ▼
Self-hosted GraphHopper 11.0 (route-service/graphhopper/), one JVM per region
  (Isle of Man, England — see src/regions.ts), pedestrian profile "foot"
```

Every candidate loop, once built, is scored and gated by `loops/quality.ts`, and the survivors are picked for diversity by `loops/diversity.ts` before being returned.

## 3. The underlying pathfinder: GraphHopper, configured deliberately without CH

- GraphHopper 11.0, self-hosted (`graphhopper/Dockerfile`, `graphhopper/config.yml`), one instance per geographic region, each with its own OSM extract and heap (2 GB Isle of Man, 6 GB England — `docker-compose.prod.yml`).
- Single profile `foot`, defined by a **custom model** (`graphhopper/looper_foot.json`) that replaces GraphHopper's stock `foot.json`: it zeroes out inaccessible/dangerous edges (no foot access, hike_rating ≥ 2, certain bridleways, etc.) but deliberately **does not** apply GraphHopper's stock road-class preference. Rationale (from the file's own comment): a loop generator aiming in many directions needs "one residential street is as good as another," whereas the stock weighting funnels everything onto the same well-tagged arterials regardless of the bearing the generator wants.
- **Contraction Hierarchies (CH) is explicitly disabled** (`profiles_ch: []` in `config.yml`). CH bakes one fixed weighting into the graph at import time and cannot accept a different custom model per request — and Looper's per-request "avoid this corridor" areas (see §5) are exactly that: a different weighting on every single call.
- **Landmarks (LM)** is enabled instead (`profiles_lm: [{ profile: foot }]`) as the speed compromise: LM stays mathematically valid as long as a request only ever *raises* edge cost (never lowers it), which is all Looper's avoidance areas ever do. This is a deliberate, already-reasoned tradeoff, not an oversight.
- Every request also sets `'ch.disable': true` explicitly (`src/graphhopper.ts:57`) and GraphHopper is asked for ordinary **point-to-point** routes only — one call per leg, never GraphHopper's own round-trip mode.
- **So: the actual shortest-path search per leg is GraphHopper's Landmark-accelerated bidirectional A\*/Dijkstra variant, not Looper's own code.** Looper only decides *where* the two endpoints of each leg are.

## 4. Candidate generation: deterministic multi-start sampling

`loops/candidates.ts` — `generateLoopAttempts(seed, count)`:
- Produces `count` (default 24, configurable per-request, see §8) **deterministic** starting bearings, spread evenly around the compass (360°/pairs) with a small random jitter (±12°) so repeated requests don't look stencilled.
- A seeded PRNG (`mulberry32`, in `loops/random.ts`) is used — the seed is derived from the start coordinate + target distance + a `variation` field the client can bump for "show me different ones" (`seedFor()`, referenced in `generate.ts`). Same request → same loops; a `variation` increment → a different, still-deterministic set.
- Attempts come in **mirrored pairs**: the same bearing tried both clockwise and counter-clockwise, because "the same three streets can make a good loop one way and an awkward one the other" (one-way paths, stairs, crossings the generator can't see from a graph query alone).
- This is the *only* randomness in the system, and it's fully seeded/reproducible — not stochastic search in the metaheuristic sense.

## 5. Building one candidate loop: incremental, self-correcting construction

`loops/routing.ts` — `buildLoopIncrementally(start, targetMetres, initialBearing, direction, route, options)`. This is the core "algorithm," and it is best described as **greedy incremental construction with bounded local retries and geometric post-repair** — not a global optimizer, not classic Dijkstra/A* (that's delegated to GraphHopper per leg).

Per candidate:
1. **Corner count**: tries shapes with 1, 2, 3, then 4 corners (`CORNER_COUNTS_TO_TRY` in `generate.ts`), simplest first, stopping as soon as one produces a passing loop. A promenade might only need 2 legs; a housing estate might need 5.
2. **Leg-by-leg construction**: for a loop with `cornerCount` corners, there are `cornerCount + 1` legs. Before each leg, the code computes remaining distance budget ÷ legs left, and aims the next leg's target point that far away, on a heading stepped evenly round the compass (turning the requested `direction`). This is *live* planning — the shape is not decided up front.
3. **Per-leg routing** (`routeLegAttempt`): each leg is one GraphHopper point-to-point call, penalized against ground already walked (§5.1 below). If it fails outright, or blows its share of the distance budget, or contains a short dead-end spike, it gets **one bounded retry** with a relaxed penalty / shorter reach / different bearing — never a full restart.
4. **Bounded per-leg retries** (`attemptLeg`, up to `DEFAULT_MAX_LEG_ATTEMPTS = 2`): if a leg overshoots its planned length by more than `DEFAULT_LEG_OVERSHOOT_TOLERANCE` (1.4×), or backtracks briefly onto the previous leg, the next attempt aims a shorter reach (×0.8 per retry) and swings the bearing further round (+20°/retry) — a genuinely different guess, not the same request repeated.
5. **Join pullback** (`applyJoinPullback`): after two legs meet, if the turn there is sharper than `JOIN_TURN_THRESHOLD_DEGREES` (150°) or a short branch straddles the seam, both the arriving and departing leg are undone and re-routed to a point pulled back 65% of the way toward the start (`WAYPOINT_PULLBACK_SCALE`) — the fix for a waypoint or corner landing in a cul-de-sac.
6. **In-leg spike detection & reroute** (`findLegSpike`): detects a short dead-end/driveway duck-in-and-back inside a single leg's own geometry (sharp reversal whose two ends land within ~20 m of each other) and asks GraphHopper to route around it with a small avoidance disc.
7. **Post-build spike trimming** (`trimTinySpikes`): after the whole loop is joined, any remaining backtrack shorter than `TINY_SPIKE_ROUND_TRIP_METRES` (80 m) is spliced straight out of the final geometry — a last-resort honest cleanup for ground that genuinely offers no other way through, bounded so a fundamentally out-and-back walk isn't gutted (`MAX_TOTAL_TRIM_METRES = 300`).

### 5.1 Anti-retrace: avoidance areas, not a global no-repeat constraint

`loops/avoidance.ts`:
- Every leg already routed is buffered into a 25 m-half-width polygon corridor (`CORRIDOR_HALF_WIDTH_METRES`) using Turf.js (`@turf/buffer`, `union`, `difference`, `simplify`).
- A 75 m circle around the start is always cut out (the shared doorstep every loop has is not "retracing").
- These corridors are sent to GraphHopper as a **custom model** (`avoidanceCustomModel`): any edge inside a corridor gets `multiply_by: 0.05` on its priority — GraphHopper folds priority into the weight denominator, so this is roughly a **20× cost penalty**, not a hard block. A relaxed retry uses 0.2× (5× penalty) if the strong penalty leaves a leg unroutable or absurdly long.
- Practically: this is a **soft, per-request, incrementally-updated weighting** rather than a graph-level constraint — GraphHopper will still cross or reuse penalized ground if nothing else is close to the target length, which is intentional (a single bridge can be the only way through).
- Capped at 12 areas per request (`MAX_AVOIDANCE_AREAS`) — the largest corridors by area are kept, to bound request size.

## 6. Quality scoring and hard rejection gate

`loops/quality.ts` — every finished candidate is measured **from its raw geometry**, not trusted from GraphHopper's own turn-by-turn instructions (those are used only as a secondary signal for U-turns).

**Hard rejection thresholds** (`analyseRouteQuality` — any one failure rejects the whole candidate):
| Check | Threshold | What it catches |
|---|---|---|
| Distance error | > 12% of target | Wrong length |
| Duration error | > 15% of target (time mode) | Wrong time |
| Repeated corridor | > 12% of distance is retraced ground | A walk that scribbles through the same few blocks |
| Short backtrack | any backtrack under 500 m that isn't a "real feature" | A corner that turned out to be a dead end |
| U-turns | > 1 | Geometric turn-arounds (≥150° swing, arms within 20 m) |
| Leg balance | any middle leg > 45% or < 8% of total (3+ leg shapes only) | One trudge and three corners, or a collapsed spoke |
| Bounding-box elongation | ratio > 4.5 | A long thin corridor rather than an enclosing loop |
| Compactness | isoperimetric compactness < 0.20 | "Hits the distance, never repeats a street, still reads as a scribble on a map" |
| Start stub | out-and-back stub at the door > max(150 m, 4% of distance), and < 500 m | A there-and-back with a loop stuck on the end |
| Doesn't return to start | > 40 m gap between first/last point | Not a loop at all |

A backtrack ≥ 500 m is *excused* from several of these checks — long enough to only be a real feature (a pier, a headland, a promenade with one road in), not an accident, and the whole walk is then judged as the legitimate there-and-back it is.

**Weighted quality score** (0–100, used for ranking, not gating) — `SCORE_WEIGHTS`:
- Overlap avoidance: **35%**
- Distance/duration closeness: **25%**
- Shape (isoperimetric compactness): **20%**
- Leg balance: **10%**
- Simplicity (fewer U-turns): **10%**

This weighting is explicitly stated as "the way a walker would weigh it": not retracing matters most, then hitting the requested length, then whether it feels like a loop, then balance, then how fiddly it is to follow.

## 7. Choosing what to offer: diversity selection

`loops/diversity.ts` — `selectDiverseRoutes(candidates, limit=3, maxShared=0.55)`:
- Candidates ranked by quality score.
- Two-pass greedy selection: pass 1 requires each pick to leave via a different 45° compass octant (`bearingOctant`) *and* share ≤ 55% ground with anything already chosen; pass 2 drops the octant requirement (some towns have a genuine bottleneck — a single bridge/headland — where every clean loop leaves the same way).
- Labels (`labelRoutes`) are compass-direction names ("North loop"), disambiguated by length ("Shorter east loop"/"Longer east loop") when two picks share an octant.

## 8. Orchestration: batching, retries, and the recent early-stop optimization

`loops/generate.ts` — `generateLoops(request, options)`:
1. Builds a seeded set of attempts (`candidateCount`, default 24 — `src/config.ts`) via §4, and runs them through a bounded worker pool (`mapWithConcurrency`, concurrency default 6 — capped because "twenty-four at once is more load than a small routing container should take").
2. **Early-stop (added 2026-08-26):** `mapWithConcurrency` now accepts a `shouldStop()` callback; `attempt()` passes one that trips once **5 passing candidates** have already been found, so unclaimed attempts in the batch are never dispatched. (Already-dispatched attempts — up to `concurrency` of them — finish naturally; this is a *bounded* trim of the tail, not mid-flight cancellation.) Measured on the test fixture: cut total GraphHopper calls from 648 to 162 (~75%) for the same 3 offered routes.
3. If under 3 loops pass, exactly **one** re-aim retry is allowed:
   - Time mode, duration-only misses: rescale the distance target from the *observed* pace on this terrain, and try one more batch.
   - Otherwise: rescale the construction target from the median distance actually returned (the street network stretched a crow-flies target more/less than expected), retry once — but the walker's original ask (`qualityTarget`) is what candidates are still judged against, never silently moved.
4. If diversity selection still can't fill 3 offers, up to `MAX_DISCOVERY_BATCHES` (3) additional fresh bearing batches are sampled (`variation + batch`).
5. If literally nothing passes, but at least one candidate passes the three *essential* checks (distance, duration, closes the loop — never the shape checks), Looper offers a walk that doubles back rather than nothing, with an explicit warning (`RETRACES_WARNING`) — never mixed in alongside clean loops.
6. If nothing passes even the essentials: empty result + `NO_CLEAN_LOOP_WARNING`.

### Waypoint mode
`generateWaypointLoops()` (same file): when the client supplies ordered must-visit waypoints:
1. Routes the waypoints directly (no avoidance) as a sanity floor — if that alone exceeds 125% of the target, refuses immediately with a clear "increase your plan or remove a waypoint" message rather than forcing a bad answer.
2. First tries to reuse an *ordinary* generated loop (§8 above, ignoring waypoints) that happens to already pass through the pins in the right order — cheaper and less likely to manufacture a needless spur than rebuilding around a point already on the loop.
3. Otherwise routes the pins with avoidance-on-return-legs, then inserts **one invisible "guide point"** per alternative to shape any spare distance into a loop without moving a pin the walker placed. The guide's distance from the start is chosen by sampling 48 radii (`WAYPOINT_GUIDE_RADIUS_SAMPLES`) against 6 scale factors, picking whichever gets closest to the target crow-flight perimeter (deliberately a sampled search, not binary search — the objective isn't monotonic when a bearing points between two waypoints, so binary search can converge on the wrong side of the minimum).

## 9. Concurrency and load control (also added 2026-08-26)

Two independent layers, addressing two different scaling problems:
- **Per-request concurrency** (`config.concurrency`, default 6): bounds how many legs *one* request routes in parallel — protects one request from over-fanning-out internally.
- **Global concurrency ceiling** (`src/concurrencyLimiter.ts`, new): a semaphore shared across **every** request hitting a given region's GraphHopper instance, not just one request's own fan-out. Configurable via `GRAPHHOPPER_MAX_CONCURRENCY` (default 24) / `GRAPHHOPPER_MAX_QUEUE` (default 100). Beyond the concurrency limit, calls queue; beyond the queue limit, they're refused immediately (`LimiterBusyError`) rather than left to pile up — this is what actually protects the single small GraphHopper JVM (2–6 GB heap, no horizontal replicas today) from hundreds of simultaneous walkers.
- `LimiterBusyError` is translated into the existing `GraphHopperError(kind: 'timeout')` → the existing 503 "route service is busy" response path, so no new client-facing error shape was introduced.
- Separately, a per-IP fixed-window rate limiter (`src/http/rateLimit.ts`, default 20 requests/minute) exists at the HTTP layer — this bounds *request rate per walker*, not total engine load across walkers, which is why the concurrency limiter above was still needed.
- A single `AbortController` per HTTP request (`src/server.ts`) ties together a hard deadline (`REQUEST_TIMEOUT_MS`, default 25 s) and client-disconnect detection; every GraphHopper call and every queued concurrency-limiter wait observes it, so a request that times out or whose client goes away stops consuming engine capacity promptly.

## 10. What this system deliberately does *not* do

- No Contraction Hierarchies (see §3) — a considered tradeoff for per-request custom avoidance models, not an oversight.
- No global/whole-route optimization (no genetic algorithms, simulated annealing, ILP, orienteering-problem solving) — loops are built greedily, leg by leg, with local repair only.
- No use of GraphHopper's built-in round-trip/alternative-route algorithms.
- No point-of-interest or "scenic" scoring — the only per-request criteria are distance/duration target, optional ordered waypoints, and previously-shown routes to exclude (`exclude`). Geometry-only quality (§6) is otherwise the sole shaping signal.
- No caching of GraphHopper responses or precomputed/offline route generation — every request is fully live.
- No horizontal scaling of the GraphHopper engine itself — one JVM per region; the global concurrency limiter (§9) manages load on that single process rather than distributing it.

## 11. Known open items (not yet implemented, discussed but deferred)

- Horizontal GraphHopper replicas + a service-level admission queue for real throughput scaling beyond what one JVM's concurrency ceiling can absorb.
- Offline precomputation/caching of loop sets for popular (start point × distance) combinations, to serve common requests near-zero-cost instead of fully live every time.
- A bounded "local repair" step for near-miss candidates (single-reason quality rejections) that perturbs bearing/corner-count and rescoring rather than falling straight through to a whole fresh discovery batch — sketched in `route-service/docs/routing-algorithms-research.md` but not built.
- `GRAPHHOPPER_MAX_CONCURRENCY`/`GRAPHHOPPER_MAX_QUEUE` defaults are untuned against real traffic or a load test.

## Appendix: key files

| File | Role |
|---|---|
| `src/server.ts` | HTTP surface, request lifecycle, abort/deadline, concurrency-limiter wiring |
| `src/config.ts` | All tunable knobs, env-configurable |
| `src/graphhopper.ts` | Thin GraphHopper HTTP client; request/response shape |
| `src/regions.ts` | Region bounds → which GraphHopper instance serves a start point |
| `src/loops/candidates.ts` | Deterministic seeded bearing/direction sampling |
| `src/loops/routing.ts` | Incremental leg-by-leg loop construction, retries, spike/join repair |
| `src/loops/avoidance.ts` | Walked-ground → GraphHopper avoidance custom model |
| `src/loops/quality.ts` | Geometry-derived scoring and hard rejection gate |
| `src/loops/diversity.ts` | Final 3-of-N selection for genuinely different offered routes |
| `src/loops/generate.ts` | Top-level orchestration: batching, retries, early-stop, waypoint mode |
| `src/concurrencyLimiter.ts` | Global cross-request concurrency ceiling on the GraphHopper engine |
| `graphhopper/config.yml`, `graphhopper/looper_foot.json` | GraphHopper engine configuration and custom walking profile |
