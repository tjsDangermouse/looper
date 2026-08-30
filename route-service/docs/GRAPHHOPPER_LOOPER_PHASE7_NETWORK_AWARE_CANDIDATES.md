# GraphHopper / Looper Phase 7 — Network-Aware Candidate Family Construction

## Decision

**Analysis NO-GO. Final classification: NO MATERIAL WIN; infrastructure outcome B.**

Real graph anchors solve the narrow problem they should solve: median endpoint
miss falls from 58 m across the Phase 3B trace (and 192 m for Peel undershoots)
to 0.0 m. A reusable bounded field is also cheap: 0.56–3.33 ms warm for
1,149–4,520 nodes.

They do not solve loop construction. Network distance from the start does not
constrain network distance between anchors. Both prototypes usually build the
wrong scale, still trigger many seam pullbacks, and offer fewer routes than
Phase 3B. No production flag or integration was implemented.

## 1. Baseline confirmation

Production remains Phase 3B with the retained flags and GraphHopper settings
listed in the Phase 6 report. `LOOPER_PERIMETER_RETENTION` remains default OFF.
The repeated warm baseline is:

```text
wall time                     1,847 ms
GraphHopper calls                 1,297
candidate builds                    120
retained candidate passes            23
completed trace candidates           127
  passes                              24
  distance failures                  68 (48 short, 20 long)
  other quality failures             35
offered routes                       14
calls/passing retained candidate   56.4
calls/offered route                92.6
```

Passive Phase 6 tracing records 250 retry attempts, 129 leg-budget calls, 236
join-pullback calls, 46 spike calls, two relaxed calls, and a 58 m median guide
miss. Retention is 0.982 after leg 3 and 0.986 final for passes, versus 0.803
and 0.730 for undershoots.

For a like-for-like normal-ring comparison (excluding waypoints), Phase 3B has
108 completed candidates, 19 passes (17.6%), 978 calls, and 849 calls attached
to rejected candidates. Its calls include 213 retries, 110 leg-budget, 205
pullback, 45 spike and two relaxed routes.

## 2. GraphHopper graph-access investigation

The existing GraphHopper 11 library instance exposes all required read-only
structures without a fork:

- `GraphHopper.getBaseGraph()` supplies immutable nodes and edges;
- `LocationIndex.findClosest()` and the existing profile/snap-prevention filter
  snap the request start;
- `NodeAccess` supplies node coordinates;
- `EdgeExplorer` / `EdgeIterator` traverse adjacency and expose edge distance;
- the existing foot `Weighting` determines whether an oriented edge is
  accessible (`calcEdgeWeight` finite);
- `QueryGraph` is still appropriate for exact virtual snaps used by routing.

GraphHopper's standard server also has an SPT endpoint, already wrapped by
`GraphHopperClient.shortestPathTree`. The older `networkAwareSeeds` experiment
used that endpoint only to reorder geometric bearings and measured little net
benefit. Phase 7 therefore did not repeat that experiment.

A bounded Dijkstra-style exploration is cleanly possible as an analysis field.
It accumulates GraphHopper edge distances in metres, uses the profile weighting
only as the access filter, and returns graph locations; it does not calculate
or return a route. All candidate legs still go through GraphHopper's normal
router. One field is reusable across all 24 families in a request.

One limitation is explicit: the field starts from the nearer endpoint of the
snapped edge, whereas routing starts at the exact `QueryGraph` virtual node.
That produces first-leg field errors up to a few hundred metres on some
fixtures, despite zero endpoint miss. A production-quality field should seed
both edge endpoints with their partial-edge distances.

## 3. Bounded exploration design and cost

The analysis radius is `0.35 × targetDistance`, a generic fraction large
enough to cover both tested shell families. The queue settles nodes by
accumulated edge metres and stops at the bound. Each result contains node id,
coordinate, network distance and accessible degree.

After a discarded warm exploration, seven repeats give:

| fixture | target | bound | nodes | edges examined | median warm ms | median heap delta |
|---|---:|---:|---:|---:|---:|---:|
| Douglas 5 km | 5,000 | 1,750 | 4,520 | 12,261 | 3.33 | 832,400 B |
| Douglas 3 km | 3,000 | 1,050 | 2,828 | 7,760 | 1.48 | 732,728 B |
| Peel 5 km | 5,000 | 1,750 | 1,149 | 2,895 | 0.56 | 416,224 B |
| Onchan 5 km | 5,000 | 1,750 | 2,108 | 5,219 | 0.99 | 524,288 B |

