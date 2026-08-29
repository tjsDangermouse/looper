# GraphHopper under Looper's workload — Phase 2

Phase 1 established that Looper's routing *is* GraphHopper's, invoked directly.
Phase 2 asks the next question: how much faster can Looper be made by using
GraphHopper's own machinery more intelligently, before changing Looper's
algorithm?

Measured 2026-08-29 on darwin/arm64, Docker Desktop, GraphHopper 11.0, Isle of
Man (35,088 nodes, 42,016 edges). Reproduce with:

```sh
npx tsx bench/phase2/capture.mts            # the workload corpus: 1,863 real calls
npx tsx bench/phase2/anatomy.mts            # §2, §3, §21 — what the calls are
docker run ... com.looper.routing.Lab       # §6, §15, §16, §19 — the configuration matrix
docker run ... com.looper.routing.Heuristic # §4 — the landmark bound, measured
docker run ... com.looper.routing.ModelCost # §18 — what a corridor costs before searching
npx tsx bench/phase2/transport.mts          # §20 — the cost of the boundary
./bench/phase2/prepare-landmarks.sh 16 32 64
./bench/phase2/landmark-sweep.sh            # §7 — prepared × active
npx tsx bench/phase2/avoidance-strength.mts # §12, §13 — penalty strength
npx tsx bench/phase2/end-to-end.mts         # §25, §26 — the gate
```

## Executive conclusion: **NO MATERIAL ENGINE-LEVEL WIN**

```
Phase 1 baseline (full suite, warm, median of 9):  2,294 ms
Phase 2 best measured total:                       2,233 ms
improvement:                                         2.7%
```

That 2.7% is not a result, and the 2,233 ms is not a configuration: it is **the
baseline engine measured a second time**. Nothing this phase tried beat the
shipped configuration by more than the shipped configuration beats itself. The
same engine benchmarked against itself in the same session differs by 2.7% on
the total and by up to 16% on a single fixture, so the noise floor of a
whole-generation measurement here is larger than every engine-level effect this
phase found. The honest statement is that **no
GraphHopper configuration tested moves Looper's latency at all**, and the
brief's own rule applies: improvement is below 15%, so the next phase should
reduce and reuse routing calls rather than tune the engine further.

The reason is not that the search is already fast enough to be uninteresting.
It is that **the search was never where the time was**, and the evidence for
that is the most useful thing this phase produced:

| layer | over the same 1,863 real calls | share of what Looper measures |
|---|---:|---:|
| GraphHopper, in-process | **2,261 ms** | 19% |
| — of which the graph search itself | ~507 ms | 4% |
| — of which building the custom weighting | ~650 ms | 5% |
| — of which snapping, extraction, details, instructions | the balance | 10% |
| the Node↔Java boundary (HTTP, JSON both ends), serial | +3,116 ms | 26% |
| Node's own `JSON.parse` of the responses | +242 ms | 2% |
| queueing under Looper's six-way concurrency | +6,485 ms | 55% |
| **what Looper's own metrics call `engineMs`** | **11,862 ms** | 100% |

Phase 1 concluded "the routing engine is not the bottleneck" from the fact that
a plain leg costs 1–5 ms. This phase can put a number on it: of every
millisecond Looper attributes to the engine, **GraphHopper spends 0.19 of it,
and the actual pathfinding gets 0.04**.

No hard-stop condition was triggered. No routing logic was written: every
experiment is a GraphHopper configuration key, a GraphHopper request hint, or a
GraphHopper profile. Nothing was forked, copied or modified.

## Request workload anatomy

The corpus is not a fixture set. `bench/phase2/capture.mts` runs the six
established production probes through a real route service with
`LOOPER_TRACE_FILE` set and records every engine call it makes, with the points
and custom model each carried. Call counts reproduce Phase 1's exactly (291,
215, 763, 181, 34, 379).

Wall time below is measured at Looper's own call site, under production
concurrency, so it includes queueing and the boundary — that is deliberately
the number Looper actually pays.

