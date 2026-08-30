# GraphHopper / Looper Phase 8 — Pairwise Topological Anchor Compatibility

## Decision

**Analysis NO-GO. Final classification: NO MATERIAL WIN — but a different
failure from Phase 7, and one that names the next problem precisely.**

Pairwise compatibility fixes what Phase 7 broke. Loop scale is now predicted
from anchor-to-anchor cost rather than assumed from a start shell, and the
scale error collapses: Phase 7's Douglas 5 km families missed target by 1,598
and 2,483 m at median, Phase 8 misses by 752 m, and its offered routes miss by
92 m at mean. Repair work falls further than Phase 7 managed — no geometric
retries at all, and join-pullbacks down from 1.90 to 1.01 calls per candidate.
Calls per passing candidate fall from 51.5 to 27.2.

It still does not clear the gate. Offered routes reach 11 of 12: Peel returns
two walks, not three. Candidate pass rate is 19.8%, not the required 30%, and
distance failures rise rather than fall by 35%. No production flag, integration
or paired benchmark was implemented.

The reason coverage fails is now measurable, and it is not distance. At Peel
the *planned* anchor polygon is the most compact of all four fixtures (0.422)
while the *routed* walk is the least compact (0.152). Three straight lines
between routable anchors do not determine the shape of the walk GraphHopper
returns. Anchor selection has been taken as far as it goes.

---

## 1. Phase 3B and Phase 7 baseline confirmation

Production is unchanged and remains Phase 3B:

```text
LOOPER_PULLBACK_REUSES_PREVIOUS=true
LOOPER_BACKTRACK_NEEDS_BUDGET=true
LOOPER_BUDGET_ONCE_PER_LEG=true
ROUTING_CONCURRENCY=4
LOOPER_MODEL_REGISTRY=true
LOOPER_ROUTE_MEMO=true
```

`LOOPER_PERIMETER_RETENTION` remains default OFF. There is no Phase 4 closure
reserve, no Phase 5 full-shape controller and no Phase 7 anchor family on any
production path. GraphHopper, LM, avoidance and waypoint semantics are
untouched.

A fresh capture reproduces the reference exactly:

| fixture | wall ms | calls | builds | passes | offered |
|---|---:|---:|---:|---:|---:|
| douglas-5km | 416 | 238 | 24 | 5 | 3 |
| douglas-3km | 149 | 96 | 24 | 4 | 3 |
| peel-5km | 569 | 530 | 24 | 5 | 3 |
| onchan-5km | 209 | 114–127 | 24 | 4–5 | 3 |
| wp-one | 140 | 34 | 0 | 0 | 1 |
| wp-two | 682 | 285 | 24 | 5 | 1 |

The normal-ring comparison set is reproduced to the call:

```text
completed candidates                 108
passes                                19   (17.6%)
GraphHopper calls                    978
calls on rejected candidates         849
calls per passing candidate         51.5
offered routes                        12
short / long / other                43 / 17 / 29
retries 213, leg-budget 110, pullback 205, spike 45, relaxed 2
```

Onchan varies between 114 and 127 calls across runs from candidate
concurrency races, as Phase 6 recorded; the tabled figures use the traced
capture.

Phase 7's families are retained as negative references: Family A 96 built, 23
passes, 585 calls, 434 rejected, 7 offered; Family B 96 built, 20 passes, 597
calls, 478 rejected, 9 offered. Their per-fixture median absolute distance
errors were 2,483 / 276 / 1,224 / 893 m (A) and 1,598 / 598 / 1,180 / 625 m
(B). Those numbers are the bar Phase 8's scale prediction has to beat.

---

## 2. Improved field seeding

Phase 7 seeded the bounded exploration at the nearer tower node of the snapped
edge, while a route starts at the `QueryGraph` virtual node. Phase 8 explores
the `QueryGraph` itself, so both endpoints of the snapped edge are entered at
their true partial-edge distance and the root of the tree is exactly where
routing begins. `LooperRoutingCore.explore` also keeps each settled node's
predecessor and the edge it arrived by, making the result a rooted
shortest-path tree rather than only a distance field.

Measured against plain GraphHopper routes to the same 32 pool anchors:

| fixture | nodes | edges | warm ms | median &#124;field − routed&#124;, virtual-node seed | same anchors, tower-node seed | median routed/field |
|---|---:|---:|---:|---:|---:|---:|
| douglas-5km | 4,521 | 12,263 | 4.01 | 17.7 m | 18.2 m | 1.015 |
| douglas-3km | 2,829 | 7,762 | 1.63 | 9.3 m | 9.4 m | 1.016 |
| peel-5km | 1,149 | 2,895 | 0.53 | 6.7 m | 6.7 m | 1.007 |
| onchan-5km | 2,120 | 5,245 | 1.05 | 0.0 m | 7.5 m | 1.000 |