The field itself is not the cost problem. Even Douglas is roughly 1% of its
347 ms request baseline. Reported heap delta is allocation pressure during one
exploration, not retained request cache memory.

## 4. Shells, sectors and anchor availability

Analysis shells are 5% of target (250 m at 5 km, 150 m at 3 km). Directional
availability is measured at 15° because production's 24 candidates require
that resolution; this is evidence for 24 sectors rather than an arbitrary
eight.

| fixture | populated shells | represented 15° sectors | largest gap | median degree |
|---|---:|---:|---:|---:|
| Douglas 5 km | 7 | 20/24 | 75° | 3 |
| Douglas 3 km | 7 | 24/24 | 15° | 3 |
| Peel 5 km | 7 | 15/24 | 105° | 3 |
| Onchan 5 km | 7 | 24/24 | 15° | 3 |

Peel's sparse angular coverage is a network fact, not a tuning target. The
105° gap warns that forcing uniform polygon corners there is structurally
unlikely to work.

Anchor ranking is deterministic:

```text
network-shell error
+ angular error from sector centre
- bounded accessible-degree preference
```

Nodes require degree at least two and each subsequent anchor must be at least
8% of target away in crow distance from earlier anchors. All fixtures supplied
three anchors for all 24 mirrored clockwise/counter-clockwise families.

The initial TypeScript selection is intentionally transparent rather than
optimised. Sorting all reachable nodes for every anchor costs 110–558 ms per
family/fixture. Shell/sector indexing would remove most of that cost, but the
candidate gate fails independently, so optimisation was not used to disguise
the result.

## 5. Anchor quality and displacement

Graph nodes are valid route endpoints. Across all 768 routed legs in both
families, median endpoint miss is 0.0 m. This confirms H1's displacement part.

| fixture | family | median start network/crow stretch | median first-leg field error | median anchor-to-anchor routed/crow |
|---|---|---:|---:|---:|
| Douglas 5 km | A / B | 1.23 / 1.25 | 21 / 34 m | 1.68 / 1.42 |
| Douglas 3 km | A / B | 1.23 / 1.26 | 216 / 17 m | 1.18 / 1.24 |
| Peel 5 km | A / B | 1.24 / 1.22 | 365 / 9 m | 1.26 / 1.48 |
| Onchan 5 km | A / B | 1.29 / 1.30 | 331 / 29 m | 1.31 / 1.26 |

The last column is the critical result: even when every anchor has a known
start distance, adjacent anchors have a different and variable network
relationship. Start shells alone do not define loop perimeter.

## 6. Candidate family A

Family A chooses three degree-2+ anchors at `0.25 × target` network distance
from the start, progressing 90° clockwise or counter-clockwise. It preserves
24 deterministic mirrored families and rejects physically close anchor pairs.

| fixture | built | pass | short | long | other | calls | calls/pass |
|---|---:|---:|---:|---:|---:|---:|---:|
| Douglas 5 km | 24 | 0 | 0 | 24 | 0 | 116 | — |
| Douglas 3 km | 24 | 15 | 1 | 7 | 1 | 149 | 9.9 |
| Peel 5 km | 24 | 1 | 7 | 12 | 4 | 172 | 172.0 |
| Onchan 5 km | 24 | 7 | 2 | 13 | 2 | 148 | 21.1 |
| **total** | **96** | **23 (24.0%)** | **10** | **56** | **7** | **585** | **25.4** |

The Douglas 3 km result proves anchor construction can work on a compatible
dense topology. Douglas 5 km proves the quarter-shell assumption is not a
scale law: every candidate overshoots, with 2,483 m median absolute error.

## 7. Candidate family B

Family B makes network shells explicit with side/outer/return fractions
`0.20 / 0.32 / 0.20`. It is a deliberately different deterministic family,
not a fitted fixture-specific correction.

| fixture | built | pass | short | long | other | calls | calls/pass |
|---|---:|---:|---:|---:|---:|---:|---:|
| Douglas 5 km | 24 | 2 | 0 | 20 | 2 | 147 | 73.5 |
| Douglas 3 km | 24 | 9 | 4 | 11 | 0 | 144 | 16.0 |
| Peel 5 km | 24 | 1 | 1 | 14 | 8 | 156 | 156.0 |
| Onchan 5 km | 24 | 8 | 2 | 11 | 3 | 150 | 18.8 |
| **total** | **96** | **20 (20.8%)** | **7** | **56** | **13** | **597** | **29.9** |

