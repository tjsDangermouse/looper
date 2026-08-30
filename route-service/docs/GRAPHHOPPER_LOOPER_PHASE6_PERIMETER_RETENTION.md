# GraphHopper / Looper Phase 6 — Perimeter Retention and Contraction Attribution

## Decision

**Production NO-GO. Final classification: NO MATERIAL WIN.**

The forensic hypothesis is partly true: too-short candidates retain a median
0.803 of their initial effective scale by leg 3 and 0.730 at completion,
compared with 0.982 and 0.986 for passing candidates. The loss is early enough
to observe. It is not attributable to one dominant causal mechanism, however.
The conservative combined offline oracle reaches 38/68 distance failures
(55.9%) across four non-waypoint fixtures, but no individual mechanism reaches
40%; the best is routing displacement at 17/68 (25.0%).

The resulting bounded cumulative-deficit prototype made production behaviour
worse:

```text
                                Phase 3B       Phase 6       change
median warm wall time            1,847 ms       2,017 ms       +9.2%
GraphHopper calls                    1,297           1,472      +13.5%
retained candidate passes                23              21       -2
offered routes                            14              14        0
```

The prototype remains behind `LOOPER_PERIMETER_RETENTION`, default OFF. Phase
3B remains production. No GraphHopper setting or waypoint semantic changed.

## 1. Baseline confirmation

The capture explicitly enabled the retained Phase 3B behaviour:

```text
LOOPER_PULLBACK_REUSES_PREVIOUS=true
LOOPER_BACKTRACK_NEEDS_BUDGET=true
LOOPER_BUDGET_ONCE_PER_LEG=true
ROUTING_CONCURRENCY=4
LOOPER_MODEL_REGISTRY=true
LOOPER_ROUTE_MEMO=true
```

The rejected Phase 4 closure-reserve controller is absent. Phase 5's
full-shape functions remain passive trace/analysis helpers; there is no
full-shape production controller. GraphHopper is unchanged.

Four repeated alternating warm Phase 3B arms reproduced the Phase 5 baseline:

| fixture | median wall ms | GH calls | builds | retained passes | distance rejections | offered |
|---|---:|---:|---:|---:|---:|---:|
| Douglas 5 km | 347 | 238 | 24 | 5 | 10 | 3 |
| Douglas 3 km | 113 | 96 | 24 | 4 | 3 | 3 |
| Peel 5 km | 508 | 530 | 24 | 5 | 12 | 3 |
| Onchan 5 km | 133 | 114 | 24 | 4 | 4 | 3 |
| wp-one | 123 | 34 | 0 | 0 | 5 | 1 |
| wp-two | 626 | 285 | 24 | 5 | 23 | 1 |
| **total** | **1,847** | **1,297** | **120** | **23** | **57** | **14** |

The passive completed-candidate corpus contains 127 candidates: 24 pass, 68
distance failures (48 short, 20 long), and 35 other quality failures. Calls
attribute as 167 pass, 642 distance failure, 333 other quality failure, and
155 request/waypoint or unfinished work. Thus 975/1,297 calls (75.2%) are
attached to completed rejected candidates.

## 2. Intended perimeter and scale

`initialIntendedPerimeter` is the crow-distance perimeter of the complete
equal-share guide skeleton constructed at candidate start, including its
direct geometric closure. For a normal three-corner 5 km ring the planner lays
out three 1,250 m outward guide segments; the final start segment completes
the geometric skeleton. It is neither a GraphHopper distance nor a network
stretch prediction.

The stage retention diagnostic is:

```text
effectiveScale = actual routed metres already committed
               + current remaining crow-distance skeleton

retention = effectiveScale / initialIntendedPerimeter
```

Final retention uses the post-trim routed candidate distance. This deliberately
labelled hybrid exposes scale evolution; it does not assert equivalence between
crow and network metres. Raw coordinates, distances and segments remain in the
trace so other definitions can be tested.

## 3. Instrumentation

Tracing now records, without work when tracing is disabled:

- candidate family identity, bearing, direction, corner count, target scale,
  initial shares, guide coordinates, segments, closure and perimeter;
- every plan's current point, guide set, planned budget, used/remaining target,
  and remaining skeleton;