The correction is real but small, and the honest reading is narrower than
Phase 7 assumed. It is worth 7.5 m at Onchan, where the request start snaps
mid-edge, and essentially nothing at Douglas and Peel, where the nearer tower
node was already within a metre. Phase 7's 216–365 m "first-leg field errors"
were therefore not caused by seeding; they came from its own anchor choice and
from leg-level effects. The cost is unchanged: 0.53–4.01 ms warm, one field
per request, reusable across every family.

The important number in that table is the last column. The field predicts what
GraphHopper will actually charge for `start → anchor` to within 0–1.6%. Every
first leg in the analysis is planned on this and lands within a few metres.

---

## 3. Anchor pool design

The pool is deliberately small, deterministic and request-scoped, and — the
point of the phase — it pins no shell. Anchors only have to *cover* the
plausible band widely enough for a sequence to be assembled at target scale;
which radius each one sits at is left to the sequence search.

```text
eligible = field nodes with
             degree >= 3
             network distance in [MIN_LEG_SHARE x target, field bound]
seed     = highest degree, nearest the band centre, lowest node id
then greedily add the node maximising its minimum spread to those chosen,
     spread = angular separation / 180 + 0.35 x radial separation
     subject to a crow-separation floor
```

Neither band edge is a new constant. The floor is the acceptance gate's own
`MIN_LEG_SHARE` — an anchor nearer than that can never be a legal corner — and
the ceiling is simply how far the field was explored. Where the network cannot
host `size` anchors at the separation floor, the floor is halved and halved
again rather than silently returning a short pool. The greedy is incremental,
so the first *K* entries are exactly the pool of size *K*; one probe capture
serves every size in the pool-size study.

| fixture | pool | 15° sectors | largest angular gap | network distance p10/median/p90 | median degree | median crow separation |
|---|---:|---:|---:|---:|---:|---:|
| douglas-5km | 32 | 20/24 | 45° | 421 / 913 / 1,621 m | 4 | 1,032 m |
| douglas-3km | 32 | 19/24 | 45° | 328 / 702 / 1,015 m | 4 | 730 m |
| peel-5km | 32 | 14/24 | 105° | 440 / 941 / 1,633 m | 3 | 852 m |
| onchan-5km | 32 | 21/24 | 30° | 471 / 1,143 / 1,722 m | 3 | 1,215 m |

Peel's 14 of 24 sectors and 105° gap reproduce Phase 7's finding on a
differently constructed pool. It is a property of the network.

---

## 4. Pool-size comparison

Cheap side (no routing), median absolute error of the predicted perimeter over
the sequences the search returns:

| fixture | 8 | 12 | 16 | 20 | 24 | 32 |
|---|---:|---:|---:|---:|---:|---:|
| douglas-5km | 276 m | 94 m | 87 m | 87 m | 60 m | 32 m |
| douglas-3km | 208 m | 115 m | 66 m | 47 m | 36 m | 30 m |
| peel-5km | 123 m | 211 m | 119 m | 163 m | 109 m | 64 m |
| onchan-5km | 446 m | 201 m | 77 m | 109 m | 66 m | 63 m |

Sequences and families rise with the pool and then saturate: Douglas 5 km
reaches 22 of 24 families at pool 20 and gains nothing after; Peel reaches 16
families only at pool 32 and never more.

Routed side, one sequence per family, whole normal ring:

| pool | fanout | built | passes | pass rate | calls | calls/pass | rejected calls |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 16 | 3 | 79 | 10 | 12.7% | 472 | 47.2 | 420 |
| 16 | 6 | 80 | 7 | 8.8% | 465 | 66.4 | 428 |
| 20 | 3 | 82 | 9 | 11.0% | 475 | 52.8 | 430 |
| 20 | 6 | 82 | 12 | 14.6% | 456 | 38.0 | 400 |
| 24 | 3 | 84 | 12 | 14.3% | 471 | 39.3 | 415 |
| 24 | 6 | 84 | 9 | 10.7% | 467 | 51.9 | 423 |
| 32 | 3 | 86 | 16 | 18.6% | 456 | 28.5 | 377 |
| 32 | 6 | 86 | 18 | 20.9% | 461 | 25.6 | 371 |

The expected too-small/too-large trade-off does not appear inside the range
tested: 32 is best on every column, and the pairwise cost it adds is
milliseconds, not calls. The binding constraint is not pool size, so the
analysis settles on pool 32 with fanout 6 rather than claiming an optimum.

---

## 5. Shortest-path-tree ancestry representation

Each settled node carries its predecessor and parent edge, so the field is a
tree rooted at the routing start. Ancestry between anchors A and B is read off
the two root paths:

```text
sharedMetres    network distance of the lowest common ancestor
divergence      that ancestor's node id
toA, toB        LCA to A, LCA to B
sharedFraction  2 x sharedMetres / (d(A) + d(B))
treeMetres      toA + toB
sharedEdges     length of the common parent-edge prefix, in edges
```

