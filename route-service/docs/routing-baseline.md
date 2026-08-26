# Phase 0 — baseline audit, instrumentation, and benchmark fixtures

Recorded against `main` at the start of the loop-generation improvement work.
Companion to `routing-system-breakdown.md`, which describes the architecture;
this document records the things that had to be *measured or verified* before
any of it could safely be changed. Paths are relative to `route-service/`.

## 1. Where GraphHopper is actually asked

Every engine call in the service goes through `LegRouter`, which the server
supplies in `src/server.ts` and which reaches the engine through
`GraphHopperClient.route`. There is one HTTP call per invocation, always
`POST /route`, always two points, never a multi-point request and never
GraphHopper's own round-trip mode.

Each call now carries a `purpose` tag, which is metrics only — a router that
ignores it behaves exactly as before:

| purpose | where | when |
| --- | --- | --- |
| `leg` | `routeLegAttempt` | the ordinary leg of a candidate loop |
| `leg-relaxed` | `routeLegAttempt` | the leg was unroutable under the strong avoidance penalty |
| `leg-budget` | `routeLegAttempt` | the penalty made the leg absurdly long; reroute more cheaply |
| `spike` | `routeLegAttempt` | a short dead-end branch was found inside the leg's own path |
| `join-pullback` | `applyJoinPullback` | two legs met at a cul-de-sac; both are redone (2 calls) |
| `waypoint-direct` | `routeWaypointCandidate` | the unpenalised ordered-waypoint feasibility route |
| `waypoint-leg` | `routeWaypointCandidate` | a leg of a waypoint candidate |

`repair`, `network-summary`, `screen` and `cache` counters exist and read zero
until the phases that introduce them.

## 2. How many calls one request can cost

Worst case, per **leg** (`routeLegAttempt`): 1 base + 1 relaxed + 1 budget +
1 spike = **4**.

Per **corner leg** (`attemptLeg`, `DEFAULT_MAX_LEG_ATTEMPTS = 2`, so three
attempts): **12**. The closing leg is never retried: **4**.

Per **candidate** at corner count *c*: `c` corner legs + 1 closing leg +
`c` join seams at 2 calls each = `12c + 4 + 2c`. `CORNER_COUNTS_TO_TRY` is
`[1,2,3,4]`, tried in order and abandoned as soon as one passes, so a candidate
that never passes costs the sum over all four: **156 calls**.

Per **batch**: `candidateCount` (24 in production, `DEFAULT_ATTEMPT_COUNT` 16
otherwise) × the above. Per **request**: up to 4 batches — the first, one
re-aim retry, and `MAX_DISCOVERY_BATCHES - 1` further discovery batches.

So the theoretical ceiling is roughly **15,000 calls**, and the only things
standing between that and production are the early stop and the fact that most
candidates pass at a low corner count. Measured on the benchmark, the worst
real scenario (`rural-3km-tight`) costs 1,291 and the median urban request 137.
The gap between 137 and 15,000 is the actual risk surface here.

Waypoint mode costs, separately: 1 `waypoint-direct` + a complete ordinary
`generateLoops` run + 1 pin-only candidate + up to 16 guided candidates, each
of `waypoints.length + 2` legs with the same per-leg fixups.

## 3. Early stop, as it stands

`mapWithConcurrency` takes a `shouldStop()` checked before each item is
*claimed*. `attempt()` trips it once `EARLY_STOP_PASSING_COUNT = 5` candidates
have passed. Attempts already dispatched — up to `concurrency` of them — finish
normally; nothing is cancelled mid-flight and no permit is held.

The five is a guess at a buffer above the three offered, because diversity
filtering can discard some. It does not consult the diversity selector, so it
can stop with five candidates that the selector will reject as three readings
of the same street, and it can keep going long after three genuinely different
loops are already in hand. That is Phase 1's problem.

## 4. Candidate rejection reasons

`analyseRouteQuality` returns machine-readable reasons, counted per request:
`distance`, `duration`, `repeated-corridor`, `out-and-back-spur`, `u-turns`,
`leg-too-long`, `leg-too-short`, `elongated`, `shapeless`, `start-spur`,
`open-ended`. The first three of these (`ESSENTIAL_REJECTIONS`: `distance`,
`duration`, `open-ended`) are the ones never waived; the rest can be set aside
when nothing clean exists at all, under `RETRACES_WARNING`.

## 5. How retrace and shared ground are measured today

Both are **geometric**, in `quality.ts`, and both work by resampling a route to
15 m samples in a local equirectangular frame and matching samples that are
within `CORRIDOR_MATCH_METRES` (17.5 m) of each other and within 35° of
parallel:

- `findRepeatedCorridors` — a route against itself, earlier ground only,
  ignoring the first and last 75 m, discarding matched runs under 37.5 m as
  junctions rather than corridors.
- `sharedCorridorMetres(a, b)` — one route against another, same machinery,
  used by the diversity selector and by the `exclude` filter.

**The known weakness:** 17.5 m of separation is a street's width. A pavement on
the opposite side of the same road, a parallel back lane, and a footpath beside
a carriageway are all counted as the same ground. So is a route crossing
another at a shallow angle for 40 m. This inflates both retrace and
alternative-to-alternative similarity, and the inflation is worst exactly where
it hurts most — dense urban grids, where parallel streets are close together
and where the generator should be finding the most choice. Addressed in Phase 1.

## 6. What is asked of GraphHopper, and what is not

`buildRouteBody` currently requests `details: ['street_name', 'road_class']`,
`points_encoded: false`, `instructions: true`, `elevation: false`,
`'ch.disable': true`, `snap_preventions: ['ferry']`.

**`edge_id` is not requested.** A comment in `graphhopper.ts` describes edge ids
as "a supporting signal for repeat detection"; that was aspirational and the
detail was never actually asked for or parsed. `edge_id` is a built-in
GraphHopper path detail requiring no encoded-value configuration, so it is
expected to work against the current `config.yml` unchanged — but that is a
reasonable expectation, not a verified fact, and Phase 1 must treat a missing
`edge_id` detail as an ordinary outcome with the geometry path as fallback.

**Isochrone / shortest-path-tree.** `graphhopper-web` 11.0 is the standard
open-source jar and is expected to serve `/isochrone` and `/spt`; neither is
disabled in `config.yml`. Again unverified without a running engine. Phase 3
must probe at runtime, time out, and fall back rather than assume.

## 7. Is the profile's route a valid lower bound? **No.**

This matters because waypoint mode currently uses the direct ordered-waypoint
route as a feasibility floor, and Phase 4 wants to build a mathematical
backbone on it.

`looper_foot.json` defines the profile entirely by `priority` and `speed`.
GraphHopper's custom weighting divides by priority, so an edge's weight is
proportional to `length / priority`. Every priority rule in the profile is a
multiplier **at or below 1**:

```
!foot_access || hike_rating >= 2                        -> 0    (impassable)
country == DEU && BRIDLEWAY && foot_road_access != YES  -> 0    (impassable)
mtb_rating > 3                                          -> 0.7
foot_road_access == PRIVATE                             -> 0.1
```

so wherever priority varies between two routes, the weight-minimal route is not
the distance-minimal one. A route through a `PRIVATE`-access path costs ten
times its length; the engine will happily return a physically longer way round.

**Consequence:** `direct.distanceMeters` is an *upper* bound on the true
shortest ordered-waypoint distance, not a lower bound. The existing 125%
feasibility check therefore over-estimates the minimum and can refuse a
waypoint set that is actually walkable within the plan. That is a fail-safe
direction for route quality and a fail-*unsafe* direction for refusals, and it
is a real defect, not a rounding concern.

The same argument applies to duration: priority does not affect travel time at
all, so a weight-minimal route is not time-minimal either.

Phase 4 must either compute the bound under a distance-only model or use a
deliberately conservative estimate. It must not treat today's direct route as
`B`.

## 8. Instrumentation added

`src/loops/metrics.ts` — `RequestMetrics`, a counter set with no coordinate in
it anywhere, so it is safe to log in production as it stands. Counted: engine
calls total and by purpose, engine time, candidates built/routed/passed/
rejected, rejection reasons, repairs, discovery batches, re-aims, early-stop
reason, fallback usage, cache hits and misses, per-candidate elapsed time
(median/p95/max), and — once the offered set is known — distance error, retrace
percentage, U-turn count and the worst pairwise shared ground between offered
routes.

Snapshots are order-independent: the same work in a different completion order
produces the same object, which is what makes a benchmark a baseline rather
than noise.

Wired in at `src/server.ts` (logged as `cost`), and available on
`diagnostics.metrics` for the tuning panel. The API contract already reserves
extra diagnostic fields for the service's own tools.

## 9. Benchmark fixtures

`bench/` — see `bench/README.md` for how to run it and, importantly, what its
numbers do and do not mean. Twenty deterministic scenarios over five synthetic
networks, covering dense urban, suburban, sparse rural, coastal, and
bridge-chokepoint ground; short and long loops; distance and duration mode; a
walker-supplied pace; refresh variation; exclusions; and no, one, two and three
ordered waypoints, including a pin beyond a chokepoint, a pin forcing a narrow
out-and-back, and a pin that is genuinely out of reach.

