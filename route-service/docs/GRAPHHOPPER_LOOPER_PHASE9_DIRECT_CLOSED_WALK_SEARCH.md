# GraphHopper / Looper Phase 9 — Direct Bounded Closed-Walk Search

## Decision

**B — STRUCTURALLY VIABLE, ENGINEERING NEEDED.**

Searching the walk works. A bounded beam search over the request-local
GraphHopper graph returns **12 of 12 offered routes on the normal ring,
including three at Peel**, with mean absolute distance error of 54 m against
Phase 3B's 216 m and Phase 8's 92 m, mean quality 73.2 against 67.6, repeated
ground 0.08% against 1.88%, and **zero GraphHopper routing calls**. The whole
ring costs 771 ms end to end — 105 to 371 ms per request — against Phase 3B's
1,622 ms and 978 calls.

Two things stop this being an unqualified A. Peak heap at the retained
operating point is 137 MB per request, because the prototype never frees a
state it has generated; and Douglas 5 km costs 345 ms of search, above the
300 ms guideline, on an unoptimised interpreted implementation. Both have
concrete fixes named in section 26, neither is a property of the formulation,
and no route-quality or coverage problem remains unsolved.

The Peel question is also settled, in the direction that matters. An oracle
search establishes that **exactly three** mutually diverse qualifying walks
exist at Peel — no more — so Phase 8's shortfall there was a search
formulation failure, not the topology refusing. Conclusion C does not apply to
any tested fixture.

Production is untouched and remains Phase 3B.

---

## 1. Phase 3B and Phase 8 reference

Production is unchanged:

```text
LOOPER_PULLBACK_REUSES_PREVIOUS=true
LOOPER_BACKTRACK_NEEDS_BUDGET=true
LOOPER_BUDGET_ONCE_PER_LEG=true
ROUTING_CONCURRENCY=4
LOOPER_MODEL_REGISTRY=true
LOOPER_ROUTE_MEMO=true
```

There is no Phase 4 closure reserve, no Phase 5 full-shape controller, no
Phase 6 perimeter compensation on any production path, and
`LOOPER_PERIMETER_RETENTION` remains default OFF. GraphHopper, LM, avoidance
and waypoint semantics are untouched.

A fresh capture reproduces the reference exactly, to the call:

| fixture | wall ms | GH calls | builds | passes | offered |
|---|---:|---:|---:|---:|---:|
| douglas-5km | 476 | 238 | 24 | 5 | 3 |
| douglas-3km | 184 | 96 | 24 | 4 | 3 |
| peel-5km | 741 | 530 | 24 | 5 | 3 |
| onchan-5km | 221 | 114 | 24 | 4 | 3 |
| wp-one | 146 | 34 | 0 | 0 | 1 |
| wp-two | 800 | 285 | 24 | 5 | 1 |

```text
normal-ring completed candidates    108
passes                               19   (17.6%)
GraphHopper calls                   978
calls on rejected candidates        849
calls per passing candidate        51.5
offered routes                       12
```

Offered-walk quality, measured from this checkout rather than quoted: mean
absolute distance error 216 m, mean quality 67.6, mean repeated ground 1.88%,
one u-turn. Mean quality reproduces the Phase 8 report's figure to the decimal.

Phase 8's results are carried as quoted numbers, since nothing about the
pairwise-anchor generator was re-run: 11 of 12 offered, two at Peel, mean
absolute error 92 m, mean quality 73.8, repeated 0.00%, no u-turns, 924 routing
calls plus 64 probes, planned Peel polygon compactness 0.422 against realised
0.152.

---

## 2. Formal route objective (P1)

The objective is not restated in new terms. Every constraint below is read off
`src/loops/quality.ts`, and the search is judged by calling
`analyseRouteQuality` itself with no threshold relaxed.

### Hard constraints

```text
closure          the walk starts and ends at the routing start
walkability      every edge is accessible under the foot profile weighting
distance         |actual - target| <= MAX_DISTANCE_ERROR (0.12) x target
retracing        gate `out-and-back-spur`: a reverse retrace of any length
                 below MIN_BACKTRACK_METRES (500 m) is fatal, and the only
                 exemption is the EDGE_START_IGNORE_METRES (75 m) doorstep
                 window at either end
repeated ground  <= MAX_REPEATED_FRACTION (0.12) of the walk
u-turns          <= MAX_U_TURNS (1)
compactness      >= MIN_COMPACTNESS (0.20), gate `shapeless`
elongation       bounding-box ratio <= MAX_BOUNDING_BOX_RATIO (4.5)
doorstep stub    <= max(MAX_START_STUB_METRES, 0.04 x distance),
                 gate `start-spur`
```

The retracing rule is the one that changes the shape of the search, and it is
worth stating in the form the search actually uses. Below 500 m, *any* reverse
retrace outside the 75 m doorstep window rejects the walk. On a physical
network that is equivalent to: **an admissible walk may not spend a physical
edge twice.** So the object being searched is a rooted circuit, optionally
reached through a doorstep stem of at most about 75 m — not an unbounded closed
walk, and not a mathematically simple cycle either. Section 4 measures that
this is exactly what the accepted walks are.

### Soft ranking terms

Looper's own `scoreRoute` weights, unchanged: overlap 0.35, closeness to target
0.25, shape 0.20, leg balance 0.10, simplicity 0.10. Diversity between offered
walks is `MAX_SHARED_FRACTION` (0.55) of shared ground under
`selectDiverseRoutes`, again unchanged.

One gate does not apply, and the reason is structural rather than a relaxation.
`leg-too-long` and `leg-too-short` are computed from `legDistances`, and a
directly searched walk has no legs: it was never cut into planned steps. The
gate already handles this case — a single-leg walk produces `legShares.length
<= 2`, and both rules are skipped. Nothing was disabled to arrange it.

---

## 3. Simple cycle versus closed walk (P2)

Three formulations were considered and the accepted walks decide between them.

| formulation | what it allows | verdict |
|---|---|---|
| simple cycle | no repeated vertex or edge | too strict: junction revisits are common and harmless |
| rooted closed walk with bounded repeated edges | any edge up to a budget | too loose: the gate rejects any reverse retrace under 500 m outright |
| stem + circuit + stem | a doorstep stem, then no repeated edge | **matches** |

Section 4 measures the stem. It is 4 m at median across the twelve offered
Phase 3B walks and never exceeds 61 m — comfortably inside the gate's own 75 m
doorstep window, which is why it costs nothing. Peel is the fixture that needs
it: the start there snaps 60.3 m outside the graph's 2-core, so a stem is
mandatory, and the 61 m median stem measured on Peel's offered Phase 3B walks
is that same 60 m stem, arrived at from the opposite direction.

The retained formulation is therefore **stem + edge-simple circuit + stem**,
with the stem bounded by the doorstep window rather than by a new constant.

---

## 4. Topology of successful existing Looper routes (P3)

Measured from the Phase 3B trace corpus with a passive tracing-only field
carrying each candidate's physical edge passes. Medians across the four normal
fixtures:

| group | walks | unique edges | edge passes | repeated m | repeated % | gate repeated % | max reuse | stem m | stem % | core m | compactness |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| offered | 12 | 140 | 142 | 102 | 2.77% | 1.44% | 2.0 | 4 | 0.10% | 4766 | 0.429 |
| passed | 19 | 139 | 142 | 104 | 2.43% | 1.78% | 2.0 | 7 | 0.15% | 4759 | 0.404 |
| rejected | 84 | 109 | 114 | 262 | 6.52% | 5.33% | 2.0 | 3 | 0.07% | 4194 | 0.151 |
| rejected: shapeless | 52 | 97 | 109 | 366 | 9.58% | 8.21% | 2.0 | 6 | 0.10% | 4168 | 0.114 |
| rejected: out-and-back-spur | 50 | 93 | 99 | 338 | 7.69% | 7.48% | 2.0 | 6 | 0.10% | 3893 | 0.138 |
| rejected: distance | 56 | 95 | 100 | 249 | 6.16% | 4.84% | 2.0 | 7 | 0.10% | 3672 | 0.171 |

Per fixture, offered walks only:

| fixture | walks | distance | unique edges | repeated m | repeated % | max reuse | stem m | stem % | core m | compactness | u-turns |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | 3 | 4933 | 213 | 11 | 0.22% | 2.0 | 4 | 0.07% | 4925 | 0.438 | 0.0 |
| douglas-3km | 3 | 2792 | 140 | 99 | 3.10% | 2.0 | 1 | 0.04% | 2790 | 0.419 | 0.0 |
| peel-5km | 3 | 4888 | 105 | 172 | 3.52% | 2.0 | 61 | 1.25% | 4771 | 0.260 | 0.0 |
| onchan-5km | 3 | 4874 | 98 | 264 | 5.42% | 2.0 | 43 | 0.88% | 4788 | 0.537 | 0.0 |

Distribution over the twelve offered walks:

```text
unique edges           min    64      p25    98      median   140      p75   149      max   213
edge passes            min    68      p25   101      median   142      p75   152      max   215
repeated metres        min     1      p25    24      median   102      p75   172      max   549
max edge reuse         min     2      p25     2      median     2      p75     2      max     2
reused edges           min     1      p25     2      median     3      p75     4      max     6
stem edges             min     0      p25     1      median     1      p75     1      max     4
stem metres            min     0      p25     1      median     4      p75    43      max    61
stem fraction %        min  0.00      p25  0.04      median  0.10      p75  0.88      max  1.25
compactness            min 0.257      p25 0.319      median 0.429      p75 0.448      max 0.588
bbox ratio             min 1.101      p25 1.240      median 1.354      p75 1.620      max 2.109
```

Three readings matter.

**An accepted Looper walk is very nearly edge-simple.** Unique edges 140 against
142 passes; three edges reused at median out of about 140; maximum reuse is
exactly 2 on every one of the twelve, never 3. That is a circuit with a handful
of doubled edges, not a closed walk that wanders.

**The doubled edges are mostly not retracing at all.** Most of them are the
seams where the Phase 3B generator joins one routed leg to the next, splitting
one physical edge across two passes; the gate's own measure charges 1.44%
against the raw 2.77%. The genuinely retraced ground is smaller still, and it
has to be: the `out-and-back-spur` rule makes any reverse retrace under 500 m
fatal, so an offered walk carries essentially none.

**The stem is a doorstep, not a structure.** Median 4 m, maximum 61 m, never as
much as 1.3% of the walk. There is no fixture where Looper's accepted answer is
"walk half a kilometre out, do a loop, walk back".

Rejected candidates separate cleanly on exactly these axes — compactness 0.151
against 0.429, gate repeated ground 5.33% against 1.44% — which is what makes
them usable as search constraints rather than as post-hoc tests.

---

## 5. Bounded search graph (P4)

The bound is derived, not chosen. Every node on a closed walk of length L is at
most L/2 from the start *along the walk*, so its shortest network distance from
the start is at most L/2. With the acceptance band's own ceiling that gives

```text
explorationShare = (1 + MAX_DISTANCE_ERROR) / 2 = 0.56
```

which is a general expression of the request's target and the gate's own
tolerance, with no fixture in it. This matters: Phase 7 and Phase 8 explored at
0.35 x target, and the offered Phase 3B walks at Peel reach 2,361 m from the
start — outside a 1,750 m field. A walk search at the Phase 8 bound could not
have found the walks Looper already offers.

Two exact reductions are then applied to the exported subgraph.

**The 2-core.** A circuit cannot enter a dead end and come back out without
retracing that edge in reverse, which section 2 shows is fatal. Every leaf can
therefore be peeled, repeatedly, without removing one admissible walk. What is
peeled is kept, because the doorstep stem may run through it.

**Degree-2 contraction.** A chain of degree-2 junctions offers no choice:
entering it determines everything until the next real junction. Each chain
becomes one super-edge carrying its own metres, its geometry and the physical
edge ids beneath it, so repeated-ground accounting is unchanged and search
depth falls by the length of the chains.

Both reductions are correctness-preserving, and section 6 checks that claim
against the walks Looper already offers rather than asserting it.

---

## 6. Graph size and cost per fixture (P4)

| fixture | limit m | raw nodes | raw edges | 2-core nodes | 2-core edges | search nodes | search arcs | export ms | build ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | 2800 | 6586 | 8542 | 5317 | 7273 | 3006 | 9924 | 7.66 | 16.1 |
| douglas-3km | 1680 | 4395 | 5868 | 3710 | 5183 | 2189 | 7324 | 4.26 | 15.5 |
| peel-5km | 2800 | 1401 | 1733 | 1001 | 1333 | 596 | 1856 | 1.14 | 2.2 |
| onchan-5km | 2800 | 3927 | 4816 | 2835 | 3724 | 1554 | 4886 | 3.58 | 5.0 |

The reductions remove 54–57% of the nodes and 39–46% of the edges. Export is
GraphHopper's own bounded exploration, warm median of seven, and costs 1.1–7.7
ms. The search-graph build is 2–16 ms of TypeScript.

Transfer across the Node ↔ Java boundary is not free and is not hidden: the
exported subgraph with full edge geometry is 0.23–0.97 MB per fixture and
parses in about 3 ms. It is included in the totals in section 18.

**Does the reduced graph still contain the walks Looper offers?**

| fixture | offered walks | distinct edges used | in exported region | in 2-core | max network distance of a walk edge |
|---|---:|---:|---:|---:|---:|
| douglas-5km | 3 | 627 | 627 (100.0%) | 627 (100.0%) | 2201 m |
| douglas-3km | 3 | 427 | 427 (100.0%) | 427 (100.0%) | 1241 m |
| peel-5km | 3 | 330 | 330 (100.0%) | 324 (98.2%) | 2361 m |
| onchan-5km | 3 | 262 | 262 (100.0%) | 262 (100.0%) | 2264 m |