`treeMetres` is a genuine upper bound on the shortest *distance* between A and
B, because A → LCA → B is a real walkable path. It is not an upper bound on
what GraphHopper returns: the router minimises weight, not metres, and 325 of
the 1,984 sampled pairs route longer than their tree path.

---

## 6. Pairwise topology metrics

Stratifying all 1,984 probed pairs by shared ancestry:

| shared fraction | pairs | median routed/crow | median routed/tree | median crow | median shared corridor edges |
|---|---:|---:|---:|---:|---:|
| [0, 0.1) | 1,499 | 1.310 | 0.881 | 1,056 m | 1 |
| [0.1, 0.25) | 232 | 1.402 | 0.759 | 754 m | 7 |
| [0.25, 0.4) | 79 | 1.419 | 0.714 | 575 m | 14 |
| [0.4, 0.6) | 90 | 1.345 | 0.929 | 507 m | 17 |
| [0.6, 1.0] | 84 | 1.245 | 1.000 | 355 m | 26 |

By bearing separation:

| bearing separation | pairs | median routed/crow | median shared fraction |
|---|---:|---:|---:|
| [0°, 30°) | 381 | 1.348 | 0.281 |
| [30°, 60°) | 381 | 1.420 | 0.033 |
| [60°, 90°) | 328 | 1.369 | 0.005 |
| [90°, 120°) | 326 | 1.314 | 0.000 |
| [120°, 180°] | 568 | 1.261 | 0.000 |

Foot routes are symmetric: median |A→B − B→A| is 0.0 m.

**H3 is false in the regime that matters.** Shared start-tree ancestry moves
`routed/crow` from 1.25 to 1.42 across the whole range, and not monotonically:
the most ancestry-heavy bucket has the *lowest* ratio of the five, so a pair
that leaves the start down a shared corridor is not, on this evidence, a more
expensive loop edge. Worse, ancestry has no discriminating power over the
sequences actually built: because the pool already spreads anchors angularly,
the median shared corridor between the first and last anchor of a routed
candidate is 0 m at Douglas and Onchan and 6 m at Peel. Peel's
out-and-back-spur rejections have *less* shared ancestry than its
non-spurs (6 m against 60 m). Ancestry adds nothing beyond what angular
spread already provides, and no ancestry-based gate was retained.

---

## 7. Pairwise route sample analysis

The probe capture routes every anchor and every ordered anchor pair for a
32-anchor pool: 4,096 GraphHopper calls across the four fixtures, 5,970 ms of
boundary wall time. This is an analysis oracle, not a production cost; the
production design uses 16 pair probes per request and section 10 prices both.

The oracle exists to answer one question — which cheap feature predicts
whether A→B is a useful loop edge — and the answer is the plainest one
available. `routed/crow` is close to constant within a request — median 1.282,
1.295, 1.395 and 1.325 by fixture — and drifts only mildly with crow distance
(Douglas 5 km: 1.441 under 400 m falling to 1.227 over 1,500 m; Peel 1.416 to
1.364). It is the *level* of that ratio that separates the fixtures, not its
structure. That is what makes a handful of probes worth spending: they recover
the one number the field itself cannot supply.

---

## 8. Estimator results (E0–E3, plus E6)

Against actual pair routes, per fixture:

| fixture | estimator | median abs error | p75 | p90 | signed bias | median est/actual | Spearman ρ |
|---|---|---:|---:|---:|---:|---:|---:|
| douglas-5km | E0 crow | 289.5 | 438.5 | 638.5 | −289.5 | 0.780 | 0.942 |
| douglas-5km | E1 tree | 266.8 | 610.0 | 959.0 | +266.8 | 1.198 | 0.780 |
| douglas-5km | E2 bracket midpoint | 161.3 | 287.9 | 413.6 | −15.0 | 0.989 | 0.905 |
| douglas-5km | E2g bracket geometric mean | 153.7 | 249.5 | 367.1 | −48.2 | 0.964 | 0.939 |
| douglas-5km | E3 crow × field stretch | 103.1 | 188.3 | 357.6 | −63.2 | 0.946 | 0.942 |
| douglas-5km | **E6 crow × probed stretch** | 106.9 | 212.2 | 340.0 | +21.1 | 1.015 | 0.942 |
| douglas-3km | E0 crow | 217.9 | 315.4 | 414.9 | −217.9 | 0.772 | 0.962 |
| douglas-3km | E1 tree | 206.3 | 508.9 | 746.9 | +206.3 | 1.202 | 0.656 |
| douglas-3km | E2 bracket midpoint | 130.1 | 205.7 | 302.7 | −5.8 | 0.993 | 0.885 |
| douglas-3km | E2g bracket geometric mean | 123.1 | 177.9 | 246.3 | −37.2 | 0.952 | 0.940 |
| douglas-3km | E3 crow × field stretch | 71.0 | 129.9 | 241.4 | −64.2 | 0.927 | 0.962 |
| douglas-3km | **E6 crow × probed stretch** | 65.6 | 125.2 | 191.9 | +10.6 | 1.012 | 0.962 |
| peel-5km | E0 crow | 374.4 | 534.3 | 778.6 | −374.4 | 0.717 | 0.929 |
| peel-5km | E1 tree | 213.8 | 541.7 | 864.2 | +213.8 | 1.155 | 0.835 |
| peel-5km | E2 bracket midpoint | 148.1 | 236.5 | 342.5 | −71.1 | 0.936 | 0.935 |
| peel-5km | E2g bracket geometric mean | 151.3 | 248.2 | 362.5 | −117.9 | 0.899 | 0.958 |
| peel-5km | E3 crow × field stretch | 183.1 | 332.0 | 549.3 | −180.8 | 0.865 | 0.929 |
| peel-5km | **E6 crow × probed stretch** | 152.3 | 266.7 | 424.5 | +71.9 | 1.075 | 0.929 |
| onchan-5km | E0 crow | 408.9 | 553.1 | 711.2 | −408.9 | 0.755 | 0.960 |
| onchan-5km | E1 tree | 137.9 | 530.6 | 1,110.3 | +137.9 | 1.084 | 0.738 |
| onchan-5km | E2 bracket midpoint | 189.6 | 299.3 | 457.5 | −119.7 | 0.930 | 0.922 |
| onchan-5km | E2g bracket geometric mean | 194.7 | 284.5 | 376.4 | −148.0 | 0.914 | 0.960 |
| onchan-5km | E3 crow × field stretch | 122.7 | 226.0 | 369.9 | −81.9 | 0.941 | 0.960 |
| onchan-5km | **E6 crow × probed stretch** | 113.2 | 213.6 | 362.5 | −10.5 | 0.994 | 0.960 |

Definitions. E0 is crow distance. E1 is the start-tree distance
`d(A) + d(B) − 2·d(LCA)`. E2 is the midpoint of the proven `[crow, tree]`
bracket and E2g its geometric mean; neither is fitted. E3 scales crow by the
median network/crow ratio of the pool itself — free, request-scoped. E6 scales
crow by the median routed/crow ratio of 16 probed pairs.

Three results matter:

- **E1 is the worst-ranked estimator.** The tree distance carries the topology
  the phase was built around and it is the least useful of the six for
  ordering pairs (ρ 0.66–0.84 against 0.93–0.96 for crow). Loop-edge cost is
  a metric quantity, not a tree quantity.
- **Ranking is easy; level is not.** Plain crow ranks pairs almost perfectly
  (ρ ≈ 0.95) but is biased low by 22–28%. Everything useful an estimator does
  here is fixing that single multiplier.
- **Sixteen probes fix it.** E6 removes the bias almost exactly (est/actual
  0.994–1.075 against E3's 0.865–0.946) and is the best or near-best on p90
  everywhere. Peel benefits most: its true pair stretch is 1.50, which no
  field-derived value predicts.

E6 is the estimator the compatibility graph uses.

---

## 9. Sparse pair-probe strategy and compatibility graph design

Estimates are free once the stretch is known, so sparsity is not about which
pairs get a cost — it is about which pairs get a *probe*, and how large the
search stays.

**Probes.** Undirected pool pairs are sorted by crow distance and sampled at a
fixed stride to a budget of 16. The sample deliberately spans the crow range
rather than clustering, because the quantity being estimated is a ratio. The
probes buy one number, the request's routed/crow stretch, after which all 496
pool pairs are estimated for nothing.

**Graph.** Node = pool anchor. Directed edge = a plausible anchor-to-anchor
transition. An ordered pair is admissible in exactly one rotational sense, the
one in which it makes progress around the start, and each anchor keeps only its
best `fanout` successors by topological penalty:

```text
penalty =   2.0 x sharedFraction              shared start-tree ancestry
          + 0.5 x min(1, sharedEdges / 20)    shared physical corridor
          + 8.0 x max(0, 0.12 - crow/target)  anchors too close together
          + 1.5 if no rotational progress
          + angular gap from an even 120° three-corner spacing / 180
```

Each edge carries its features, its E6 estimate, its probed distance where one
exists, the cost actually used, and this penalty. At pool 32 and fanout 6 the
graph holds 356–384 directed edges against 992 ordered pairs. No all-pairs
matrix is built in the production design; the oracle capture that measures the
estimators is separate and separately priced.

---

## 10. Pair-probe cost

| fixture | pool | pool pairs | probes used | probed stretch | field stretch | oracle capture calls |
|---|---:|---:|---:|---:|---:|---:|
| douglas-5km | 32 | 496 | 16 | 1.301 | 1.213 | 1,024 |
| douglas-3km | 32 | 496 | 16 | 1.310 | 1.200 | 1,024 |
| peel-5km | 32 | 496 | 16 | 1.499 | 1.207 | 1,024 |
| onchan-5km | 32 | 496 | 16 | 1.317 | 1.247 | 1,024 |

Sixty-four probe calls across the ring, against 849 Phase 3B calls spent on
rejected candidates. Field exploration adds 0.53–4.01 ms per request; pool
selection is under 0.1 ms; compatibility construction 5.3–8.2 ms; sequence
search 7.9–17.4 ms. The preprocessing that Phase 7 could not afford — its
unoptimised selector cost 110–558 ms per family — is now 13–26 ms per request
in total, counted once and shared by every family.

---

## 11. Sequence-search design

```text
for each anchor A and rotation direction:
  for each admissible edge A -> B:
    for each admissible edge B -> C:
      predicted = field(A) + cost(A,B) + cost(B,C) + field(C)
```

`field(A)` and `field(C)` are the exploration's own network distances, which
section 2 showed predict routed spoke length to within 1.6%. Ranking is
distance-first —

```text
score = |predicted - target| / target + 0.02 x topology penalty
```

— so shape and topology are tie-breaks and never outbid scale.

Three hard gates are applied before a sequence is worth a GraphHopper call.
They are not new heuristics: `shapeless`, `leg-too-long` and `leg-too-short`
were the largest non-distance rejection classes in the first prototype, all
three are decidable from the anchor polygon and the predicted leg split, and
all three use the acceptance gate's own thresholds (`MIN_COMPACTNESS`,
`MAX_LEG_SHARE`, `MIN_LEG_SHARE`). Applying them to the plan cut `shapeless`
from 48 of 80 candidates to a minority of a larger set.