Changing shell proportions shifts which candidates fail but does not stabilize
scale. H2 is false for start-distance-only shells.

## 8. Scale retention and distance error

Graph-aware anchors retain the geometry they actually specify:

| family | median post-trim / pre-trim routed distance |
|---|---:|
| A | approximately 0.99 across fixtures |
| B | 0.979–0.998 across fixtures |

Endpoint miss and replanning contraction are essentially eliminated because
anchors do not move and future anchors are not replanned. That is not the same
as predicting the right initial scale. Family A median candidate error ranges
from 276 m to 2,483 m; family B from 598 m to 1,598 m on Douglas and 1,180 m
on Peel. Phase 3B loses planned scale but its live budget correction often
lands closer to the requested distance.

Therefore the Phase 6 stage retention ratio is not directly comparable: the
graph families have no evolving crow skeleton. Their meaningful retention is
fixed-anchor routed pre-trim to post-trim, and it is excellent while absolute
target accuracy remains poor.

## 9. Repair work and rejected-call efficiency

Candidate legs use the same avoidance, budget, spike and join-pullback logic as
Phase 3B, but no geometric leg retry: anchors are fixed graph locations.

| generator | candidates | passes | calls/candidate | retries | budget | pullback calls | spike | relaxed | rejected calls |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Phase 3B normal | 108 | 19 | 9.06 | 213 | 110 | 205 | 45 | 2 | 849 |
| Family A | 96 | 23 | 6.09 | 0 | 35 | 161 | 5 | 0 | 434 |
| Family B | 96 | 20 | 6.22 | 0 | 49 | 154 | 10 | 0 | 478 |

Family A reduces rejected calls 48.9% and Family B 43.7%. Fixup calls fall
44.2% and 40.8%, respectively, largely because there are no retries or
retry-local repairs. However, seam pullbacks remain extremely common (1.68 and
1.60 calls/candidate). Real nodes are reachable but can still lie on the same
corridor or force a reversal. H3 is only partly supported.

Calls per passing candidate improve from 51.5 for completed Phase 3B normal
candidates (978/19) to 25.4/29.9. That apparent efficiency cannot be accepted
without offered-route coverage.

Calls per offered route are 81.5 for Phase 3B normal fixtures, 83.6 for Family
A, and 66.3 for Family B. Family B's improvement is real but accompanies a
25% loss of offered routes, so it does not pass the efficiency gate.

## 10. Peel contrast

Peel anchors eliminate guide miss but do not improve usefulness:

```text
Phase 3B: 5 passes among 59 completed trace candidates; 530 request calls;
          three offered routes.
Family A: 1/24 passes, 172 candidate calls, 1 offered route.
Family B: 1/24 passes, 156 candidate calls, 1 offered route.
```

Family B's first anchor matches its field distance within 9 m median, yet its
final candidate misses target by 1,180 m median. Peel's 15/24 sectors and 105°
gap explain why independently chosen directional anchors do not form a useful
cycle. The same failure direction appears in Douglas 5 km, so this is not a
Peel-only result.

## 11. Quality and diversity

The normal-fixture Phase 3B offers 12 routes with mean/median absolute error
5.00%/5.90%, mean quality 67.6, repeated ground 1.88%, one u-turn, worst
geometric overlap 37.8%, and worst physical overlap 38.5%.

| graph family | offered | mean absolute error | mean quality | repeated | u-turns | worst geometric | worst physical |
|---|---:|---:|---:|---:|---:|---:|---:|
| A | 7 | 121 m | 76.7 | 0.01% | 0 | 51.9% | 50.7% |
| B | 9 | 245 m | 71.0 | 0.07% | 1 | 15.4% | 8.6% |

Passing graph candidates are clean, especially Family B, but there are too few
of them: A offers none at Douglas 5 km and one at Peel; B offers only two and
one. Diversity among B's surviving routes is strong. H5 is possible but route
coverage is not preserved.

## 12. Preprocessing and total-cost accounting