| request class | calls | total ms | % of engine ms | mean | median | p95 | max | visited nodes | mean visited |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| avoid-strong (`multiply_by 0.05`) | 1,227 | 8,130 | 68.5% | 6.63 | 6 | 12 | 30 | 740,762 | 604 |
| plain (no custom model) | 368 | 1,886 | 15.9% | 5.13 | 5 | 9 | 12 | 71,240 | 194 |
| avoid-relaxed (`multiply_by 0.2`) | 268 | 1,846 | 15.6% | 6.89 | 7 | 12 | 17 | 172,316 | 643 |
| **lower-bound (`distance_influence: 2000`)** | **0** | **0** | **0%** | — | — | — | — | — | — |
| **total** | **1,863** | **11,862** | | 6.37 | | | | **984,318** | 528 |

By the fixup paying for the call:

| purpose | calls | total ms | % | mean ms | mean visited |
|---|---:|---:|---:|---:|---:|
| `leg` | 1,024 | 6,812 | 57.4% | 6.65 | 491 |
| `join-pullback` | 422 | 2,610 | 22.0% | 6.18 | 262 |
| `leg-budget` | 201 | 1,428 | 12.0% | 7.10 | 785 |
| `waypoint-leg` | 147 | 634 | 5.3% | 4.31 | 1,288 |
| `spike` | 59 | 342 | 2.9% | 5.80 | 372 |
| `waypoint-direct` | 8 | 21 | 0.2% | 2.63 | 273 |
| `leg-relaxed` | 2 | 15 | 0.1% | 7.50 | — |

Two things in this table are worth more than the rest.

**Avoidance is 84% of all calls and 84% of all engine time, but it is not
expensive in the way Phase 1's fixtures suggested.** Phase 1's avoidance
fixtures settled 3,300–5,400 nodes; the median real avoidance call settles
**604**. Those fixtures were chosen to cover request *shapes* and they do that
well, but they are not a sample of the *mix*, and a latency budget is spent on
the mix. An avoidance call costs 1.29× a plain one at Looper's call site while
settling 3.1× the nodes — which already says the node count is not what is being
paid for.

**Corridor count barely matters.** Across the real avoidance calls:

| areas in the model | calls | mean ms | mean visited nodes |
|---:|---:|---:|---:|
| 1 | 660 | 6.44 | 631 |
| 2 | 498 | 6.77 | 652 |
| 3 | 245 | 7.01 | 543 |
| 4 | 71 | 6.68 | 466 |
| 5 | 17 | 7.47 | 324 |
| 6 | 4 | 8.75 | 649 |

More corridors settle *fewer* nodes, not more — by the time a walk has six of
them the remaining route is heavily constrained. Cost rises slightly and it
rises with the polygon arithmetic, not with the search.

## `distance_influence: 2000`: why Looper uses it, and how often

**Never, in production.** `shortestPathCustomModel()` has exactly one call
site: `trueLowerBound` in `generate.ts`, reached only from the waypoint path,
and only after `fitsInPlan` has already decided the direct backbone is too long
for the walker's plan. It exists to answer "is this refusal honest?" — Looper's
profile expresses preferences as priority multipliers at or below one and
GraphHopper divides by priority, so the route the profile likes can be
physically longer than the shortest one, and a preference is not a floor.
Refusing a walker their walk on a floor we had not established would be
refusing on a guess.

Both waypoint fixtures fit their plans, so the model is never built. The eight
`waypoint-direct` calls in the corpus are the *unpenalised* backbone routes from
a different call site (`generate.ts:1277`), and the trace records them as
`plain` with a null model — which is what they are.

So §3, §10 and §11 of the brief rest on a premise that production traffic does
not support: **this model is a refusal-path guard, not a workload.** It was
characterised anyway, below, because a guard that fires is still a guard that
costs — but nothing it could save is worth an end-to-end measurement.

## LM behaviour, with the bounds actually measured

`bench/phase2/heuristic-cases.mts` and `com.looper.routing.Heuristic` take one
pair of points (Douglas seafront → Onchan) under four weightings, and for
sampled nodes compare the bound `LMApproximator.approximate` returns against the
true remaining weight, computed exactly by GraphHopper's own Dijkstra. The ratio
between the two is the only thing that decides how much graph an A* settles.