**Adaptive closure.** With all three anchors fixed, a candidate has no way to
correct scale once under way — the mirror image of Phase 7's failure. The
first two anchors are kept, and the closing anchor is re-picked from the same
pool after legs 1 and 2 have actually been routed, minimising
`|inflation × (cost(B,C) + field(C)) − remaining budget|` where `inflation` is
the ratio the legs already routed actually cost against their estimate. It
spends no extra GraphHopper call and the closing anchor changes on 112 of 172
candidates. A compounded variant, treating that ratio as a per-avoided-leg
factor, over-corrects and was rejected (28 passes against 34).

Four-anchor sequences were not tested. Three-anchor topology is not the
limitation; section 20 shows what is.

---

## 12. Predicted versus actual candidate distance

| fixture | routed | median predicted | median actual | median abs error | p75 | p90 | signed bias | median actual/predicted | predicted in ±12% / actual in band |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | 44 | 5,012 | 5,318 | 765 | 1,091 | 1,905 | −306 | 1.061 | 44 / 17 |
| douglas-3km | 48 | 2,992 | 3,263 | 447 | 693 | 1,033 | −277 | 1.093 | 48 / 20 |
| peel-5km | 32 | 4,980 | 4,764 | 494 | 772 | 1,188 | +236 | 0.951 | 29 / 17 |
| onchan-5km | 48 | 4,996 | 5,355 | 726 | 1,149 | 1,744 | −412 | 1.085 | 48 / 21 |

This is the first gate, and pairwise sequencing passes it against Phase 7:

| fixture | Phase 7 A | Phase 7 B | Phase 8 |
|---|---:|---:|---:|
| douglas-5km | 2,483 m | 1,598 m | 752 m |
| douglas-3km | 276 m | 598 m | 476 m |
| peel-5km | 1,224 m | 1,180 m | 500 m |
| onchan-5km | 893 m | 625 m | 671 m |

Against Phase 7's family A, median absolute candidate error improves by 70% at
Douglas 5 km and 59% at Peel — the two fixtures where Phase 7's wrong-scale
failure was total; against family B, by 53% and 58% — while
Douglas 3 km, the one topology Phase 7's quarter-shell happened to suit, gives
some back. The uniform overshoot of Phase 7 is gone.

The residual is legible. Per-leg, against a plain point-to-point estimate:

```text
leg 0 (avoids nothing)          ratio 1.000 - 1.009
leg 1 (avoids one leg)          ratio 0.867 - 1.064
leg 2 (avoids two legs)         ratio 0.855 - 1.272
leg 3, closing (avoids three)   ratio 1.093 - 1.243
```

Each leg avoids the ground already walked, so the later legs cost more than a
plain route between the same two points, and the closing leg costs most. The
adaptive closure measures that inflation from the legs in hand, but legs 0 and
1 under-report what legs 2 and 3 will pay. That is why 66 of 172 candidates
overshoot and only 31 fall short — the mirror of Phase 3B's 43 short against
17 long.

---

## 13. Pass rate, distance failures and repair