Every edge of every offered walk survives the bound. The six Peel edges outside
the 2-core are exactly its doorstep stem: Peel's start snaps 60.3 m outside the
core, and section 4 independently measures a 61 m median stem on Peel's offered
walks. The two measurements are of the same 60 m of pavement, and they agree.

Where the start sits:

```text
douglas-5km   in the 2-core        stem 0.0 m
douglas-3km   in the 2-core        stem 0.0 m
peel-5km      outside the 2-core   stem 60.3 m to node 19794
onchan-5km    in the 2-core        stem 0.0 m
```

---

## 7. Lower-bound pruning design (P5)

The exported field carries every settled node's shortest network distance from
the routing start. Because the exploration is Dijkstra on metres and any path
shorter than the bound lies inside the explored region, that value is the
**exact** shortest walkable distance home, not an estimate of one. So

```text
minimumFinalDistance = distanceUsed + home[node]
```

is a true lower bound on anything the partial walk can still finish at, and a
state failing

```text
minimumFinalDistance <= maxMetres
```

can be discarded without losing a single admissible walk. It is tight as well
as safe: the bound is achieved whenever the shortest way home happens not to
reuse an edge already spent.

No upper reachability bound is used. A partial walk can always be extended by
detouring, so there is no sound rule that says a state can no longer *reach*
the target — only ranking terms that prefer states which can. The search
therefore prunes only on the two exact conditions: a physical edge already
spent, and the distance lower bound. Everything else that limits the search is
beam selection, which is approximate by construction and is declared as such in
sections 9 and 12.

Measured, at the retained operating point, per ring:

```text
pruned on the distance lower bound     10,415 states
pruned as an edge already spent       406,110 states
```

---

## 8. Prototype S1 — bounded depth-first (P6)

Exhaustive depth-first, bounded only by the two exact prunes, with an expansion
budget as the instrument rather than as a bound on the problem.

| fixture | budget | states expanded | states generated | pruned: distance | pruned: reuse | depth reached | closed walks | ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | 2,000,000 | 2,000,000 | 2,000,000 | 1,479,391 | 3,280,495 | 214 | **0** | 564 |
| douglas-3km | 2,000,000 | 2,000,000 | 2,000,001 | 1,123,233 | 3,746,945 | 142 | **0** | 306 |
| peel-5km | 2,000,000 | 2,000,000 | 2,000,002 | 1,155,043 | 2,952,001 | 121 | **0** | 294 |
| onchan-5km | 2,000,000 | 2,000,000 | 2,000,001 | 810,828 | 3,434,876 | 148 | **0** | 419 |

S1 finds nothing anywhere, and the reason is visible in the depth column: it
descends 121–214 super-edges into one corner of the graph and never comes back.
Two million expansions is roughly 15 states per super-edge in the search graph
and it does not close a single walk. This is the state explosion the brief
predicted, measured honestly rather than assumed: exhaustive search of
target-length circuits is not a practical formulation, and no amount of
expansion budget on this graph size changes that.

S1 is retained as a negative reference and is not a candidate.

---

## 9. Prototype S2 — beam over distance bands (P6)

The headline prototype. States are bucketed by distance travelled, bands are
processed in increasing order, and each band keeps the best `beam` partial
walks under a per-node cap and a diversity quota.

Bands are *drained* rather than visited once. Most super-edges are shorter than
a band, so expanding a band produces states belonging to the same band;
processing each band once would silently discard most of the search. Each pass
applies the beam to whatever is currently in the band, so the width still
bounds the work per pass. Termination is not in doubt: no walk may spend an
edge twice, so depth is bounded by the edge count.

Ranking a partial walk uses the cheapest honest proxy for the gate's own
compactness — close the walk with a straight line home and ask how round the
result would be:

```text
perimeter = drawnSoFar + max(0, home[node] - home[root])
area      = |running shoelace| / 2
shape     = 4 x pi x area / perimeter^2
shortfall = max(0, minMetres - (distance + home[node])) / target
promise   = shape - shortfall
```

Both terms are incremental. The shoelace is accumulated per super-edge from
precomputed contributions, so the compactness of a *completed* walk is exact
rather than approximate — it is the same quantity `compactness()` computes,
over the same geometry. This is the thing Phase 8 could not see, because it
never held a walk.

At the retained operating point (beam 300, band 100 m, per-node 3, quota on):

| fixture | closed walks | gate passes | pass rate | offered | expanded | generated | pruned: distance | pruned: reuse | pruned: beam | pruned: dominated | peak band | search ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | 188 | 156 | 83.0% | 3 | 133,194 | 277,911 | 4,527 | 171,882 | 144,147 | 75,841 | 2,970 | 290 |
| douglas-3km | 133 | 128 | 96.2% | 3 | 71,580 | 150,326 | 1,884 | 90,224 | 78,350 | 41,380 | 2,588 | 116 |
| peel-5km | 124 | 66 | 53.2% | 3 | 55,798 | 99,891 | 1,671 | 72,506 | 43,719 | 33,894 | 1,587 | 72 |
| onchan-5km | 142 | 141 | 99.3% | 3 | 62,143 | 115,143 | 2,294 | 76,459 | 52,416 | 28,998 | 1,626 | 94 |

Pass rate is 53–99% against Phase 3B's 17.6% and Phase 8's 19.8%. That is the
expected consequence of searching the object the gate judges: most of what the
gate tests is now enforced or ranked during the search rather than discovered
afterwards.

The residual rejections across the ring are `u-turns` 91, `start-spur` 5,
`shapeless` 1 — and nothing else. Distance never rejects a completed walk,
because the band is a completion condition. Retracing never rejects one,
because edge-disjointness is a hard constraint. The remaining u-turns are the
one gate the search does not model, and section 13 says what would fix it.

---

## 10. Prototype S3 — cycle-core and stem model (P6)

The same beam, entered at every 2-core node within the doorstep allowance
rather than only at the nearest, with the width divided between entries.

| fixture | closed walks | gate passes | offered | expanded | search ms |
|---|---:|---:|---:|---:|---:|
| douglas-5km | 140 | 90 | 3 | 131,236 | 287 |
| douglas-3km | 358 | 317 | 3 | 75,549 | 132 |
| peel-5km | 214 | 116 | **2** | 58,811 | 74 |
| onchan-5km | 100 | 68 | 3 | 65,689 | 117 |

S3 offers 11 of 12 and is worse than S2 on quality (67.1 / 74.8 / 67.5 / 63.5
against 73.5 / 75.4 / 66.2 / 77.8) and on distance error at three of four
fixtures. It also picks up rejection classes S2 does not have —
`out-and-back-spur` 19 and `start-spur` 11 across the ring — which is exactly
what a longer stem buys: past the 75 m doorstep window, stem metres become
reverse retracing and the gate charges for them.