| weighting | `calcMinWeightPerDistance` | chosen bound as % of truth | nodes where the landmark bound won |
|---|---:|---:|---:|
| plain | 0.2400 | **99.8%** | 100.0% |
| avoidance 0.2 | 0.2400 | 53.6% | 92.4% |
| avoidance 0.05 | 0.2400 | **44.8%** | 92.4% |
| `distance_influence: 2000` | 2.2400 | 74.7% | **0.0%** |

The mechanism is `LMApproximator.approximate`, which returns
`max(landmarkBound, beelineBound)` — and the two terms are computed in different
weightings. The landmark term comes out of `LandmarkStorage`, which was prepared
under the **profile's** weighting and is never rescaled. The beeline term is
`BeelineWeightApproximator`, which multiplies the straight-line distance by
`weighting.calcMinWeightPerDistance()` of the **request's** weighting —

```java
// CustomWeighting.java
return 1d / (maxSpeedCalc.calcMax() / SPEED_CONV) / maxPrioCalc.calcMax() + distanceInfluence;
```

— so it adapts to the request and the landmark term does not. That single
asymmetry explains all four rows.

**Plain — strong.** Both terms are in the prepared weighting's own units, the
landmark set covers the island well, and the bound lands within 0.2% of the
truth. A near-exact heuristic is why a plain leg settles 194 nodes on a
35,088-node graph.

**Avoidance — weakened, and by a computable amount.** A request model may only
*multiply* priority by a value in `[0,1]` (`FindMinMax.checkLMConstraints`
enforces it, and Looper satisfies it by construction), so every edge weight
under the request weighting is greater than or equal to the one the landmarks
were prepared with. The landmark bound therefore stays **admissible** — it is
still a valid lower bound, which is why landmarks keep working at all. But it
is a lower bound on a *cheaper* graph: inside a corridor the real weight is
twentyfold what the preparation assumed, and the bound knows nothing about it.
The beeline term cannot rescue this either, because `maxPrioCalc.calcMax()` is
the maximum priority over the model and avoidance never raises anything —
`calcMinWeightPerDistance` is 0.2400 for plain and avoidance alike. So both
bounds stay where they were while the truth rose, and tightness falls from 99.8%
to 53.6% and then 44.8%. A bound at 45% of the truth is not far from no
heuristic at all, which is exactly what the node counts show: 604 settled
against 194.

**`distance_influence: 2000` — no landmark contribution whatsoever, and this is
correct behaviour rather than a defect.** GraphHopper adds
`distance × distance_influence / 1000` to each edge weight, so 2000 adds **2.0
weight units per metre** — and `calcMinWeightPerDistance` duly moves from 0.2400
to 2.2400. Now 89% of the beeline bound is a distance term that is *exact* for
the straight-line part, so the beeline bound reaches 74.7% of the truth. The
landmark bound, still expressed in a weighting where distance is free, cannot
compete: `max(lm, beeline)` picks the beeline term on **100.0%** of nodes.
Landmarks are valid, and useless. Phase 1's "620 visited with LM, 620 without"
was not a measurement error.

That also settles a question Phase 1 left slightly open: the landmark heuristic
is not merely *less useful* under this model, it is *never consulted*, and the
work of computing it is pure loss. See the dedicated-profile experiment below.

## Landmark experiments (§5, §6, §7, §8)

**Audit.** `config.yml` sets neither `prepare.lm.landmarks` nor
`routing.lm.active_landmarks`, so both are GraphHopper's defaults:
`LMPreparationHandler.landmarkCount = 16`, and `GraphHopper.java:607` sets the
active default to `min(8, prepared)` = 8. Phase 1's "16 prepared / 8 active" was
right, and it is **a default, not a tuning decision** — nobody chose it for this
graph. One preparation exists, `landmarks_foot`, 3,145,828 B, over a single
subnetwork, prepared under the profile weighting (`LM_BFS|custom`).