| fixture | generator | built | pass | pass rate | short | long | other | median abs error | calls | calls/pass | rejected calls |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | Phase 3B | 24 | 5 | 20.8% | 5 | 6 | 8 | — | 238 | 47.6 | 205 |
| douglas-5km | Phase 8 | 44 | 6 | 13.6% | 7 | 20 | 11 | 752 m | 225 | 37.5 | 194 |
| douglas-3km | Phase 3B | 12 | 4 | 33.3% | 4 | 2 | 2 | — | 96 | 24.0 | 72 |
| douglas-3km | Phase 8 | 48 | 14 | 29.2% | 7 | 21 | 6 | 476 m | 235 | 16.8 | 166 |
| peel-5km | Phase 3B | 59 | 5 | 8.5% | 31 | 6 | 17 | — | 530 | 106.0 | 492 |
| peel-5km | Phase 8 | 32 | 2 | 6.3% | 12 | 3 | 15 | 500 m | 212 | 106.0 | 201 |
| onchan-5km | Phase 3B | 13 | 5 | 38.5% | 3 | 3 | 2 | — | 114 | 22.8 | 80 |
| onchan-5km | Phase 8 | 48 | 12 | 25.0% | 5 | 22 | 9 | 671 m | 252 | 21.0 | 194 |
| **total** | Phase 3B | 108 | 19 | 17.6% | 43 | 17 | 29 | — | 978 | 51.5 | 849 |
| **total** | Phase 8 | 172 | 34 | 19.8% | 31 | 66 | 41 | 583 m | 924 | 27.2 | 755 |

Too-short candidates fall from 43 to 31 on a 59% larger candidate set — the
undershoot problem the handoff identified as 74% of Phase 3B's distance
failures is genuinely reduced. Too-long rises from 17 to 66, which is the
avoidance inflation of section 12 and not a scale-model failure.

Repair work:

| generator | candidates | calls/candidate | geometric retries | leg-budget | join-pullback | spike | relaxed | pullback/candidate | fix-up calls/candidate |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Phase 3B normal | 108 | 9.06 | 213 | 110 | 205 | 45 | 2 | 1.90 | 3.35 |
| Phase 7 family A | 96 | 6.09 | 0 | 35 | 161 | 5 | 0 | 1.68 | 2.09 |
| Phase 7 family B | 96 | 6.22 | 0 | 49 | 154 | 10 | 0 | 1.60 | 2.22 |
| Phase 8 | 172 | 5.37 | 0 | 46 | 173 | 17 | 0 | 1.01 | 1.37 |

Median endpoint miss is 0.0 m and median trim retention 0.993. Geometric
retries are gone, as in Phase 7, because anchors are real graph locations that
do not move. The new result is the pullback column: Phase 7 left seam
pullbacks at 1.6–1.7 per candidate and concluded H3 was only partly supported.
Pairwise-compatible anchors bring that to 1.01, a 40% reduction on Phase 7 and
a 47% reduction on Phase 3B, and total fix-up work per candidate falls 59%
against Phase 3B. Compatibility does reduce seam repair — but, per section 6,
through the rotational-progression and separation terms, not through shared
ancestry.

---

## 14. Rejected calls, calls per pass, calls per offered route

| generator | candidates | passes | calls | rejected calls | calls/pass | offered | calls/offered |
|---|---:|---:|---:|---:|---:|---:|---:|
| Phase 3B normal | 108 | 19 | 978 | 849 | 51.5 | 12 | 81.5 |
| Phase 7 family A | 96 | 23 | 585 | 434 | 25.4 | 7 | 83.6 |
| Phase 7 family B | 96 | 20 | 597 | 478 | 29.9 | 9 | 66.3 |
| Phase 8, one per family | 86 | 18 | 461 + 64 probes | 371 | 25.6 | 9 | 58.3 |
| Phase 8, two per family | 172 | 34 | 924 + 64 probes | 755 | 27.2 | 11 | 89.8 |

The two Phase 8 rows are the same generator asked for different coverage. One
sequence per directional family is the efficient operating point: rejected
calls fall 56.3% and calls per pass 50.3%, both past the gate's efficiency
thresholds, and calls per offered route are the best of any generator measured
in Phases 3B, 7 or 8. Two per family buys Peel's second walk and Douglas 5
km's third at the cost of that efficiency: rejected calls fall only 11.1%,
though calls per pass still improve 47.2%.

Neither row reaches 12 offered routes.

---

## 15. Peel topology

Peel is where the phase's conclusion is written.

| fixture | routed candidates | median planned polygon compactness | median realised compactness | shapeless | out-and-back-spur |
|---|---:|---:|---:|---:|---:|
| douglas-5km | 44 | 0.330 | 0.169 | 27 | 12 |
| douglas-3km | 48 | 0.328 | 0.258 | 13 | 4 |
| peel-5km | 32 | **0.422** | **0.152** | 23 | 22 |
| onchan-5km | 48 | 0.307 | 0.220 | 23 | 16 |

Peel plans the roundest loops of all four fixtures and walks the least round
ones. Every sequence routed there passed a hard `MIN_COMPACTNESS` gate on its
anchor polygon; 23 of 32 came back `shapeless` anyway, and 22 came back as
out-and-back spurs. Distance is no longer the problem — Peel's median absolute
error is 500 m, the second best of the four, and better than Douglas 5 km's.

