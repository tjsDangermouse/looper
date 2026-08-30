# Looper Routing — Consolidated Handoff

## Purpose

This file replaces the individual routing-phase reports and the long conversation history for future Looper routing work.

It records only the conclusions that still matter: current architecture, measured findings, retained changes, rejected avenues, benchmarks, and the next problem to solve.

---

# 1. Product / Routing Goal

Looper generates walking and running loops near a user-specified target distance.

Important requirements:

- Routes should form useful loops rather than out-and-back walks.
- Distance should be close to the requested target.
- Retracing should be low.
- Multiple offered routes should be meaningfully different.
- Ordered user waypoints are supported.
- Route quality matters more than micro-optimising a low-level pathfinder.
- The eventual architecture should remain compatible with local/on-device routing and small regional graph/PBF workflows.

Looper owns the high-level loop-generation logic.

GraphHopper owns low-level point-to-point routing.

Current conceptual architecture:

```text
Looper
candidate generation
waypoints
incremental legs
avoidance
retries / repair
quality
diversity
        ↓
thin Java routing facade
        ↓
GraphHopper 11 library
```

---

# 2. GraphHopper Reference Configuration

GraphHopper source/version used for all routing-equivalence work:

```text
GraphHopper release 11.0
commit: 69e50f6e
```

Actual routing profile:

```text
foot
```

`looper_foot.json` is the profile's custom-model file, not the profile name.

Current routing mode:

```text
LM hybrid
AStarBidirection
LMApproximator
epsilon = 1
node-based traversal
16 prepared landmarks
8 active landmarks
```

Looper does not explicitly send an algorithm parameter. GraphHopper's default hybrid routing path selects `astarbi`.

CH is not used.

GraphHopper configuration is now considered settled and should not be retuned without new evidence.

---

# 3. Phase 1 — GraphHopper Equivalence

## Objective

Stop reinventing GraphHopper.

Use GraphHopper itself as the local reference router and prove that a direct Java/library implementation reproduces the running GraphHopper service exactly.

## Result

PASS.

The following were compared:

```text
running GraphHopper container
direct GraphHopper Java API
minimal GraphHopper-library facade
```

Across 17 low-level fixtures and the production Looper generation probes, routes matched on:

- distance;
- geometry hash;
- full edge-ID sequence;
- snapped waypoints;
- weight;
- visited-node count.

The searches were equivalent, not merely similar.

## Performance

Direct Java invocation was roughly:

```text
1.6x faster than the GraphHopper HTTP server
```

The minimal facade over a socket/HTTP boundary was approximately:

```text
1.2–1.5x faster at low level
```

Full Looper generation improved by about:

```text
9%
```

## Architecture conclusion

Do not fork GraphHopper source.

Do not write a replacement A*, snapping implementation, importer, ALT implementation, or custom OSM graph.

Use:

```text
small Looper Java facade
        ↓
GraphHopper core/library
```

GraphHopper-as-a-library is the reference routing engine.

---

# 4. Phase 2 — GraphHopper Performance Investigation

## Objective

Determine whether GraphHopper itself could be materially accelerated for Looper's avoidance-heavy workload.

## Result

NO MATERIAL ENGINE-LEVEL WIN.

Warm full-suite baseline:

```text
~2,294 ms
```

Best remeasurement:

```text
~2,233 ms
```

Nominal difference:

```text
2.7%
```

This was within benchmark noise.

## Most important finding

Across the captured workload of 1,863 real low-level routing calls:

```text
GraphHopper in-process                       ~2,261 ms
actual graph search                           ~507 ms
custom weighting construction                 ~650 ms

Node ↔ Java boundary                        +3,116 ms
Node JSON.parse                               +242 ms
contention / concurrency effect             +6,485 ms

Looper-attributed engineMs                  ~11,862 ms
```

Therefore:

```text
GraphHopper itself ≈ 19% of what Looper calls engine time
actual pathfinding ≈ 4%
```

Graph search was not the major performance problem.

## Request mix

Across the 1,863-call corpus:

```text
avoid-strong      1,227
plain               368
avoid-relaxed       268
```

By purpose:

```text
leg               1,024
join-pullback       422
leg-budget          201
waypoint-leg        147
spike                59
waypoint-direct       8
leg-relaxed           2
```

## Landmark findings

Plain routes receive a strong LM heuristic.

Representative result:

```text
plain:
LM on      192 visited
LM off   1,290 visited
≈6.7x node reduction
```

Avoidance weakens but does not invalidate LM:

```text
avoidance 0.05:
LM on    1,888
LM off   4,162
≈2.2x node reduction
```

`distance_influence: 2000` receives effectively no landmark benefit.

The reason is mathematical:

```text
LMApproximator = max(landmarkBound, beelineBound)
```

The landmark bound remains in the prepared profile weighting's units.

The beeline bound uses the request weighting's `calcMinWeightPerDistance()`.

With `distance_influence: 2000`, the beeline bound dominates on every sampled node, so the landmark term is valid but unused.

This is correct GraphHopper behaviour.

## Important production correction

`distance_influence: 2000` is effectively absent from the normal production workload.

It is only used by `trueLowerBound` in the waypoint refusal-path logic when the direct backbone appears too long.

In the measured production corpus:

```text
lower-bound calls = 0
```

A dedicated LM profile for this request type was tested and was about 25% faster on that synthetic class, but it was not adopted because the class did not occur in production.

## Landmark tuning

Prepared/active landmark combinations including 16, 32 and 64 landmarks were tested.

More landmarks reduced visited nodes, but the extra heuristic computation consumed the gain.

No end-to-end improvement was measurable.

Keep:

```text
16 prepared
8 active
```

## Algorithm tuning

Tested GraphHopper-supported configurations included:

```text
astarbi + LM
astar + LM
flexible astarbi
flexible dijkstrabi
```

No production request class benefited enough to justify per-class algorithm selection.

## Avoidance strength

The strong avoidance multiplier:

```text
0.05
```

does real route-quality work and should not be weakened.

It increases search nodes, but that extra graph search is nearly invisible in end-to-end latency.

Adaptive weak-then-strong avoidance was rejected because weaker searches were not meaningfully cheaper and retries would add cost.

## Phase 2 conclusion

Freeze GraphHopper configuration.

Future optimisation should target how Looper uses GraphHopper, not GraphHopper itself.

---

# 5. Phase 3A — Boundary and State Reuse

## Objective

Reduce repeated transport/custom-model work without changing Looper's routing algorithm.

Implemented experimentally:

- request-scoped corridor/model registry;
- reusable GraphHopper custom weighting where safe;
- exact route-request memoisation;
- single-flight duplicate request handling;
- transport/batching/concurrency measurements.

## Result

NO MATERIAL END-TO-END WIN.

Baseline:

```text
~2,230 ms
```

Retained combination:

```text
~2,170 ms
```

Nominal improvement:

```text
~2.7%
paired median roughly 4%
```

The baseline itself varied by roughly the same amount.

## Model registry

Corridors are registered individually rather than whole corridor sets because consecutive models tend to add one new corridor to a previously seen set.

Measured corpus:

```text
2,784 corridor polygon references
658 distinct polygons
76.4% of polygon references already seen
```

Request payload reduction:

```text
5.57 MB → ~1.99 MB
≈65% reduction
```

## Weighting reuse

Safe reused state included:

- immutable `CustomWeighting`;
- compiled `CustomWeightingHelper`;
- JTS `PreparedPolygon`;
- parsed `CustomModel` / geometry.

Request-specific state was not shared:

- `QueryGraph`;
- `Snap`;
- routing algorithm instances.

Weightings built:

```text
1,495 → 738
```

Serial `hopper.route` time fell by roughly:

```text
9.3%
```

but the walker's end-to-end wait barely moved.

## Exact request memoisation

Measured exact duplicates:

```text
118 of 1,863 calls
≈6.3%
```

Breakdown included:

```text
74 completed-cache hits
44 single-flight joins
```

Removing those calls returned about:

```text
2.7% wall-time improvement
```

This established an important empirical rule:

> Removing X% of routing calls tends to return roughly half of X% in full-generation wall time.

## Boundary finding

The boundary cost is mostly per call, not per byte.

A warm no-routing exchange to the minimal facade costs roughly:

```text
0.58 ms
```

Payload reduction therefore did not transform performance.

Keep-alive was already enabled.

Batching was slower at every useful batch size because a batch waits for its slowest member and destroys useful completion independence.

Lower-level custom binary/Unix-socket work was therefore rejected.

## Concurrency

Six-way concurrency was initially retained.

Phase 3A showed that increasing concurrency also increases speculative candidate work.