**Placement (§8).** GraphHopper's own selection put the sixteen landmarks around
the island's extremities and across its middle — Castletown (54.06, −4.76), Peel
(54.23, −4.68), Ramsey (54.32, −4.40), the Point of Ayre approaches, with a
cluster through the Douglas conurbation where the network is densest. For an
island this shape that is close to what one would choose by hand, and the plain
row of the table above — a bound at 99.8% of truth — is the evidence that it
works. Nothing suggested a hand-placed set would help, and none was tried.

**The matrix.** Three preparations, each its own import (the count is written
into the graph, so it cannot be moved by a request hint), each replayed against
the full corpus in its own JVM after a corpus-wide warm-up.

| prepared | active | `landmarks_foot` | visited nodes | in-JVM ms | routes |
|---:|---:|---:|---:|---:|---|
| 16 | 2 | 3.1 MB | 1,080,484 | 2,176 | identical |
| 16 | 4 | 3.1 MB | 1,019,580 | 2,235 | identical |
| 16 | 6 | 3.1 MB | 997,972 | 2,233 | identical |
| **16** | **8** *(shipped)* | 3.1 MB | 984,318 | 2,216 | identical |
| 16 | 12 | 3.1 MB | 977,928 | 2,186 | identical |
| 16 | 16 | 3.1 MB | 977,216 | 2,201 | identical |
| 32 | 8 | 5.2 MB | 988,086 | **2,131** | identical |
| 32 | 16 | 5.2 MB | 965,070 | 2,172 | identical |
| 32 | 32 | 5.2 MB | 960,212 | 2,290 | identical |
| 64 | 4 | 9.4 MB | 1,018,056 | **2,122** | identical |
| 64 | 12 | 9.4 MB | 954,960 | 2,167 | identical |
| 64 | 32 | 9.4 MB | **936,624** | 2,293 | identical |

Every cell returns the same routes — the path fingerprint, a hash of every
call's full edge-id sequence, is identical across all twenty-two configurations
tested in this phase.

Two findings. **More landmarks do settle fewer nodes** — 1,080k at two active
down to 937k at 64/32, a 13% reduction — and **it buys nothing**, because the
extra bound computations cost about what the saved settles save. The whole
matrix spans 2,122–2,293 ms, 8%, with no monotone trend: the fastest cells (32/8
and 64/4) are the ones settling *more* nodes than the slowest (64/32).

The brief warned not to assume more active landmarks is faster. It is not, and
the crossover is visible: node count falls monotonically with active count while
time turns around between 12 and 16.

**End-to-end, the honest test.** A 64-landmark graph served from its own core
alongside the shipped one, both warmed against the whole corpus first, nine
repetitions per fixture:

| fixture | 16/8 median ms | 64/12 median ms | change | routes identical? |
|---|---:|---:|---:|---|
| douglas-5km | 381 | 369 | −3.1% | yes |
| douglas-3km | 223 | 220 | −1.3% | yes |
| peel-5km | 644 | 654 | +1.6% | yes |
| onchan-5km | 165 | 168 | +1.8% | yes |
| wp-one | 125 | 127 | +1.6% | yes |
| wp-two | 750 | 767 | +2.3% | yes |
| **total** | **2,288** | **2,305** | **+0.7%** | all identical |

Against a noise floor of ±2.7% on the total, +0.7% is nothing. **Rejected**: a
3× larger landmark file, for nothing.

*A warning worth recording.* The first run of this comparison reported the
64-landmark engine **22.8% slower**, with a `peel-5km` p95 of 1,587 ms. The
engine was JIT-cold and the baseline had been serving all afternoon. Phase 1's
bench README says exactly this and it was still nearly published as a finding.
Both engines are now warmed against the whole corpus before either is timed.

## Algorithm experiments (§15, §16, §17)

| configuration | visited nodes | in-JVM ms | routes |
|---|---:|---:|---|
| default (`astarbi` + LM, epsilon 1) | 984,318 | 2,260 | identical |
| `algorithm=astar` (unidirectional, + LM) | 984,318 | 2,227 | identical |
| `algorithm=astarbi` (named explicitly) | 984,318 | 2,233 | identical |
| `lm.disable=true` (flexible `astarbi`) | 1,707,892 | 2,391 | identical |
| `lm.disable=true, algorithm=dijkstrabi` | 1,707,892 | 2,375 | identical |