The supporting structure is consistent with a genuinely thin network rather
than with a tuning failure: 14 of 24 sectors populated, a 105° angular gap,
16 of a possible 24 directional families with any admissible sequence at all
(Douglas and Onchan reach 22–24), the highest pair stretch of the four
fixtures at 1.40 routed/crow, and 1,149 field nodes against Douglas 5 km's
4,521. Phase 3B copes by brute force: it builds 59 candidates at Peel to pass
5, spending 530 calls. Phase 8 builds 32 for 212 calls and passes 2.

No Peel-specific sector, shell, threshold or constant was introduced, and none
should be. What Peel shows is general and appears in weaker form at Douglas 5
km and Onchan: the anchor polygon does not determine the shape of the walk.

---

## 16. Offered-route coverage, quality and diversity

| fixture | Phase 3B offered | Phase 8 offered | mean abs error | mean quality | mean repeated | u-turns | worst geometric overlap | worst physical overlap |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | 3 | 3 | 88 m | 72.7 | 0.00% | 0 | 35.6% | 13.8% |
| douglas-3km | 3 | 3 | 122 m | 69.5 | 0.00% | 0 | 26.4% | 22.6% |
| peel-5km | 3 | **2** | 65 m | 76.5 | 0.00% | 0 | 14.8% | 14.9% |
| onchan-5km | 3 | 3 | 83 m | 77.4 | 0.00% | 0 | 24.9% | 21.1% |
| **total** | 12 | **11** | 92 m | 73.8 | 0.00% | 0 | — | — |

Against the Phase 3B normal-fixture offering — 12 routes, mean absolute error
5.00% of target, mean quality 67.6, repeated ground 1.88%, one u-turn,
worst geometric overlap 37.8%, worst physical overlap 38.5% — the walks Phase
8 does offer are better on every axis. Mean absolute distance error is 92 m,
mean quality 73.8, repeated ground 0.00%, no u-turns, and worst physical
overlap 22.6%. Family diversity holds: 22–24 of 24 directional families carry
a sequence outside Peel, and 6–11 families produce a passing candidate.

But coverage is mandatory and it is 11, not 12.

---

## 17. Analysis GO / NO-GO gate

**NO-GO.**

| requirement | threshold | measured (two per family) | measured (one per family) | verdict |
|---|---|---|---|---|
| coverage | 3 routes on every normal fixture | 3 / 3 / **2** / 3 | 3 / 3 / **0** / 3 | **fail** |
| efficiency | rejected calls −40% **or** calls/pass −30% | −11.1% / **−47.2%** | **−56.3%** / **−50.3%** | pass |
| distance | distance failures −35% **or** pass rate ≥ 30% | +61.7% / 19.8% | −23.3% / 20.9% | **fail** |
| repair | fix-up work materially below Phase 3B | 1.37 vs 3.35 calls/candidate | 1.36 vs 3.35 | pass |
| quality | no material loss | improved on every axis | improved | pass |
| breadth | improvement across multiple fixtures | 3 of 4 fixtures | 3 of 4 | pass |

Two of the six requirements fail, and coverage is explicitly mandatory. The
structural-success classification is also unavailable, because it too requires
coverage to be restored. No production flag, integration, paired benchmark or
waypoint change was implemented.

---

## 18. Production design, if it had passed

Not implemented. Recorded only so the next phase does not have to re-derive
it. Had the gate passed, the path behind `LOOPER_PAIRWISE_ANCHOR_CANDIDATES`
(default OFF, Phase 3B generator retained for paired A/B testing) would have
been:

```text
request
  -> one bounded QueryGraph-seeded field, ~1-4 ms, reused by every family
  -> greedy 32-anchor pool, no shell pinned
  -> 16 pair probes to calibrate the request's routed/crow stretch
  -> sparse compatibility graph, fanout 6, ~380 directed edges
  -> distance-first sequence search behind the acceptance gate's own shape gates
  -> route the top sequence per directional family, re-picking the closing
     anchor from the routed legs
  -> normal Looper quality and diversity selection
```

No paired production benchmark was run, since nothing was integrated.

---

## 19. Retained and rejected changes

Retained as analysis infrastructure:

- `LooperRoutingCore.explore` seeded on the `QueryGraph` virtual node and
  returning shortest-path-tree predecessors and parent edges;
- the `NetworkField` exporter and the four measured fixture fields;
- `bench/phase8/field.mts` — field, tree ancestry, anchor pool, estimators;
- `bench/phase8/sequence.mts` — sparse compatibility graph and sequence search;
- `bench/phase8/probe.mts`, `analyse.mts`, `diagnose.mts`, `baseline.mts` and
  their results;
- the finding that the acceptance gate's own shape thresholds can be applied
  to a plan before routing it.

Rejected:

- production integration of the pairwise generator;
- start-tree ancestry as a compatibility signal (H3, measured false);
- the tree-distance estimator E1 as a ranking function;
- compounded per-avoided-leg inflation in the adaptive closure;
- an all-pairs compatibility matrix in the production design;
- any Peel-specific sector, shell, threshold or constant;
- reducing candidate count, avoidance, diversity or route count to pass;
- reintroducing Phase 4 closure reserve, Phase 5 full-shape control or Phase 6
  perimeter repayment.

Waypoints remain entirely on the Phase 3B path and were excluded from the
gate, as required. GraphHopper, LM, avoidance and concurrency are unchanged.

---

## 20. Final classification and Phase 9 recommendation

**NO MATERIAL WIN**, by the classification the brief defines: coverage is
mandatory for every passing grade including structural success, and Peel
returns two walks instead of three.

That label understates what changed, so the distinction should be carried
forward explicitly. Phase 7 failed because it could not predict loop scale.
Phase 8 predicts loop scale: all but three of the 172 ranked sequences plan
inside the ±12% band, median candidate error more than halves against Phase 7
on the two fixtures where Phase 7 collapsed, first legs land within 1.6% of their field estimate,
undershoots fall in absolute terms on a larger candidate set, seam pullbacks
drop 47% against Phase 3B, geometric retries reach zero, calls per offered
route reach the best figure measured in any phase, and the routes that do pass
are better than Phase 3B's on distance, quality, retracing and overlap.

What Phase 8 cannot do is predict the *shape of the walk*. The gate's shape
tests — `shapeless`, `out-and-back-spur` — are now the dominant rejection
class, and section 15 shows they are not predictable from the anchors:
Peel plans the roundest polygons of all four fixtures and walks the least
round ones. Three straight lines between routable points constrain where a
walk passes through, not what it looks like in between, and on a sparse
network the difference is total.

**Phase 9 should stop selecting anchors and start searching for the walk.**
The brief's fallback is the right one and the evidence now supports it
specifically rather than by elimination:

```text
bounded closed-walk / cycle search from the start node
target-length rooted cycles
cycle-basis and k-shortest-cycle variants
orienteering-style closed-walk generation
```

Such a search optimises the object the quality gate actually judges — the walk
— and can carry compactness, retracing and leg balance as search constraints
rather than as post-hoc rejections. Three Phase 8 assets transfer directly to
it and should not be rebuilt: the bounded `QueryGraph`-seeded field with its
shortest-path tree, which is cheap enough to run per request; the measurement
that a request's routed/crow stretch is a single number recoverable from ~16
probes; and the finding that the acceptance gate's own thresholds can be
evaluated on a plan before any routing call.

No tiny cycle-search feasibility experiment was run. The Peel compactness
contrast in section 15 explains the NO-GO on its own, and building even a
minimal cycle engine is Phase 9's work, not a footnote to this one.

GraphHopper should still provide every route.

---

## Reproduction

From `route-service/`, with the settled GraphHopper facade on `:8991`.

```sh
# P0 — Phase 3B reference
npx tsx bench/phase6/capture.mts P8
npx tsx bench/phase8/baseline.mts

# P1/P3 — field with virtual-node seeding and shortest-path-tree parents
docker build -t looper-phase8-field gh-harness
docker run --rm --entrypoint java \
  -v looper_graph-cache-iom:/data/graph-cache:ro \
  -v "$PWD/graphhopper:/gh:ro" -v "$PWD/bench/phase8:/work" \
  looper-phase8-field -Xmx2g -cp /h/gh-harness.jar \
  com.looper.routing.NetworkField /gh/config.yml /data/graph-cache \
  /work/fixtures.json /work/network-fields.json

# P4/P5 — anchor and all-pairs probe oracle
POOL=32 npx tsx bench/phase8/probe.mts

# P2, P6-P17 — headline analysis (pool 32, fanout 6, 16 probes, 2 per family)
npx tsx bench/phase8/analyse.mts

# efficiency operating point and the no-adaptive-closure control
PER_FAMILY=1 LABEL=per-family-1 npx tsx bench/phase8/analyse.mts
ADAPTIVE=false LABEL=static npx tsx bench/phase8/analyse.mts

# rejection-class diagnostics
npx tsx bench/phase8/diagnose.mts

# pool-size and fanout sweep
for P in 16 20 24 32; do for F in 3 6; do
  POOL=$P FANOUT=$F PER_FAMILY=1 POOL_SIZES=8 LABEL=sweep npx tsx bench/phase8/analyse.mts
done; done

# verification
npm run typecheck
npm run lint
npm test
```

Primary generated artifacts:

```text
bench/phase6/corpus-P8/*.jsonl
bench/phase8/network-fields.json
bench/phase8/results/probes-32.json
bench/phase8/results/offline.{md,json}
bench/phase8/results/offline-per-family-1.{md,json}
bench/phase8/results/offline-static.{md,json}
```