That is the useful finding, and it is a measurement rather than an assumption.
The stem allowance is not a free parameter: the gate's doorstep exemption is
75 m, and entries beyond it are rejected for the retracing the stem itself
creates. Splitting a fixed beam width between entries also costs more than the
extra entries return. **S3 is rejected**, and the single-root formulation of S2
— which already handles Peel's mandatory 60 m stem — is retained.

---

## 11. Prototype S4 — meeting frontiers (P6)

One beam grown to roughly half the target; every pair of partial walks ending
on the same node considered as a closure, admissible only where the two spend
no physical edge in common.

| fixture | meeting nodes | pools with 2+ | pairs tried | out of band | overlapping | joined |
|---|---:|---:|---:|---:|---:|---:|
| douglas-5km | 634 | 603 | 3,498 | 0 | 3,498 | **0** |
| douglas-3km | 362 | 342 | 4,862 | 0 | 4,862 | **0** |
| peel-5km | 252 | 243 | 1,668 | 0 | 1,668 | **0** |
| onchan-5km | 363 | 336 | 3,628 | 0 | 3,628 | **0** |

S4 finds nothing, and it is worth being precise about why, because the first
reading was wrong. Distance is never the problem — not one pair falls outside
the band. Every single pair shares an edge. Two fixes were applied before the
result was accepted: the same compass-octant diversity quota S2 uses, and a
limit of two half-walks per family on any meeting node, after the first
diagnosis showed pools filled with near-identical variants sharing 67 of 71
edges. Both raised the number of pairs considered and neither produced a join.

The structural reason is that S4 asks for more than S2 does. S2 needs *one*
path to survive the beam; S4 needs *both halves of the same walk* to survive it
independently and then meet. Every closed walk S2 finds decomposes into two
disjoint halves, so the walks exist in the graph — the beam simply does not
keep both halves of any of them. **S4 is rejected.**

---

## 12. State dominance strategy (P7)

Two approximations limit the search, and both are declared.

**Per-node cap.** At most `perNode` survivors may sit on one node within a
band. Two partial walks at the same node having travelled nearly the same
distance are close to interchangeable for everything downstream, and without
the cap one busy junction fills the beam with its own variants.

**Diversity quota.** The beam width is divided between the compass octants a
partial walk has committed to once it is clear of the door — the same
`INITIAL_BEARING_METRES` / `bearingOctant` axis `selectDiverseRoutes` judges
on. Unused quota is redistributed to the best states overall, so the quota
never wastes width.

Neither is a distance-bucket approximation: distances are exact throughout, and
bands are only a processing order.

| per-node cap | offered / 12 | closed walks | gate passes | expanded | search ms (ring) | mean quality | mean abs error |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 11 | 213 | 193 | 288,362 | 524 | 74.8 | 81 m |
| 2 | 12 | 428 | 375 | 311,591 | 554 | 73.3 | 86 m |
| **3** | **12** | **587** | **491** | **322,715** | **577** | **73.2** | **54 m** |
| 6 | 11 | 594 | 486 | 327,557 | 600 | 64.8 | 203 m |
| 12 | 11 | 723 | 634 | 347,585 | 597 | 68.5 | 137 m |

| diversity quota | offered / 12 | closed walks | gate passes | expanded | mean quality |
|---|---:|---:|---:|---:|---:|
| on | **12** | 587 | 491 | 322,715 | 73.2 |
| off | **7** | 618 | 529 | 318,309 | 74.9 |

The quota is the single most important setting in the phase, and it costs
nothing. Without it the search finds *more* passing walks and offers *fewer*
routes: at Douglas 5 km every one of 53 closed walks sat in one compass octant
and overlapped the best of them by 89% at minimum, so the offer selector could
only ever take one. Diversity has to be a property of the search, not a filter
applied to its output. Section 15 gives the full measurement.

---

## 13. Anti-retrace constraints (P8)

Phase 8's central failure was that good anchor geometry became an out-and-back
walk. In a direct search that failure is not detected late, it is
unrepresentable: a physical edge already spent is not offered as a move.

The rule is on physical edge ids, not on super-edges or graph edges, so a
contracted chain accounts for each real edge beneath it, and a `QueryGraph`
virtual edge accounts against the real edge it is a piece of. The doorstep stem
is the one exemption, and it is the gate's own 75 m window rather than a new
allowance.

Measured on the offered walks:

```text
repeated physical edge metres      0 m on 11 of 12 offered walks
mean repeated ground               0.08%   (Phase 3B 1.88%)
out-and-back-spur rejections       0 across the whole S2 ring
```

Section 4's expectations are met with room to spare: accepted Phase 3B walks
carry a median 1.44% of gate-charged repeated ground, and the searched walks
carry 0.08%.