`LMRoutingAlgorithmFactory` accepts only `astar`, `astarbi` and
`alternative_route`, and treats an empty algorithm as `astarbi`; `dijkstra`,
`dijkstrabi` and the rest are unreachable while landmarks are on, which is why
the flexible rows have to disable LM to be measured at all. That constraint is
GraphHopper's, and it is the reason Phase 1 could list those classes as
discardable.

Per class, which is what §16 and §17 actually asked:

| class | LM visited | flexible visited | LM ms | flexible ms | LM's benefit |
|---|---:|---:|---:|---:|---:|
| plain | 193 /call | 775 /call | 0.42 | 0.56 | 4.0× nodes, **25% time** |
| avoid-strong | 603 /call | 916 /call | 1.42 | 1.45 | 1.5× nodes, **2% time** |
| avoid-relaxed | 642 /call | 1,110 /call | 1.38 | 1.51 | 1.7× nodes, 9% time |
| lower-bound *(synthetic)* | 448 /call | 447 /call | 0.55 | 0.44 | **none; LM costs 21%** |

**No production class is faster with landmarks disabled**, so the deterministic
per-class selection policy §17 asks for has nothing to select: one configuration
is best or indistinguishable everywhere, and adding a policy would add a branch
and a way to be wrong for no measured gain. **Rejected.**

The one class where `lm.disable` genuinely wins is the lower-bound model, and it
wins by 21% while returning a byte-identical path — the landmark bound is
computed on every node and chosen on none, so switching it off removes pure
waste. It has zero production calls. Banked, not shipped.

## The `distance_influence` investigation (§9, §10, §11)

**§9 is unsupported and is rejected on GraphHopper's own source.**
`Router.LMSolver.createPathCalculator` selects a preparation by
`landmarks.get(profile.getName())` — one landmark storage per profile name,
chosen by the profile and by nothing else. There is no mechanism by which a
request could select among several preparations for one profile, and no request
hint that would express it. Multiple preparations are therefore only reachable
through multiple profiles, which is §11.

**§11 works, and it is the one genuine engine-level win this phase found.** A
`foot_lower_bound` profile carrying `distance_influence: 2000` in the profile's
own custom model, with `profiles_lm` preparing landmarks for it, gives that
weighting a landmark set in its own units. The same 368 point-pairs:

| how the lower bound is asked for | visited nodes | in-JVM ms | path |
|---|---:|---:|---|
| request custom model on `foot` *(today)* | 164,826 | 211.8 | `1375ccf1…` |
| the same, `lm.disable=true` | 164,410 | 172.0 | `1375ccf1…` |
| dedicated `foot_lower_bound` profile | **72,712** | **157.9** | `1375ccf1…` |
| the same, `lm.disable=true` | 164,410 | 163.1 | `1375ccf1…` |

**2.27× fewer nodes and 25% faster, path-identical.** The landmark bound is now
prepared in a weighting where distance costs two units per metre, so it is
comparable with the beeline bound instead of being dominated by it, and the
heuristic starts working again — precisely as the mechanism above predicts. The
cost is a second preparation: +3.1 MB on disk and a second landmark build at
import.

It is not recommended for adoption **on this workload**, for one reason only:
the class has no calls. Shipping a second profile and a second preparation to
speed up a code path that fires only when a walker is about to be refused would
be adding a permanent cost to every import for a saving nobody has been
measured receiving. If the refusal path ever becomes common — a waypoint-heavy
release, say — this is a known, measured, route-identical 25%, and the config is
kept at `bench/phase2/graphs/config/config-lower-bound.yml`.

Alternatives considered and not pursued: a `shortest` weighting (GraphHopper 11
has no separate one — `CustomWeighting` with a distance influence *is* the
supported expression); raising `distance_influence` further (moves the beeline
bound the same way but distorts the answer more, and the current value is
already only "very nearly" shortest, which callers compensate for with a
tolerance); dropping the model (rejected outright — it is the floor a refusal
rests on).

## Avoidance strength study (§12, §13, §14)