- every attempt's target, routed endpoint, intended/achieved crow reach, guide
  miss, routed distance, retry index and relaxed status;
- exact before/after routed distances and endpoints for leg-budget, spike and
  join-pullback transformations;
- the selected attempt and final leg endpoint;
- pre-trim leg sum, final distance and trim delta.

The analyser reconstructs original-versus-replanned future guides, stage
waterfalls, mechanism deltas, retention, fixture contrasts, controllability,
and conservative oracle ceilings. Speculative fixups on attempts later
discarded are retained as raw trace but excluded from final-candidate
attribution.

## 4. Candidate transformation call graph

```text
candidate-start skeleton
  -> leg-plan
     -> normal route
        -> relaxed route on routing failure
        -> kept leg-budget reroute (optional)
        -> kept spike reroute (optional)
     -> retry with shorter/swung target (optional)
     -> select attempt
     -> join-pullback of current + previous legs (optional)
     -> commit routed distance and endpoint
  -> replan future guides from new endpoint and remaining budget
  -> repeat outward legs
  -> closure route
  -> join geometries
  -> trim tiny spikes
  -> quality and distance classification
```

Short-backtrack handling is a reason for retry, not a separate geometry
rewrite. Relaxed routing is a replacement route inside an attempt. Later-guide
recalculation occurs at the next `leg-plan`.

## 5. Intended versus achieved progress and endpoint displacement

Guide miss separates Peel from the other normal fixtures, but not cleanly
enough to be a controller by itself:

| fixture | candidates | median guide miss m | p90 m | retry attempts/candidate | relaxed attempts |
|---|---:|---:|---:|---:|---:|
| Douglas 5 km | 24 | 47 | 600 | 2.38 | 22 |
| Douglas 3 km | 12 | 15 | 377 | 1.67 | 3 |
| Peel 5 km | 59 | 85 | 888 | 1.88 | 59 |
| Onchan 5 km | 13 | 34 | 364 | 1.92 | 14 |

For Peel undershoots specifically, median guide miss is 192 m and p90 is
1,288 m, versus 56/314 m for Peel passes. Douglas 5 km undershoots are 28/654
m; Onchan undershoots are only 19/114 m. Endpoint displacement is therefore a
strong Peel symptom but not a generic sufficient explanation.

## 6. Transformation attribution

Positive is expansion; negative is contraction. Selected transformations only:

| mechanism | pass median | too-short median | too-long median | too-short triggers | too-short total m |
|---|---:|---:|---:|---:|---:|
| routing displacement | +226 | +247 | +414 | 125 | +35,231 |
| retry | -539 | -865 | -727 | 65 | -68,462 |
| leg-budget | -3,701 | -1,479 | -1,434 | 20 | -48,467 |
| join-pullback | -524 | -620 | -363 | 64 | -49,152 |
| replanning | 0 | 0 | 0 | 125 | +21,435 net |
| spike | -59 | -59 | +1,068 | 12 | -645 |
| closure | +209 | +373 | +749 | 48 | +39,577 |
| final trim | -32 | -135 | -197 | 48 | -6,500 |

Interpretation by mechanism:

- **Normal routing displacement:** the largest early absolute movement and the
  top controllability score, but its median is expansion for every outcome.
  Signed local contractions recover only 17/68 failures offline.
- **Retry:** reliably contracts the planned skeleton and separates short from
  pass (-865 versus -539 m median). It recovers 15/68 failures, the strongest
  pure contraction signal but below the gate.
- **Leg-budget:** produces very large negative route-distance deltas. It is
  uncommon in selected paths and often replaces an avoidance-driven detour;
  repaying the removed distance blindly would restore the detour's length, not
  necessarily useful perimeter. Ceiling: 3/68.
- **Join-pullback:** common and contracting, but most triggers occur after much
  authority has gone. Ceiling: 5/68.
- **Replanning:** does not systematically contract undershoots; their net
  replan delta is positive. Negative replans recover 9/68.
- **Spike:** small, rare, and too late. Ceiling: 0/68.
- **Closure:** expands rather than contracts on median and is uncontrollable.
  This confirms that another closure reservation would be wrong.