| fixture | family | exploration ms | selection ms | routing elapsed ms | total analysis path ms | summed GH engine ms |
|---|---|---:|---:|---:|---:|---:|
| Douglas 5 km | A / B | 3.33 | 372 / 469 | 436 / 265 | 811 / 738 | 240 / 268 |
| Douglas 3 km | A / B | 1.48 | 407 / 408 | 213 / 224 | 622 / 633 | 192 / 184 |
| Peel 5 km | A / B | 0.56 | 121 / 111 | 224 / 190 | 346 / 301 | 133 / 116 |
| Onchan 5 km | A / B | 0.99 | 247 / 240 | 195 / 203 | 443 / 444 | 130 / 140 |

Exploration is request-scoped and counted once. Anchor selection is the
unoptimised analysis implementation and is counted rather than hidden. It
would need shell/sector indexes before any production benchmark, but there is
no reason to optimise it yet because the candidate family fails the gate.
Routing elapsed uses four-candidate concurrency. Summed engine time and summed
boundary wall time are retained separately in `offline.md/json`; they exceed
elapsed time where calls overlap. The `total analysis path` column counts the
field once plus selection plus routing elapsed, so preprocessing is not hidden.

Cross-request caching is unnecessary to make exploration affordable and was
not used. A request-scoped field is sufficient.

## 13. GO / NO-GO gate

**NO-GO before production integration.**

Positive structural signals:

- endpoint miss: effectively eliminated;
- rejected calls: down 43.7–48.9%;
- calls/pass: down more than 25%;
- field exploration: comfortably cheap;
- Family B surviving-route diversity: strong.

Failed requirements:

- pass rate is 24.0%/20.8%, not 2× Phase 3B's 17.6%;
- distance failures are 66/63 of 96, worse in rate than Phase 3B;
- offered routes fall from 12 to 7/9;
- gains are not consistent: Douglas 5 km and Peel remain poor;
- repair work falls less than 50% and pullbacks remain common;
- the analysis anchor selector adds hundreds of milliseconds.

The structural-success rejected-call threshold is met numerically, but its
required quality/coverage preservation is not. No
`LOOPER_NETWORK_AWARE_CANDIDATES` production path, paired benchmark, or
waypoint change was implemented.

## 14. Retained and rejected changes

Retained as analysis infrastructure:

- read-only `LooperRoutingCore.explore` using GraphHopper graph primitives;
- the `NetworkField` exporter and measured fixture field;
- deterministic shell/sector anchor selection and two offline families;
- offline scale, repair, efficiency, quality and diversity results.

Rejected:

- production integration of either anchor family;
- treating start distance as loop scale;
- reducing candidate count, avoidance or diversity to make the prototype pass;
- reusing Phase 6 cumulative repayment;
- any Peel-specific sector or shell constant.

Waypoints remain entirely on the existing production path.

## 15. Final classification and Phase 8 recommendation

**NO MATERIAL WIN; Outcome B: the network field is useful, but independent
start-shell anchor sequencing is weak.**

Phase 8 should retain the cheap distance-field infrastructure and investigate
pairwise/topological compatibility before routing whole candidates. The next
bounded experiment should measure anchor-to-anchor network distances or shared
start-tree ancestry for a small ranked anchor set, then choose sequences whose
pairwise edges plausibly close at target scale. This is not permission to build
a second router: GraphHopper should still provide all routes, and a direct
closed-cycle search should be considered only if pairwise-compatible anchors
also fail.

## Reproduction

```sh
# Phase 3B/Phase 6 baseline artifacts
ROUNDS=4 RUNS=7 npx tsx bench/phase6/paired.mts
npx tsx bench/phase6/capture.mts P6
CORPUS=corpus-P6 npx tsx bench/phase6/analyse.mts

# Build and export repeated warm GraphHopper fields
docker build -t looper-phase7-field gh-harness
docker run --rm --entrypoint java \
  -v looper_graph-cache-iom:/data/graph-cache:ro \
  -v "$PWD/graphhopper:/gh:ro" \
  -v "$PWD/bench/phase7:/work" \
  looper-phase7-field -Xmx2g -cp /h/gh-harness.jar \
  com.looper.routing.NetworkField /gh/config.yml /data/graph-cache \
  /work/fixtures.json /work/network-fields.json

# Route both 24-candidate families and write analysis
npx tsx bench/phase7/analyse.mts

# Verification
npm run typecheck
npm run lint
npm test
```