150 real strong-avoidance calls, sampled evenly through the corpus so they are
not all easy first legs, each re-asked at six multipliers. Identity is the
engine's own edge-id sequence.

| multiplier | mean ms | mean visited | same path as 0.05 | mean distance m | mean overlap with avoided ground |
|---:|---:|---:|---:|---:|---:|
| 1.0 (no penalty) | 2.67 | 176 | 35.6% | 1,375 | 35.65% |
| 0.5 | 2.57 | 218 | 50.3% | 1,420 | 24.29% |
| 0.2 | 2.59 | 319 | 72.5% | 1,524 | 18.82% |
| 0.1 | 2.73 | 392 | 90.6% | 1,650 | 16.88% |
| **0.05** *(shipped)* | 2.61 | 468 | 100% | 1,750 | 16.05% |
| 0.02 | 2.93 | 626 | 94.0% | 1,940 | 14.87% |

The weakest multiplier that still returns the 0.05 path, per request:

| weakest that matches | requests | share |
|---|---:|---:|
| 1.0 — the corridor was never in the way | 53 | 35.6% |
| 0.5 | 22 | 14.8% |
| 0.2 | 33 | 22.1% |
| 0.1 | 27 | 18.1% |
| 0.05 — genuinely needs the full strength | 14 | 9.4% |

Three conclusions, and they do not point the same way.

**Penalty strength drives search cost exactly as the heuristic analysis
predicts.** 176 nodes at no penalty, 468 at 0.05 — a 2.66× increase, matching
the tightness collapse from 99.8% to 44.8%.

**And it costs nothing.** 2.67 ms against 2.61 ms. The 2.66× extra search work
is invisible, because the search is 4% of what Looper pays. This is the clearest
single demonstration in the phase that the node count and the latency are not
the same story.

**0.05 is doing real work and must not be weakened.** Mean overlap with ground
the walk has already covered more than doubles at multiplier 1.0 — 16.05% to
35.65% — and the walks get 21% shorter, which is a different walk, not a cheaper
one. Only 9.4% of requests strictly need 0.05, but the 35.6% that would be
unchanged cannot be identified in advance without routing them.

**§14 (adaptive avoidance) is rejected on this evidence, without prototyping.**
The scheme needs one cheap search to usually succeed and total wall time to
fall. The first half holds — 90.6% of requests would get their final path at
0.1. The second half fails at the premise: a 0.1 search is not cheaper (2.73 ms
against 2.61), so the best case saves nothing and every retry is a pure addition.
Building it could only make Looper slower.

## Candidate response-output cost (§18, §19, §20)

**What a corridor costs before any searching happens.** `ModelCost` times
`hopper.createWeighting` alone:

| class | weighting build, cache hit | cache miss |
|---|---:|---:|
| plain | 0.004 ms | 0.004 ms |
| avoid-strong | 0.224 ms | 0.655 ms |
| avoid-relaxed | 0.187 ms | 0.587 ms |

`CustomModelParser` caches the compiled class, but the key is
`CustomModel.toString()`, which includes `areas` — and `JsonFeature.toString()`
prints the full geometry. Looper's corridors are different on nearly every call
by construction, so the key is different too. In practice 730 of the 1,495
avoidance calls in one generation carry a model no other call carries, and 765
repeat one (though only 6.4% of all calls repeat a whole request, endpoints
included — see Phase 3 below): **about 650 ms of weighting construction across the corpus**, of
which roughly 0.22 ms per call is preparing the polygons (paid on hit and miss
alike) and roughly 0.43 ms is compiling a class that will be used once.

That makes turning the custom model into a weighting **the single largest
in-engine cost of Looper's workload — larger than the graph search** (~650 ms
against ~507 ms). It is not a defect in GraphHopper: the cache is doing what a
correctness-preserving cache must, since two models with different areas are
different models. It is a consequence of Looper handing the engine a freshly
drawn polygon set on every call.

**What the response costs.** Whole corpus, in-JVM, and the serialization timed
separately:

| response asked for | in-JVM ms | serialize ms | routes |
|---|---:|---:|---|
| what Looper asks for today | 2,260 | 121 | reference |
| no instructions | 2,109 | 63 | identical |
| `edge_id` only, no `street_name`/`road_class` | 2,196 | 90 | identical |
| geometry + `edge_id`, no instructions or names | 2,102 | 60 | identical |
| no details, no instructions, no geometry | 2,033 | 9 | (no geometry) |

**Which of these Looper could actually defer, traced to the consumer:**

| what Looper asks for | who reads it | deferrable? |
|---|---|---|
| `instructions` | `quality.ts` counts u-turns from `maneuverSigns` on **every** candidate, and that gate decides whether a candidate is offerable at all | **no** — load-bearing during generation |
| `edge_id` | `edges.ts` measures physical retracing and route-to-route overlap on every candidate | **no** |
| `street_name` | only `generate.ts` at the three places a route is *offered* — three candidates in roughly twenty-four | **yes** |
| `road_class` | only `pavementReport`, a diagnostic counter | **yes** |

So the deferrable part is exactly the `edge-id-only` row: **64 ms of GraphHopper
time and 31 ms of serialization across a whole corpus**, about 1.3% of
GraphHopper's work, which is 0.25% of Looper's. It would also shrink the 11.45
MB of response bytes Node parses. Measured, and **not recommended**: it splits
one request shape into two, and a two-shape request path is a place for a bug to
live, in exchange for half of one percent.

The finding that matters here is the negative one: **instructions cannot be
deferred**, because the u-turn count gates candidate selection. The brief
suggested deferring "until the final three routes have been selected"; that
would change which three get selected.

**Where the time is, broken down** (whole corpus, in-JVM, GraphHopper's own
stopwatches where it keeps them):

| phase | ms | note |
|---|---:|---|
| custom weighting construction | ~650 | measured separately; the largest item |
| graph search | 507 | `<algo>-routing`, quantised to whole ms, so a floor |
| algorithm set-up (`algoInit`) | 53 | includes building the LM approximator |
| snapping, query graph, path extraction, details, instructions | ~1,050 | the balance; apportioned by the response-shape rows above |
| **`hopper.route` total** | **2,261** | |
| response serialization to JSON | +121 | measured outside `route`, so not in the total above; `points_encoded: false` is the expensive branch |

## Full benchmark (§25, §26)

| stage | what it was | verdict |
|---|---|---|
| P0 | Phase 1 baseline, 16/8 | 2,294 ms |
| P1 | active-landmark tuning, 1→16 | no effect beyond noise; **rejected** |
| P2 | prepared-landmark tuning, 16/32/64 | +0.7% end-to-end; **rejected** |
| P3 | algorithm and LM-disable selection per class | LM wins or ties everywhere in production; **rejected** |
| P4 | dedicated lower-bound profile | −25% on a class with zero calls; **banked, not shipped** |
| P5 | avoidance penalty strength | strength drives nodes, not time; **no change** |
| P6 | deferring path details | 0.5% of Looper's time; **rejected** |
| P7 | best retained combination | there is nothing to retain |

| fixture | Phase 1 | best Phase 2 | improvement | route quality changed? |
|---|---:|---:|---:|---|
| douglas-5km | 368 | 358 | 2.7% | no |
| douglas-3km | 217 | 215 | 0.9% | no |
| peel-5km | 652 | 631 | 3.2% | no |
| onchan-5km | 192 | 161 | 16.1% | no |
| wp-one | 121 | 123 | −1.7% | no |
| wp-two | 744 | 745 | −0.1% | no |
| **total** | **2,294** | **2,233** | **2.7%** | **no** |

That table is the noise floor, not a result: it is **the same engine measured
twice**. It is printed here because it is the only fair yardstick for the +0.7%
the 64-landmark engine scored, and it is what justifies calling every
engine-level effect in this phase unmeasurable end-to-end.

Engine-call count is reported and never asserted, as in Phase 1:
`diversityAwareEarlyStop` races concurrent candidates, and `peel-5km` gave
743–779 calls across runs while returning byte-identical walks every time.

## Route equivalence