- **Final trim:** removes 135 m median from undershoots but is too late and too
  small to explain them.

Join-pullback triggered 175 times and was kept 130 times. Phase 3B reused a
point on the previous routed path in 114 triggers (99 kept); only 61 triggers
needed the older previous-leg reroute path. The contraction result therefore
does not justify reverting reuse: reuse avoids a call while preserving the
same generic pullback mechanism.

The strongest stage-level signals are early: stage-0 routing displacement has
a +202 m median; stage-1 retry -761 m, leg-budget -1,385 m, pullback -540 m,
and replan -110 m. By stage 2, a normal three-corner candidate has no later
outward guide after the current one; closure/trim losses have no authority.

## 7. Candidate perimeter waterfalls

Representative Peel undershoot:

```text
peel-5km:8-cw@3

initial crow skeleton                    5,000 m
before leg 2 effective scale             4,769 m
before closure effective scale           3,815 m
final routed/trimmed distance             3,320 m

routing displacement leg 1                +460 m
replan before leg 2                       -154 m
routing displacement leg 2              +1,324 m
leg-budget selected in leg 2             -1,385 m
join-pullback in leg 2                     -689 m
replan before leg 3                       +262 m
routing displacement leg 3              -1,807 m
closure                                   -176 m
final trim                                -261 m
```

The deltas describe sequential local transformations with geometric and routed
quantities kept distinct; they are not expected to sum as one homogeneous
unit ledger. Passing and too-long examples, plus every candidate's machine
readable stages and occurrences, are in `bench/phase6/results/analysis.*`.

## 8. Cumulative retention

| outcome | initial | after leg 1 | after leg 2 | after leg 3 | before closure | final |
|---|---:|---:|---:|---:|---:|---:|
| PASS | 1.000 | 1.000 | 0.974 | 0.982 | 0.975 | 0.986 |
| TOO SHORT | 1.000 | 1.001 | 0.954 | 0.803 | 0.763 | 0.730 |
| TOO LONG | 1.000 | 1.002 | 1.062 | 1.189 | 1.189 | 1.249 |

Final median retention by normal fixture:

| fixture | pass | too short | too long |
|---|---:|---:|---:|
| Douglas 5 km | 0.887 | 0.749 | 1.215 |
| Douglas 3 km | 0.935 | 0.648 | 1.148 |
| Peel 5 km | 0.977 | 0.706 | 1.309 |
| Onchan 5 km | 1.007 | 0.805 | 1.173 |

Separation begins after leg 1 and becomes material at/after leg 2. This is
early enough to be interesting, unlike Phase 5's final-distance prediction,
but the local signed causes differ by candidate.

## 9. Peel contrast

| measure | Douglas 5 km | Douglas 3 km | Peel 5 km | Onchan 5 km |
|---|---:|---:|---:|---:|
| median / p90 guide miss m | 47 / 600 | 15 / 377 | **85 / 888** | 34 / 364 |
| retry attempts/candidate | 2.38 | 1.67 | 1.88 | 1.92 |
| kept leg-budget/candidate | 0.33 | 0.17 | 0.29 | 0.46 |
| kept pullbacks/candidate | 1.21 | 1.25 | 1.00 | 0.85 |
| negative replan m/candidate | 586 | 172 | 196 | 396 |
| median closure delta m | 145 | 251 | **555** | 171 |
| short-backtrack retry triggers | 39 | 4 | 62 | 11 |

Peel does not have the most retries, budget corrections, pullbacks, or
negative replanning. It does have the largest endpoint miss and closure
expansion, especially among undershoots, plus the largest absolute failure
count. The evidence points to an interaction between guide geometry and Peel's
routable topology, not a universal pullback or closure constant. No
Peel-specific rule was introduced.

## 10. Controllability ranking

The transparent score is:

```text
total absolute delta
× mean((cornerCount - stage) / cornerCount)
× controllable-trigger share
```