What the search does **not** yet model is the u-turn rule, and it is the only
gate still rejecting completed walks (91 across the ring, and 4 u-turns survive
into the twelve offered against Phase 3B's 1). A u-turn here is not an edge
reversal — those are impossible — it is a walk going round a very small block
and coming back within 20 m of itself. The incoming and outgoing bearings of
every arc are already computed and carried; a turn-angle term in the ranking,
or a hard test against the last two arcs, is the obvious fix and is named in
section 26 rather than claimed here.

---

## 14. Shape state during search (P9)

Per super-edge, precomputed once in the start's local metric frame:

```text
twiceArea    shoelace contribution of traversing from -> to (negated reversed)
drawn        geometric length of the drawn line
minX/maxX/minY/maxY    bounding box
maxRadius    furthest point from the start
```

A state carries the running sums: shoelace, drawn length, bounding box,
maximum radius, distance and depth. Every one is a constant-time update per
arc, and nothing is recomputed over the walk.

This buys more than a proxy. Because the shoelace accumulates over the real
edge geometry, the compactness of a completed walk is **exact** — the same
number `compactness()` returns — so `shapeless` can be decided at the moment of
closure rather than after assembly. The bounding-box ratio is exact for the same
reason. Only the *partial* shape term is a proxy, and only for ranking.

The measured effect is in the rejection classes: `shapeless`, which was the
dominant Phase 8 rejection and 52 of 84 rejected Phase 3B candidates, rejects
**one** completed walk in the entire S2 ring.

---

## 15. Search diversity method (P11)

Families are compass octants of the bearing from the start, committed to once
the walk is `min(INITIAL_BEARING_METRES, 0.2 x target)` out — deliberately the
same axis and the same threshold the offer selector uses. Seeding families on
the first arc out of the door was tried first and is useless: the start snaps
mid-street on three of the four fixtures, so there are exactly two first arcs.

Beam width is divided between the families present in a band, with leftover
width going to the best states overall.

Octants reached by passing walks, and how much the second-best walk overlaps
the best:

| fixture | first-arc families | octant families | overlap with best: min | p25 | median |
|---|---|---|---:|---:|---:|
| douglas-5km | 6 (one octant only) | 1, 3, 4, 5, 6, 7 | 7.8% | 12.5% | 18.7% |
| douglas-3km | 3, 5 | 1, 3, 4, 5, 7 | 3.6% | 15.0% | 48.2% |
| peel-5km | 6 | 2, 5, 6 | 5.0% | 9.5% | 83.9% |
| onchan-5km | 0, 1, 5, 7 | 2, 4, 5, 6, 7 | 2.1% | 8.6% | 11.2% |

Worst physical overlap among the three offered walks is 21.4% / 48.8% / 38.5% /
31.4%, all inside the 55% bar, against Phase 3B's 37.8% / 25.8% / 28.0% /
17.4%. Phase 3B is more diverse at two fixtures and less at two; neither
generator is close to the bar.

Edge exclusion after accepting a route was not needed and was not implemented:
the quota produces separated walks in one pass, and re-running the search per
accepted route would multiply the cost.

---

## 16. Avoidance handling (P12)

Looper's 0.05 strong avoidance exists because the Phase 3B generator routes a
loop as a sequence of legs, and each leg has to be told not to walk back along
the ground the previous ones used. It is a soft, weighted approximation to a
constraint.

A direct search does not need the approximation, because it enforces the
constraint exactly. Edge-disjointness is what avoidance is *for*, applied to
the whole walk at once rather than leg by leg, and applied as a hard rule
rather than as a 20x weight multiplier that a determined shortest path can
still pay. The measured outcome is the point:

```text
mean repeated ground, Phase 3B offered walks   1.88%
mean repeated ground, Phase 9 offered walks    0.08%
```

with no avoidance model constructed, no corridor polygon built, and no custom
weighting compiled.

Between offered walks, separation is the diversity quota during the search plus
`selectDiverseRoutes` after it — the mechanism Looper already uses, unchanged.

The brief's warning — that a graph cycle ignoring avoidance may materialise
very differently once GraphHopper avoids previously walked corridors — is
measured rather than assumed, and it does not arise, because section 17
establishes that the retained walk is not re-routed at all. Nothing is handed
back to a router that could choose differently. **No second weighting system
was implemented, and avoidance was not weakened.** The existing avoidance
semantics remain exactly as they are on the Phase 3B path, which is still
production.

---

## 17. Graph-walk materialisation (P13)

A searched walk is already a real walk: every metre is a GraphHopper edge, its
line is GraphHopper's own geometry, and its length is the sum of those edges'
own distances. The question is what GraphHopper still has to be asked. Four
representations, twelve walks, judged by the same gate:

| representation | walks | via points | median \|routed − searched\| | median edge agreement | gate passes | median quality | median compactness |
|---|---:|---:|---:|---:|---:|---:|---:|
| **M0 searched walk, unrouted** | 12 | 0 | **0 m** | **100.0%** | **12/12** | **77.9** | **0.472** |
| M1 every junction as a via point | 12 | 83 | 21 m | 92.2% | 9/12 | 75.7 | 0.470 |
| M2 every fourth junction | 12 | 22 | 51 m | 65.5% | 3/12 | 70.7 | 0.466 |
| M3 three corners (Phase 8 control) | 12 | 5 | 1,486 m | 15.1% | **0/12** | 1.1 | 0.056 |

M3 is Phase 8's failure reproduced as a control, and it reproduces exactly.
Given three corners of a walk that is known to be good, GraphHopper returns
something 1,486 m from it at median, agreeing on 15% of its edges, with
compactness collapsing from 0.472 to 0.056, and not one of the twelve passes
the gate. Phase 8's Peel contrast — planned 0.422, realised 0.152 — is the same
measurement taken from the other side. Sparse anchors do not determine a walk.

The gradient through M1 and M2 makes the same point continuously: the more
freedom GraphHopper is given between fixed points, the less of the searched
walk survives, and the fewer walks pass.

**The retained method is M0: preserve the searched walk.** GraphHopper's data
produced it; it does not need to produce it again, and asking it to is the one
thing that reliably destroys it.

What that leaves for production is turn-by-turn instructions and duration,
which are not routing decisions. GraphHopper's library exposes the machinery to
build both from an edge sequence — the path, its instructions and its details
are constructed from edges, not re-searched — so this stays inside the Phase 1
rule that GraphHopper owns everything below Looper. It is engineering work in
the Java facade and is named as such in section 26; no instruction generation
was implemented in this phase.

---

## 18. Search time, states and memory (P14)

Every stage is counted, including preprocessing.

| fixture | subgraph export ms | transfer + parse ms | graph build ms | search ms | judge ms | **total ms** | states expanded | store entries | peak heap MB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | 7.66 | 3 | 16.1 | 290 | 54 | **371** | 133,194 | 277,915 | 137.0 |
| douglas-3km | 4.26 | 3 | 15.5 | 116 | 22 | **161** | 71,580 | 150,330 | 102.7 |
| peel-5km | 1.14 | 3 | 2.2 | 72 | 27 | **105** | 55,798 | 99,897 | 24.6 |
| onchan-5km | 3.58 | 3 | 5.0 | 94 | 29 | **134** | 62,143 | 115,147 | 46.2 |

GraphHopper routing calls: **0**. The only GraphHopper work is the bounded
exploration in the export column.

Beam width against cost:

| beam | offered / 12 | closed walks | gate passes | expanded | search ms (ring) | worst fixture ms | peak heap MB | mean quality | mean abs error |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 50 | 3 | 34 | 16 | 54,704 | 132 | 64 | 34.0 | 63.3 | 170 m |
| 100 | 11 | 166 | 151 | 107,197 | 200 | 91 | 47.9 | 65.5 | 176 m |
| 200 | 11 | 452 | 377 | 216,677 | 405 | 197 | 120.4 | 71.2 | 82 m |
| **300** | **12** | 587 | 491 | 322,715 | **577** | **290** | **137.0** | **73.2** | **54 m** |
| 600 | 11 | 776 | 631 | 615,051 | 1,123 | 564 | 212.5 | 75.2 | 76 m |
| 1200 | 11 | 818 | 678 | 1,167,171 | 2,366 | 1,250 | 351.4 | 75.4 | 105 m |

Band width:

| band | offered / 12 | expanded | search ms (ring) | peak heap MB | mean quality | mean abs error |
|---:|---:|---:|---:|---:|---:|---:|
| 50 m | 12 | 358,328 | 659 | 136.0 | 72.9 | 74 m |
| **100 m** | **12** | 322,715 | **577** | 137.0 | 73.2 | **54 m** |
| 200 m | 11 | 298,326 | 533 | 129.9 | 71.0 | 102 m |
| 400 m | 11 | 268,363 | 458 | 106.8 | 71.1 | 88 m |

Width is not free and more is not better: beam 600 and 1200 cost 2x and 4x and
offer *eleven*, because the extra width fills with walks the selector then
refuses. Beam 300 / band 100 m is retained, and the phase does not claim it is
optimal — only that it is the best of what was measured.

Memory is the honest weak point. 137 MB peak at Douglas 5 km is not a
per-request budget anyone would ship. The cause is not the algorithm: the
prototype pushes every generated state into one array and never frees it, so
643k state objects across the ring are retained for the whole search when only
the current and pending bands are live. Section 26 names the fix.

---

## 19. Route quality results (P15, P16)

Phase 3B's wall is the service's end-to-end response time; Phase 9's is the
full section-18 cost — export, transfer, graph build, search and gate.

| fixture | generator | offered | mean abs error | mean quality | mean repeated | u-turns | worst overlap | GH calls | wall |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | Phase 3B | 3 | 345 m | 69.3 | 0.27% | 0 | 37.8% | 238 | 476 ms |
| douglas-5km | Phase 8 (quoted) | 3 | 88 m | 72.7 | 0.00% | 0 | — | 225 | — |
| douglas-5km | **Phase 9 S2** | **3** | **29 m** | **73.5** | **0.00%** | 1 | 21.4% | **0** | **371 ms** |
| douglas-3km | Phase 3B | 3 | 206 m | 66.8 | 1.30% | 0 | 25.8% | 96 | 184 ms |
| douglas-3km | Phase 8 (quoted) | 3 | 122 m | 69.5 | 0.00% | 0 | — | 235 | — |
| douglas-3km | **Phase 9 S2** | **3** | **23 m** | **75.4** | **0.00%** | 1 | 48.8% | **0** | **161 ms** |
| peel-5km | Phase 3B | 3 | 103 m | 70.0 | 1.97% | 1 | 28.0% | 530 | 741 ms |
| peel-5km | Phase 8 (quoted) | **2** | 65 m | 76.5 | 0.00% | 0 | — | 212 | — |
| peel-5km | **Phase 9 S2** | **3** | 145 m | 66.2 | 0.33% | 2 | 38.5% | **0** | **105 ms** |
| onchan-5km | Phase 3B | 3 | 208 m | 64.4 | 3.97% | 0 | 17.4% | 114 | 221 ms |
| onchan-5km | Phase 8 (quoted) | 3 | 83 m | 77.4 | 0.00% | 0 | — | 252 | — |
| onchan-5km | **Phase 9 S2** | **3** | **17 m** | **77.8** | **0.00%** | 0 | 31.4% | **0** | **134 ms** |

Ring totals:

| generator | offered / 12 | mean abs error | mean quality | mean repeated | u-turns | GraphHopper calls | wall |
|---|---:|---:|---:|---:|---:|---:|---:|
| Phase 3B | 12 | 216 m | 67.6 | 1.88% | **1** | 978 | 1,622 ms |
| Phase 8 (quoted) | **11** | 92 m | 73.8 | 0.00% | 0 | 924 + 64 probes | — |
| **Phase 9 S2** | **12** | **54 m** | **73.2** | **0.08%** | 4 | **0** | **771 ms** |

Phase 9 is better than Phase 3B on coverage, distance, quality, retracing,
routing calls and wall time; better than Phase 8 on coverage and distance;
comparable to Phase 8 on quality and retracing. It is worse than Phase 3B on
u-turns — 4 against 1 — which is the gap section 13 identifies and section 26
proposes to close.

---

## 20. Peel results (P17)

Peel is the fixture the phase exists for, and it is now unremarkable.

```text
search graph        596 nodes, 1,856 arcs, after peeling and contraction
start               60.3 m outside the 2-core; a stem is mandatory
closed walks        124
gate passes          66   (53.2%)
offered               3
search time          72 ms
GraphHopper calls     0
```

The three offered walks are 5,111 m at median, mean absolute error 145 m, mean
quality 66.2, repeated ground 0.33%, worst mutual overlap 38.5%.

Against the two generators that came before: Phase 3B reaches three walks at
Peel by brute force, building 59 candidates and spending 530 GraphHopper calls
— more than half the whole ring's routing. Phase 8 reaches two, spending 212.
Phase 9 reaches three for 72 ms of search and no routing at all.

Peel is also where the phase's central claim is cleanest. Phase 8 planned the
roundest anchor polygons of all four fixtures at Peel (0.422) and walked the
least round routes (0.152). Phase 9 searches walks whose compactness it knows
exactly at the moment of closure, and Peel's offered walks come out at 0.328 —
above the gate's floor by construction rather than by luck.

It remains the hardest fixture, and the numbers say so: the lowest pass rate of
the four (53.2% against 83–99%), the largest distance error, the lowest
quality, and — per section 21 — the smallest supply of qualifying walks in the
ground. It is no longer the fixture that fails.

---

## 21. Oracle route availability (P18)

The brief is explicit that a search must not be blamed for failing to find
routes that do not exist. A deliberately expensive search — beam 2,000, band
50 m, per-node cap 6, no early stop, no compactness pre-filter, 0.7–3.0 s and
up to 1.6 GB per fixture — enumerates as many qualifying walks as it can, and
a greedy maximal selection under the production diversity rule counts how many
genuinely different ones the ground holds.

| fixture | closed walks | gate passes | **mutually diverse qualifying walks** | oracle search ms |
|---|---:|---:|---:|---:|
| douglas-5km | 562 | 550 | **7** | 3,003 |
| douglas-3km | 440 | 438 | **10** | 1,163 |
| peel-5km | 468 | 248 | **3** | 749 |
| onchan-5km | 497 | 497 | **8** | 881 |

**Three qualifying walks exist at Peel. Exactly three.** Phase 8's Peel
shortfall was a search formulation failure, not the network refusing.

Peel's three, in full:

| # | distance | error | quality | compactness | repeated % | u-turns | octant | worst overlap with the others |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 5,007 m | +0.1% | 79.4 | 0.482 | 0 | 0 | 6 | 52.1% |
| 2 | 4,602 m | −8.0% | 56.4 | 0.401 | 0 | 1 | 5 | 5.9% |
| 3 | 5,581 m | +11.6% | 50.1 | 0.466 | 0 | 1 | 6 | 52.1% |

The margins are thin and worth recording: the third walk sits at +11.6% against
a ±12% band, and two of the three share 52.1% of their ground against a 55%
bar. Peel has three loops and no fourth, and it very nearly has two. That is a
property of a town with a harbour, one bridge and a headland, and it is the
correct answer rather than a defect.

Note that S2 at the retained operating point offers three at Peel with
different walks and slightly worse individual quality than the oracle's best
three — the production-cost search finds a qualifying set, not the optimal one.

---

## 22. Constraint sensitivity (P19)

No fixture falls short of three, so this section is a margin measurement rather
than a diagnosis. The same enumerated walks, re-counted with one production
rule loosened at a time. **Nothing here was applied; all are analysis.**

| constraint | douglas-5km | douglas-3km | peel-5km | onchan-5km |
|---|---:|---:|---:|---:|
| current gate | 7 | 10 | **3** | 8 |
| distance band ±18% instead of ±12% | 7 | 10 | 3 | 8 |
| compactness floor 0.15 instead of 0.20 | 7 | 10 | 3 | 8 |
| u-turns up to 2 instead of 1 | 7 | 10 | **4** | 8 |
| shape rules set aside (essentials only) | 7 | 10 | **4** | 8 |

Only Peel moves at all, and only on the u-turn rule, which buys it a fourth
walk. The distance band and the compactness floor are not binding anywhere —
which is worth knowing, because both have been suspected in earlier phases. The
supply of walks at these four locations is set by the network and by the
diversity bar, not by the quality thresholds.

---

## 23. GraphHopper native round-trip and known approaches (P20, P21)

**GraphHopper's own `algorithm=round_trip` was tested first**, because Phase 1's
rule is that Looper does not reinvent what GraphHopper already has. It exists
in GraphHopper 11, it works under `ch.disable=true` with the foot profile, and
it is fast: 8 ms per call. Twelve seeds per fixture, judged by Looper's gate:

| fixture | routed | gate passes | offered | median distance | median \|error\| | median quality | median compactness | median repeated |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| douglas-5km | 12 | 1 | 1 | 4,252 m | 1,080 m | 12.6 | 0.021 | 6.60% |
| douglas-3km | 12 | 1 | 1 | 2,517 m | 483 m | 37.5 | 0.030 | 1.15% |
| peel-5km | 12 | 1 | 1 | 3,961 m | 1,767 m | 23.5 | 0.102 | 5.30% |
| onchan-5km | 12 | 3 | 2 | 5,512 m | 821 m | 39.8 | 0.025 | 3.25% |

Six of 48 routes pass; five of 12 routes could be offered. Median compactness
is 0.02–0.10 against the gate's 0.20 floor, and the dominant rejections are
`shapeless` (35 of 48) and `out-and-back-spur` (25 of 48). GraphHopper's
round-trip solves a different problem — a plausible circular detour — and does
not aim at a target length, a compactness floor or a retracing rule. It cannot
meet Looper's requirements, and no configuration of it was found that would.
The custom search is justified by measurement, not by preference.

Other approaches considered and not pursued:

- **Johnson-style and other exhaustive cycle enumeration.** Enumerates all
  simple cycles, which is exponential and not target-length-directed. S1's
  result is the same finding measured on this graph.
- **k-shortest cycles / cycle basis.** Minimises length; Looper needs a
  *specific* length with a shape constraint. The cycle basis of a 1,856-arc
  graph is far larger than the useful set and is not ordered usefully.
- **Resource-constrained shortest path / orienteering.** The closest fit in the
  literature, and S2 is essentially a beam-search heuristic for one: distance
  is the resource, compactness the collected prize. A full labelling algorithm
  with dominance was not needed once the beam met the coverage requirement, and
  is the natural next formulation if one is.
- **Alternative-route algorithms (plateau, penalty).** Built for distinct paths
  between two distinct points; a loop has one endpoint.

No library was imported. GraphHopper's own `BaseGraph`, `QueryGraph`,
`NodeAccess`, `EdgeExplorer` and profile `Weighting` supply everything the
search reads, exactly as Phase 7 established.

---

## 24. Comparison with Phase 3B and Phase 8

Section 19 carries the route-quality comparison. The structural comparison:

| | Phase 3B | Phase 7 | Phase 8 | **Phase 9 S2** |
|---|---|---|---|---|
| object chosen | bearing + corner geometry | shell anchors | pairwise-compatible anchors | **the walk** |
| offered routes | 12 / 12 | 7–9 / 12 | 11 / 12 | **12 / 12** |
| Peel | 3 (530 calls) | — | 2 | **3 (0 calls)** |
| candidate pass rate | 17.6% | 20.8–24.0% | 19.8% | **53–99%** |
| dominant rejection | distance (56) | scale | shape (`shapeless`, spur) | u-turns (91) |
| mean abs distance error | 216 m | 625–2,483 m | 92 m | **54 m** |
| repeated ground | 1.88% | — | 0.00% | 0.08% |
| u-turns across the ring | **1** | — | 0 | 4 |
| GraphHopper calls | 978 | 585–597 | 924 + 64 | **0** |
| ring wall time | 1,622 ms | — | — | **771 ms** |
| peak memory | negligible | negligible | negligible | **137 MB** |

The pattern across the three failed phases and this one is consistent. Phase 7
could not predict loop scale. Phase 8 predicted scale and could not predict
shape. Phase 9 does not predict either: it holds the walk, so scale is a
completion condition and shape is an exact running quantity. Every rejection
class those phases fought — `distance`, `shapeless`, `out-and-back-spur`,
`leg-too-short`, geometric retries, seam pullbacks — is either enforced during
the search or does not arise, and the one gate that still rejects anything is
the one the search does not yet model.

---

## 25. Retained and rejected code

Retained as analysis infrastructure:

- `LooperRoutingCore.exploreSubgraph` — the same bounded exploration as
  `explore`, keeping the induced edge set with metres, both traversal
  directions and geometry, and mapping virtual edges to the physical edge they
  are a piece of;
- `com.looper.routing.Subgraph` — the per-fixture exporter and its warm timing;
- `bench/phase9/graph.mts` — the 2-core peel, degree-2 contraction, stem
  reconstruction and search-graph build;
- `bench/phase9/search.mts` — the S1/S2/S3/S4 prototypes, the field lower-bound
  prune, the incremental shape state and the family-quota beam;
- `bench/phase9/walk.mts` — assembly of a searched walk into the line and edge
  spans the production gate consumes;
- `bench/phase9/topology.mts`, `validate.mts`, `analyse.mts`, `sweep.mts`,
  `oracle.mts`, `materialise.mts`, `roundtrip.mts`, `compare.mts`,
  `diagnose.mts`, `capture.mts` and their results;
- one passive tracing-only field on the `candidate` trace event carrying the
  physical edge passes of a completed candidate. It is computed only when
  `LOOPER_TRACE_FILE` is set and nothing in production reads it.

Rejected:

- **S1**, exhaustive depth-first: 2M expansions, zero closed walks, on every
  fixture;
- **S3**, multiple 2-core entries: 11 of 12, worse quality, and the extra stem
  metres are charged as retracing past the gate's 75 m doorstep;
- **S4**, meeting frontiers: zero joins on every fixture; every candidate pair
  shares an edge;
- **M1/M2/M3 materialisation**, re-routing the walk through via points: the
  more freedom GraphHopper is given, the less of the walk survives, and the
  Phase 8 three-corner control passes none of twelve;
- **GraphHopper's native `round_trip`**: 6 of 48 routes pass the gate,
  compactness 0.02–0.10;
- first-arc diversity families, superseded by compass octants;
- beam widths above 300 and bands above 100 m, which cost more and offer fewer;
- any Peel-specific sector, threshold, constant or bound.

Nothing was integrated into production. No flag was added; the name reserved
for one, should Phase 10 proceed, is `LOOPER_DIRECT_CLOSED_WALK_SEARCH`,
default OFF, with the Phase 3B generator retained for paired A/B testing (P22).
Waypoints were not addressed and remain entirely on the Phase 3B path.
GraphHopper, LM, avoidance, concurrency and every quality threshold are
unchanged, and the production baseline reproduces to the call after all of this
work.

---

## 26. Decision

**B — STRUCTURALLY VIABLE, ENGINEERING NEEDED.**

Route quality and coverage are solved, and by a clear margin:

```text
12 of 12 offered routes, Peel included
mean absolute distance error   54 m   (Phase 3B 216 m, Phase 8 92 m)
mean quality                   73.2   (Phase 3B 67.6, Phase 8 73.8)
repeated ground                0.08%  (Phase 3B 1.88%)
candidate pass rate            53-99% (Phase 3B 17.6%, Phase 8 19.8%)
GraphHopper routing calls      0      (Phase 3B 978)
ring wall time                 771 ms (Phase 3B 1,622 ms)
```

Three of four fixtures are inside the brief's "promising" envelope on their
own: 105, 134 and 161 ms end to end. Douglas 5 km is 371 ms, above it.

It is not classified A for two measured reasons, and the optimisation path for
each is concrete rather than hoped for:

**Memory — 137 MB peak.** The prototype pushes every generated state into one
array and never frees it. Only the current band and the pending bands are live;
completed bands are needed solely for parent-chain reconstruction, which needs
five numbers per state, not a JS object of twelve. Storing states as parallel
typed-array columns and releasing drained bands is a mechanical change with a
large, predictable factor.

**Search time — 290 ms at Douglas 5 km.** The search is interpreted TypeScript
holding a graph that was exported, serialised, transferred and re-parsed. The
same search inside the Java facade, over GraphHopper's own graph, skips the
export, the 0.97 MB payload and the graph rebuild — 27 ms of the 371 before
anything else is optimised — and runs against the same JIT that routes today.
The four family sub-searches are independent and the service already runs four
routing lanes concurrently.

Two smaller items belong in the same work:

**U-turns.** The only gate still rejecting completed walks (91 across the ring)
and the one axis where Phase 9 is worse than Phase 3B (4 against 1). Arc
bearings are already computed and carried; a turn-angle term in the ranking, or
a hard test against the last two arcs, closes it.

**Instructions and duration.** M0 keeps the searched walk, so nothing re-routes
it, but a walker needs turn-by-turn directions. GraphHopper's library builds
instructions and path details from an edge sequence without searching, which
keeps this inside the Phase 1 rule. It was not implemented here.

Waypoints are untouched and would need their own design: an ordered pin list is
a different object from a rooted circuit, and the Phase 3B path should remain
for them regardless of what happens to the ring generator.

---

## 27. Should routing research continue?

**Yes — but as engineering, not as research.**

The explicit STOP condition in the brief is not met. It asks whether direct
graph-space search can demonstrate a credible route-quality and coverage
solution, and the answer is measured: 12 of 12 with better distance, better
quality, less retracing, no routing calls and half the wall time, on a
formulation that also settles the Peel question the last two phases could not.
The brief's own instruction was to treat a well-supported negative as a
success; this is a well-supported positive, and the same standard applies.

What should **not** continue is the search for a better *heuristic*. Phases
4 through 8 all failed the same way — they optimised a proxy for the walk and
were beaten by the walk — and nothing in this phase suggests a ninth proxy
would do better. The recommendation is specifically not "keep researching
generation". It is:

1. **Phase 10 is engineering**, not investigation: move the search into the
   Java facade, replace the state store with typed-array columns and released
   bands, add the u-turn term, build instructions from the edge sequence, and
   put the whole thing behind `LOOPER_DIRECT_CLOSED_WALK_SEARCH` (default OFF)
   with a paired A/B benchmark against Phase 3B on the same six probes.
2. **Phase 3B stays.** It is production until the paired benchmark says
   otherwise, it remains the waypoint path regardless, and it is the fallback
   for any request the search cannot serve.
3. **The known unknowns are named**: waypoint requests, requests whose start is
   far from any 2-core, targets well outside 3–5 km, and denser city graphs
   than the Isle of Man offers. None was tested here.

If the Phase 10 engineering does not bring Douglas 5 km inside a few hundred
milliseconds at bounded memory, the correct answer is then to stop and keep
Phase 3B — the structural result would stand as a recorded finding rather than
as a reason to keep trying.

---

## Reproduction

From `route-service/`, with the settled GraphHopper facade on `:8991` and the
GraphHopper container on `:8989`.

```sh
# P0 - Phase 3B reference, and the corpus this phase reads
npx tsx bench/phase8/baseline.mts
npx tsx bench/phase9/capture.mts P9

# P3 - topology of the walks Phase 3B already offers
npx tsx bench/phase9/topology.mts P9

# P4 - bounded subgraph export, at (1 + MAX_DISTANCE_ERROR) / 2 of target
docker build -t looper-phase9 gh-harness
docker run --rm --entrypoint java \
  -v looper_graph-cache-iom:/data/graph-cache:ro \
  -v "$PWD/graphhopper:/gh:ro" -v "$PWD/bench/phase9:/work" \
  looper-phase9 -Xmx4g -cp /h/gh-harness.jar \
  com.looper.routing.Subgraph /gh/config.yml /data/graph-cache \
  /work/fixtures.json /work/subgraphs.json true

# P4 - search-graph reductions, and the check that they keep the offered walks
npx tsx bench/phase9/graph.mts
npx tsx bench/phase9/validate.mts

# P6-P11, P16 - prototypes S1-S4, the gate, diversity and the comparison
node --expose-gc --import tsx bench/phase9/analyse.mts
node --expose-gc --import tsx bench/phase9/compare.mts
npx tsx bench/phase9/diagnose.mts
S4_DEBUG=1 npx tsx bench/phase9/s4debug.mts

# P7, P14, P15 - cost, memory and dominance sweep
node --expose-gc --import tsx bench/phase9/sweep.mts

# P13 - materialisation, including the Phase 8 three-corner control
npx tsx bench/phase9/materialise.mts

# P18, P19 - oracle route availability and constraint sensitivity
node --expose-gc --import tsx bench/phase9/oracle.mts

# P21 - GraphHopper's own round-trip algorithm
npx tsx bench/phase9/roundtrip.mts

# verification
npm run typecheck
npm run lint
npm test
```

Primary generated artifacts:

```text
bench/phase9/corpus-P9/*.jsonl
bench/phase9/corpus-P9/offered.json
bench/phase9/subgraphs.json
bench/phase9/results/topology-P9.{md,json}
bench/phase9/results/offline.{md,json}
bench/phase9/results/compare.md
bench/phase9/results/sweep.{md,json}
bench/phase9/results/oracle.{md,json}
bench/phase9/results/materialise.{md,json}
bench/phase9/results/roundtrip.{md,json}
```

Environment knobs: `BEAM`, `BAND`, `PER_NODE`, `PER_FAMILY`, `WANTED`, `LABEL`
for the analyser; `ORACLE_BEAM`, `ORACLE_BAND`, `ORACLE_PER_NODE` for the
oracle; `SEEDS` for the round-trip comparison; `SAMPLE` for materialisation.