Every configuration in this phase was checked by a fingerprint over the full
`edge_id` sequence of all 1,863 calls — a stronger check than distance or a
geometry hash, because it says the searches agreed on the same physical network
edges and not merely on a length.

**Path-identical** (fingerprint `1870f0e9ee1b1ff0` throughout): all seven active
counts against all three preparations; `astar`, `astarbi` and the default;
`lm.disable`; `dijkstrabi`; every response-shape variant that still asks for
`edge_id`; and the dedicated lower-bound profile against the request model
(`1375ccf1edc3fe54` on both sides).

**Functionally equivalent, not bit-identical:** the response-shape rows that
drop `edge_id` change the fingerprint by definition — they were checked on
distance instead, and matched.

**Route-changing:** only the avoidance-multiplier study, deliberately, and
nothing from it is proposed for adoption.

End-to-end, all six fixtures returned identical route counts, distances, quality
scores, repeated-ground fractions and geometry hashes on every engine tested.

## Remaining bottlenecks, ranked by measured end-to-end contribution

1. **Queueing behind Looper's own concurrency — 55%** of what Looper calls
   engine time. Six calls in flight against a limiter, so a call's measured
   latency is mostly a measure of the other five. This is not waste — it is what
   makes the suite take 2.3 s instead of 12 — but it does mean per-call latency
   cannot be improved by making calls faster, only by making fewer of them.
2. **The Node↔Java boundary — 26%.** 5.57 MB of request bodies and 11.45 MB of
   responses for 1,863 calls: 3.0 KB out and 6.3 KB back per leg, the outbound
   bulk being corridor polygons re-serialised on every call and the inbound bulk
   being coordinates as JSON number pairs. Phase 1 measured the same boundary
   from the other side and reached the same conclusion.
3. **Custom weighting construction — 5%** of Looper's engine time, but 29% of
   GraphHopper's. Driven by corridor geometry entering a cache key, so it scales
   with how often Looper draws a new corridor rather than with graph size.
4. **The graph search — 4%.** The thing this phase was commissioned to optimise.
5. Response construction and serialization — ~2%, of which a quarter is
   deferrable and not worth deferring.

## Recommendation for Phase 3

**Optimise how Looper uses GraphHopper, not GraphHopper.**

Further engine tuning will not give large gains, and this phase can say so with
numbers rather than impressions: the entire span of every GraphHopper
configuration tested — from no heuristic at all to four times the landmarks — is
8% of GraphHopper's own time, which is 1.5% of Looper's, against a measurement
noise floor of 2.7%. There is no configuration left that could produce a
detectable end-to-end change.

The three places where Phase 3 could find real time, in order of measured size:

1. **Make fewer calls.** 1,863 engine calls across six requests, of which
   `join-pullback` alone is 422 and `leg-budget` 201 — 33% of all calls are
   fix-ups of legs that were already routed once. Every millisecond of the top
   two bottlenecks above is proportional to the call count and to nothing else.
2. **Reuse the corridor, not the answer.** Two duplication rates were measured
   inside a single generation and they are very different numbers:

   | duplicated | share of calls | what it would buy |
   |---|---:|---|
   | the custom model (same corridors, any endpoints) | **51%** | a compile and a polygon preparation, ~0.4 ms each |
   | the whole request (same corridors *and* same endpoints) | **6.4%** | the entire call |

   So a memo cache on the request is worth 6.4% of calls and no more — worth
   having, not transformative. The larger number is about the *model*: half of
   all avoidance calls hand the engine a polygon set it has already compiled,
   and re-serialise it over the socket to do so.

3. **Make the boundary cheaper before making the engine faster.** That 51% is
   where the boundary and the weighting cost meet: 3.0 KB of corridor JSON
   written, sent, parsed and turned into prepared polygons, for a corridor set
   the engine saw a moment ago. Anything that lets a request *name* a corridor
   set rather than restate it attacks the two largest addressable items on the
   bill at once — and it is a Looper-and-facade change, not a GraphHopper
   change.

What this phase does **not** support is another round of engine configuration,
a fork, or a custom algorithm. GraphHopper is already answering Looper's
workload in about a fifth of the time Looper spends asking.