| rank | mechanism | absolute m | early weight | controllable share | score |
|---:|---|---:|---:|---:|---:|
| 1 | routing displacement | 279,188 | 0.68 | 63.8% | 121,319 |
| 2 | retry | 138,503 | 0.59 | 50.0% | 40,713 |
| 3 | leg-budget | 124,261 | 0.43 | 43.6% | 23,263 |
| 4 | replanning | 96,954 | 0.32 | 63.8% | 19,743 |
| 5 | join-pullback | 96,926 | 0.36 | 36.9% | 12,962 |
| 6 | spike | 4,465 | 0.08 | 4.5% | 17 |
| 7/8 | closure / trim | — | 0 | 0% | 0 |

Large deltas are not automatically repayable. Budget reroutes remove expensive
avoidance detours; pullbacks remove dead-end structure; closure and trim are
too late. Routing displacement and retry are early but heterogeneous.

## 11. Offline oracle compensation

A failure counts only when the mechanism's signed pre-closure delta opposes
the final error, reaches the nearest accepted-band boundary, and the required
correction is no more than 30% of remaining outward planned crow reach at the
earliest matching event.

| mechanism | recoverable | unique |
|---|---:|---:|
| endpoint/routing displacement | 17 / 68 (25.0%) | 14 |
| retry contraction | 15 / 68 (22.1%) | 7 |
| leg-budget contraction | 3 / 68 (4.4%) | 0 |
| join-pullback contraction | 5 / 68 (7.4%) | 0 |
| replanning contraction | 9 / 68 (13.2%) | 2 |
| spike | 0 / 68 | 0 |
| combined cumulative deficit | **38 / 68 (55.9%)** | 4 |

Combined recovery is 8/11 Douglas 5 km, 3/6 Douglas 3 km, 14/37 Peel, 5/6
Onchan, and 8/8 wp-two. It passes the analysis-first 40% gate and is generic,
so the smallest production prototype was permitted. Waypoint recovery did not
influence its design; waypoint construction remained unchanged.

## 12. Prototype design and safety rails

`LOOPER_PERIMETER_RETENTION=true` enables a local cumulative-deficit model:

1. after an outward leg, compare the prior effective skeleton with actual
   routed metres plus the old future skeleton anchored at the routed endpoint;
2. at the next plan, measure any additional negative replan delta;
3. carry only positive measured loss forward;
4. distribute repayment over remaining outward legs;
5. cap cumulative debt at 30% of target and one payment at 25% of the ordinary
   equal-share reach;
6. never compensate the closing leg and never react to a global final-distance
   prediction.

The flag defaults OFF. It uses no fixture constants, has no oscillating
negative repayment, preserves avoidance, candidate count, concurrency,
waypoints and GraphHopper, and leaves the entire path dormant when disabled.

## 13. Paired production benchmark

Four rounds, seven measured fixture runs after a discarded warm run, with arm
order alternated:

| fixture | Phase 3B ms/calls/pass | Phase 6 ms/calls/pass | call change | offered |
|---|---:|---:|---:|---:|
| Douglas 5 km | 347 / 238 / 5 | 266 / 171 / 4 | -28.2% | 3 / 3 |
| Douglas 3 km | 113 / 96 / 4 | 183 / 165 / 4 | +71.9% | 3 / 3 |
| Peel 5 km | 508 / 530 / 5 | 706 / 720 / 5 | +35.8% | 3 / 3 |
| Onchan 5 km | 133 / 114 / 4 | 116 / 108 / 4 | -5.3% | 3 / 3 |
| wp-one | 123 / 34 / 0 | 126 / 34 / 0 | 0% | 1 / 1 |
| wp-two | 626 / 285 / 5 | 624 / 274 / 4 | -3.9% | 1 / 1 |
| **total** | **1,847 / 1,297 / 23** | **2,017 / 1,472 / 21** | **+13.5%** | **14 / 14** |

The stable untraced diagnostics report distance rejections by fixture as
10→7, 3→9, 12→10, 4→4, 5→5, and 23→24 in table order: total 57→59. A traced
prototype corpus completed more asynchronous candidates (144 versus 127), so
its 52 short/39 long split is useful for anatomy but not directly paired with
the baseline count. In that trace, calls on completed rejected candidates were
1,106/1,460 (75.8%): 810 distance-failure calls and 296 other-quality calls.
Calls per retained passing candidate worsened from 56.4 to 70.1 and calls per
offered route from 92.6 to 105.1 using untraced totals.

For completeness, completed trace outcomes were:

| fixture | Phase 3B pass/short/long/other | Phase 6 pass/short/long/other |
|---|---:|---:|
| Douglas 5 km | 5 / 5 / 6 / 8 | 4 / 2 / 8 / 3 |
| Douglas 3 km | 4 / 4 / 2 / 2 | 4 / 7 / 5 / 2 |
| Peel 5 km | 5 / 31 / 6 / 17 | 6 / 38 / 15 / 20 |
| Onchan 5 km | 5 / 3 / 3 / 2 | 6 / 1 / 5 / 1 |
| wp-two | 5 / 5 / 3 / 6 | 4 / 4 / 6 / 3 |

Because synchronous tracing changes which already-dispatched candidates finish
before early-stop cancellation, these counts are anatomy, not the paired
production denominator. The untraced diagnostics above are the gate.

## 14. Quality and diversity

| measure | Phase 3B | Phase 6 |
|---|---:|---:|
| offered routes | 14 | 14 |
| mean / median absolute distance error | 6.63% / 6.40% | 6.22% / 5.02% |
| mean / median quality score | 65.73 / 67.5 | 67.01 / 70.7 |
| mean / median repeated ground | 1.66% / 1.10% | 1.06% / 0.90% |
| total u-turns | 1 | 2 |
| worst geometric pair overlap | 37.8% | 43.4% |
| worst physical-edge pair overlap | 38.5% | 42.7% |

Aggregate distance and quality improve modestly, but diversity worsens and
u-turns double. Peel's worst physical overlap rises from 27.0% to 42.7% and it
uses 190 more calls. These quality changes cannot rescue a prototype that
misses every performance threshold and increases distance failures overall.

## 15. Retained and rejected changes

Retained:

- passive candidate-start, per-leg, endpoint, transformation and final-trim
  trace fields;
- the offline waterfall/oracle analyser and reproducible capture/paired tools;
- unit-tested bounded prototype code behind a default-OFF feature flag, as an
  experimental reference only.

Rejected for production:

- enabling `LOOPER_PERIMETER_RETENTION`;
- any Peel-specific tuning;
- compensating closure or reintroducing Phase 4 reservation;
- using Phase 5 full-shape prediction as a controller;
- removing Phase 3B budget/pullback mechanisms merely because they contract;
- changing GraphHopper, LM, avoidance, concurrency, candidate cap or waypoint
  semantics.

## 16. Final classification and Phase 7 recommendation

**NO MATERIAL WIN.** The central hypothesis is supported descriptively—scale
loss is measurable and separates outcomes by leg 2—but not causally enough for
a generic controller. The offline combined ceiling is a structural clue, not
a validated control law: combining heterogeneous retry, detour-removal,
pullback and endpoint effects overstates how interchangeable their metres are.
The production experiment converts many short candidates into long ones,
especially outside Douglas 5 km, while increasing work.

Phase 7 should investigate candidate-family construction in graph space rather
than add another correction layer to equal-share corners. Priorities are
network-aware or anchor-based family construction and a shape parameterisation
whose scale is defined on routable topology. Peel should remain a contrast
fixture, not a tuning target. The default-off Phase 6 prototype is useful as a
negative control for that work.

## Reproduction

From `route-service/`, with the settled GraphHopper facade at `GH_URL` (default
`http://localhost:8991`):

```sh
# Static verification
npm run typecheck
npm test

# Passive Phase 3B corpus and attribution
npx tsx bench/phase6/capture.mts P6
CORPUS=corpus-P6 npx tsx bench/phase6/analyse.mts

# Repeated alternating warm production benchmark
ROUNDS=4 RUNS=7 npx tsx bench/phase6/paired.mts

# Prototype anatomy only; the flag remains default OFF
npx tsx bench/phase6/capture.mts P6_PROTO LOOPER_PERIMETER_RETENTION=true
CORPUS=corpus-P6_PROTO npx tsx bench/phase6/analyse.mts
```

Primary generated artifacts:

```text
bench/phase6/corpus-P6/*.jsonl
bench/phase6/corpus-P6_PROTO/*.jsonl
bench/phase6/results/analysis.md
bench/phase6/results/analysis.json
bench/phase6/results/paired.json
```