## 10. Baseline results

`bench/results/baseline.json`, produced by `npm run bench -- --save baseline`.
209 pre-existing tests passing, 225 after this phase's additions.

| scenario | routes | gh calls | dist err | retrace | pair shared |
| --- | --- | --- | --- | --- | --- |
| urban-5km | 3/3 | 137 | 4.4% | 0% | 28% |
| urban-2km-short | 3/3 | 100 | 1% | 0% | 28.8% |
| urban-12km-long | 3/3 | 68 | 2% | 0% | 28.3% |
| urban-time-60min | 3/3 | 137 | 4.4% | 0% | 28% |
| urban-time-paced | 3/3 | 137 | 4.4% | 0% | 28% |
| urban-variation-3 | 3/3 | 105 | 8% | 0% | 19.3% |
| suburban-5km | 3/3 | 93 | 5.1% | 0% | 24.8% |
| suburban-8km | 3/3 | 123 | 4% | 0% | 39.1% |
| rural-6km | 3/3 | 989 | 6.7% | 12.3% | 48.8% |
| rural-3km-tight | 2/3 | 1291 | 6.7% | 46.6% | 0% |
| coastal-5km | 3/3 | 211 | 1.2% | 0% | 44.8% |
| bridge-4km | 3/3 | 348 | 5% | 0% | 25.2% |
| urban-exclusions | 3/3 | 136 | 4.4% | 0% | 24.7% |
| waypoint-one-urban | 3/3 | 189 | 20.8% | 0% | 31.4% |
| waypoint-two-ordered | 3/3 | 196 | 8% | 0% | 47.1% |
| waypoint-three-ordered | 3/3 | 228 | 5.8% | 0% | 46% |
| waypoint-suburban | 3/3 | 260 | 4.9% | 0% | 38.9% |
| waypoint-across-bridge | **0/3** | 362 | — | — | — |
| waypoint-narrow-spur | **0/3** | 261 | — | — | — |
| waypoint-impossible | 0/3 (correct) | 2 | — | — | — |

**18/20 scenarios valid · 5,373 engine calls · median 517 ms · p95 1,230 ms.**

What the baseline says, before anything is changed:

- **Rural ground costs 7–10× an urban request** (989 and 1,291 calls against
  137) and still under-delivers. That is the discovery-batch loop running to
  exhaustion, and it is the single largest cost in the table.
- **Waypoint distance error is far worse than standard mode** — 20.8% on
  `waypoint-one-urban`, against 1–8% everywhere else. Waypoint mode relaxes the
  distance gate to 25%, and the single-global-guide-point search is not aiming
  well enough to need less. Phase 4's target.
- **Two waypoint scenarios return nothing at all** where a walk plausibly
  exists: a pin across a chokepoint and a pin at the end of a promenade. Both
  are cases where the retrace is structural. Phases 4 and 7.
- **Alternative-to-alternative shared ground runs 25–49%** against a 55% limit,
  measured geometrically. Phase 1 should show whether that is real shared
  ground or parallel-street inflation.

## 11. One production defect found and fixed

The benchmark crashed `bridge-4km` outright on the first run. `@turf/union`
(polyclip-ts) throws on degenerate corridor geometry — a walk doubling back
along exactly the same line buffers into corridors sharing a whole edge — and
that exception escaped `buildAvoidanceAreas`, through `routeLegAttempt`, out of
`generateLoops`, and reached the walker as a generic 500 for the entire
request rather than the loss of one candidate.

Fixed in `avoidance.ts`: merging is now an optimisation that may fail, not a
requirement. Where the corridors cannot be merged they are sent separately —
the same ground, described in more pieces — and where the doorstep circle
cannot be cut out, it is not cut out. An avoidance corridor is a preference;
a preference that cannot be expressed is a weaker preference, not an error.

This is the only intentional change to production route behaviour in Phase 0,
and it only affects requests that previously failed.

## 12. What Phase 0 could not establish

- **No live GraphHopper and no Docker in this environment.** Every number above
  comes from the synthetic networks. `edge_id` support, `/isochrone` and `/spt`
  availability, real snapping behaviour, real network stretch, and real
  latency are all unverified, and every phase that depends on one of them must
  probe at runtime and fall back rather than assume.
- **No load test.** Concurrency and queue defaults remain untuned against real
  traffic, as they were.