This became important in Phase 3B.

## Retained Phase 3A switches

Available:

```text
LOOPER_MODEL_REGISTRY=true
LOOPER_ROUTE_MEMO=true
```

They are path-identical.

They reduce bytes and repeated work but are not the primary performance lever.

---

# 6. Phase 3B — Reduce GraphHopper Call Count

## Objective

Understand why Looper makes so many GraphHopper calls and eliminate structurally unnecessary ones.

## Result

Meaningful improvement, but below the defined PASS threshold.

Measured gate:

```text
Phase 3A:
2,255 ms
1,849 calls

Phase 3B:
1,904 ms
1,310 calls

wall-time improvement:
15.6%

call reduction:
29.2%

calls per returned route:
132.1 → 93.6
```

This confirmed the Phase 3A empirical exchange rate:

```text
29.2% fewer calls
→
15.6% lower wall time
```

## Call graph finding

Fix-up chains were shallow.

Examples:

```text
leg
leg → join-pullback → join-pullback
leg → leg-budget
leg → leg-budget → join-pullback → join-pullback
leg → spike
```

The problem was not deep recursion.

A large fraction of ordinary legs simply needed some fix-up.

---

# 7. Retained Phase 3B Changes

## B1 — Join-pullback reuses previous routed geometry

Original join-pullback rerouted both sides of a pulled-back seam.

Analysis showed that routing from the previous leg's start to a point already lying on the previously returned GraphHopper path reproduces the existing prefix.

Therefore the previous leg can sometimes be trimmed rather than routed again.

Guards prevent pathological trimming:

- candidate point must be sufficiently close to the intended reach;
- at least 40% of the previous leg must survive.

Join-pullback calls:

```text
416 → 260
```

Important:

B1 is bad alone because shortening a previous leg can trigger more retry churn.

Retain B1 only together with B3.

## B2 — Leg-budget once per leg

`leg-budget` was not an iterative numerical solver.

The same leg step often paid for the same type of budget reroute on multiple outer attempts.

Measured behaviour showed that repeated firings after the first result had little new value.

Calls:

```text
201 → 142
```

Retained.

## B3 — Short backtrack alone no longer triggers leg retry

This was the largest single Phase 3B win.

Before:

```text
848 leg attempts
570 retries
145 exhausted retries
```

Retry causes:

```text
short backtrack alone      212
over planned length only   194
both                       164
```

A retry triggered only by a short backtrack cleared that backtrack only about:

```text
6%
```

of the time.

The join-pullback mechanism was already the part that actually repairs the dead-ended seam.

Change:

A short backtrack alone does not force another leg retry unless the budget condition also requires it.

Result:

```text
leg attempts     848 → 665
retried          570 → 327
retry exhausted  145 → 50
```

Single-stage effect:

```text
~11.1% lower wall time
~13.7% fewer calls
```

Retained.

## B4 — Routing concurrency reduced from 6 to 4

With the cheaper Phase 3B candidate builder, wider concurrency became more speculative.

Measured retained algorithm:

```text
fan-out   wall ms   GH calls

1         3919      1122
2         2287      1193
3         1930      1246
4         1850      1297
5         1972      1382
6         1941      1450
8         2058      1626
```

Four-way is the best balance.

Retain:

```text
ROUTING_CONCURRENCY=4
```

## B5 — Keep closest-fitting leg attempt

Tested and rejected.

Although logically attractive, it increased downstream work and wall time.

Do not enable:

```text
LOOPER_KEEP_BEST_LEG_ATTEMPT
```

---

# 8. Current Retained Phase 3B Configuration

Use together:

```text
LOOPER_PULLBACK_REUSES_PREVIOUS=true
LOOPER_BACKTRACK_NEEDS_BUDGET=true
LOOPER_BUDGET_ONCE_PER_LEG=true
ROUTING_CONCURRENCY=4
```

The first three should be enabled together.

Phase 3A infrastructure may also be enabled:

```text
LOOPER_MODEL_REGISTRY=true
LOOPER_ROUTE_MEMO=true
```

Do not independently enable B1 without B3.

---

# 9. Phase 3B Quality Result

Routes changed because B1/B3 change what Looper asks GraphHopper to route.

This was expected.

Across all 14 offered walks:

```text
mean quality:
66.9 → 65.7

mean repeated ground:
1.69% → 1.66%

mean distance error:
6.0% → 6.6%

total u-turns:
1 → 1

walks offered:
14 → 14
```

This was considered a reshuffle rather than a major quality trade.

Waypoint outputs remained identical in the measured waypoint fixtures.

GraphHopper itself was unchanged.

---

# 10. The Major Structural Finding

After the Phase 3B fix-up work, the dominant remaining problem is no longer routing, boundary overhead, retries, or seam repair.

It is candidate generation.

Measured Phase 3B analysis:

```text
186 candidate builds
27 passing candidates
14 offered walks
```

Approximately:

```text
76% of remaining routing calls
```

were spent on candidates eventually rejected by the quality gate.

The largest rejection class was distance.

```text
distance failures:
95 builds
1,138 calls
61.7% of all calls in the analysed baseline
```

Distance failure breakdown:

```text
25 too long
70 too short
```

Therefore:

```text
74% of distance failures are undershoots
```

---

# 11. Why Candidates Miss Distance

The planned corner legs themselves are not badly controlled.

Typical:

```text
actual routed corner leg / planned share
≈ 1.06–1.12 median
```

The major defect is the final closure leg.

Looper plans the intermediate/corner legs, then finally routes back to the start.

The closing leg is not properly budgeted during earlier geometry selection.

Measured:

```text
closing route distance
/
budget remaining for closure
≈ 1.94 median
```

The generator therefore behaves conceptually like:

```text
choose bearing
choose corners
route planned corner legs
spend most of target budget
route home
discover how long closure actually is
accept/reject candidate
```

This is the next architectural problem.

---

# 12. What Is No Longer Worth Optimising

Do not spend another phase on:

- GraphHopper LM tuning;
- more prepared landmarks;
- routing algorithm selection;
- disabling LM on normal traffic;
- weakening avoidance;
- adaptive avoidance retries;
- GraphHopper source forks;
- custom A*;
- custom snapping;
- custom graph importer;
- binary transport;
- batching route calls;
- HTTP keep-alive tuning;
- response-field trimming;
- more join-pullback gating;
- more leg-budget gating;
- arbitrary reduction of candidate count;
- coordinate quantisation for near-duplicate routes.

Measured evidence has already rejected or exhausted these avenues.

---

# 13. Phase 4 Starting Point

Phase 4 is:

```text
Closure-Aware Candidate Generation
```

Main question:

> How can Looper choose intermediate corners so the eventual GraphHopper route back to the start is already likely to fit the requested target distance?

The aim is not merely to make rejected candidates cheaper.

The aim is to produce fewer doomed candidates.

---

# 14. Phase 4 Hypothesis

Current conceptual planning:

```text
target = 5 km

planned corner leg
planned corner leg
planned corner leg
then route home and hope the closure fits
```

Desired conceptual planning:

```text
after every corner:

distance already used
+
estimated cost of eventually returning home
+
budget needed for remaining shape

must remain compatible with target distance
```

A future corner should be pushed outward or inward based on predicted final closure cost.

---

# 15. Phase 4 Required Investigation

Before changing production candidate generation:

## A. Measure closure at every stage

For each candidate and intermediate corner record:

- distance already used;
- remaining target budget;
- straight-line distance home;
- actual eventual GraphHopper distance home;
- final closure distance;
- candidate total distance;
- pass/fail.

## B. Oracle analysis

Retrospectively use actual GraphHopper closure distances to determine:

> If perfect closure knowledge had been available during candidate construction, how many distance failures could theoretically have been prevented?

Do not build a complex estimator until this theoretical ceiling is known.

## C. Evaluate cheap closure estimators

Potential deterministic estimators:

```text
straight-line home distance
straight-line × global network stretch
straight-line × candidate-local network stretch
bounded local stretch
```

Use already-known route information where possible.

No machine learning.

No Isle-of-Man-specific constants.

## D. Determine required accuracy

Looper accepts a distance band, not an exact metre target.

Estimate only as accurately as the acceptance band requires.

## E. Closure-aware guide selection

Use predicted closure cost when choosing the next corner's radius/bearing.

Conceptually:

```text
remaining = target - distanceUsed

closureReserve = estimatedNetworkDistanceHome

budgetForFurtherShape =
remaining - closureReserve
```

Prospective corners should leave a plausible route home inside the accepted distance band.

## F. One-extra-probe experiment

A direct GraphHopper closure probe may be tested as an oracle/practical strategy.

But it must save more future routing calls than it adds.

Do not automatically add one GraphHopper route-home call after every corner.

## G. Preserve diversity

Closure-aware generation must not collapse all routes onto the same shape.

Protect:

- compass spread;
- mirrored candidate purpose;
- physical-edge diversity;
- geometry diversity;
- low retracing.

---

# 16. Phase 4 Benchmark Baseline

Use Phase 3B retained result as the reference.

Canonical measured gate:

```text
Phase 3B retained:

~1,904 ms
~1,310 calls
```

Call counts vary slightly due to candidate concurrency/early-stop races, so use repeated warm medians.

Current candidate efficiency is roughly:

```text
27 passing
/
186 built
≈14.5% pass rate
```

Desired direction:

```text
>=25% pass rate useful
>=35% strong
```

Distance-failure reduction target:

```text
>=40% useful
>=60% strong
```

Especially reduce undershoot.

---

# 17. Phase 4 Success Criteria

A successful closure-aware redesign should:

1. materially reduce distance failures;
2. materially increase candidate pass rate;
3. reduce calls spent on rejected candidates;
4. reduce GraphHopper call count;
5. improve end-to-end wall time;
6. preserve offered-route count;
7. preserve or improve route quality;
8. preserve route diversity;
9. leave GraphHopper untouched;
10. leave the Phase 3B fix-up layer largely untouched.

A geometry change is acceptable in Phase 4 because candidate generation is intentionally changing.

Quality, distance and diversity matter more than geometry identity.

---

# 18. Local / On-Device Routing Compatibility

Nothing in the current architecture prevents future local regional graph downloads.

The intended eventual graph lifecycle may be:

```text
user location
   ↓
determine local region
   ↓
download regional OSM/PBF data
   ↓
GraphHopper import
   ↓
BaseGraph + location index
   ↓
LM preparation if retained
   ↓
cache ready-to-route region
```

Important:

GraphHopper does not route directly from raw PBF.

The PBF must first be imported into GraphHopper's graph format.

The unresolved future question is therefore not architectural compatibility, but:

> Can small regional graph import/preparation be made fast and compact enough for the intended device workflow?

That is explicitly not part of Phase 4.

---

# 19. Repository Guidance

The individual historical phase reports can now be archived or removed from the working repo if desired:

```text
GRAPHHOPPER_MINIMAL_BASELINE_REPORT.md
GRAPHHOPPER_LOOPER_PHASE2_PERFORMANCE.md
GRAPHHOPPER_LOOPER_PHASE3A_BOUNDARY.md
GRAPHHOPPER_LOOPER_PHASE3B_CALL_REDUCTION.md
```

This consolidated file contains the project conclusions that should be carried into future work.

Keep benchmark/source code from those phases where it remains useful for regression testing.

Do not remove test harnesses merely because the narrative reports are replaced.

---

# 20. Short Handoff for a New AI Session

If using this file in a fresh ChatGPT/Codex/Claude session, the essential state is:

```text
Looper uses GraphHopper 11 directly as its low-level router.

GraphHopper has already been proven route-identical and sufficiently fast.
Do not rewrite or retune it.

Phase 2 proved actual graph search is only a small part of total latency.

Phase 3A proved boundary/payload optimisation gives only a few percent.

Phase 3B reduced routing calls ~29% and wall time ~16% by:
- trimming reusable join-pullback prefixes;
- eliminating ineffective short-backtrack retries;
- limiting leg-budget reroutes;
- reducing routing concurrency from 6 to 4.

Current baseline:
~1.9 s across the six production probes
~1,310 GraphHopper calls.

The major remaining problem:
~76% of calls are spent on rejected candidates.
Most rejected candidates fail distance.
~74% of distance failures undershoot.
The final closure leg is not properly planned and is ~1.94x the remaining closure budget at median.

Next task:
design and test closure-aware candidate generation so intermediate corners reserve enough network distance to return home, increasing candidate pass rate and reducing doomed candidates.

Do not revisit GraphHopper optimisation, transport optimisation, or retry micro-tuning unless new evidence invalidates the previous measurements.
```

---

# Guiding Principle

> GraphHopper is no longer the routing problem. Looper's remaining performance problem is choosing candidate loop geometry that is likely to close near the requested distance before spending several routing calls discovering that it does not.
