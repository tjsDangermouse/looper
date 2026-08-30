# GraphHopper / Looper Phase 5 — Full-Shape Distance Control

## Decision

**NO-GO for production control. Final classification: NO MATERIAL WIN.**

The hypothesis was tested offline before changing candidate generation. A
complete-shape predictor is more informative late in a candidate, but it is
not informative early enough, with enough remaining radius authority, to meet
the required correction ceiling.

The most optimistic F1–F3 ceiling is:

```text
17 / 69 distance failures = 24.6%
14 / 61 excluding waypoint fixtures = 23.0%
```

This is below the approximately 40% GO threshold. The simpler and more
accurate F0 estimator has only a 2.9% unique correction ceiling. No production
controller, direct-home probe, or early-abort rule was implemented.

Production remains Phase 3B. The only retained code changes are passive trace
fields, a pure geometric analysis helper, tests, and reproducible offline and
baseline scripts. Full-shape work is skipped entirely when tracing is off.

## 1. Baseline confirmation

The rejected Phase 4 closure-reserve prototype is absent. There is no
`LOOPER_CLOSURE_AWARE_PLANNING` production path in this checkout. The capture
harness explicitly retains:

```text
LOOPER_PULLBACK_REUSES_PREVIOUS=true
LOOPER_BACKTRACK_NEEDS_BUDGET=true
LOOPER_BUDGET_ONCE_PER_LEG=true
ROUTING_CONCURRENCY=4
LOOPER_MODEL_REGISTRY=true
LOOPER_ROUTE_MEMO=true
```

GraphHopper remains the settled GraphHopper 11 foot/LM hybrid configuration.

The first clean passive trace reproduced the corrected Phase 4 reference:

```text
GraphHopper calls             1,297
completed candidate records    127
passing candidate records       24 (18.9%)
distance failures               68
  too short                     48
  too long                      20
other quality failures          35
offered walks                   14
```

Production diagnostics distinguish dispatched candidate builds from completed
trace records. A stable untraced run dispatched 120 ring builds and recorded
23 retained passes; asynchronous candidates that finish after an early-stop
decision can still appear in the trace and consume calls, which is why the
trace has 127 completed records and 24 passes. Both measures are reported
rather than silently treating them as identical.

### Repeated warm baseline

Four untraced rounds, seven measured runs per fixture after a discarded warm
run, produced total round medians of:

```text
1,848 / 1,832 / 1,862 / 1,825 ms
median total: 1,848 ms
GraphHopper calls: 1,297 in every round
```

| fixture | median wall ms | GH calls | dispatched builds | retained passes | offered |
|---|---:|---:|---:|---:|---:|
| douglas-5km | 346 | 238 | 24 | 5 | 3 |
| douglas-3km | 112 | 96 | 24 | 4 | 3 |
| peel-5km | 504 | 530 | 24 | 5 | 3 |
| onchan-5km | 127 | 114 | 24 | 4 | 3 |
| wp-one | 126 | 34 | 0 | 0 | 1 |
| wp-two | 625 | 285 | 24 | 5 | 1 |
| **total** | **1,848** | **1,297** | **120** | **23** | **14** |

The traced candidate-call attribution was:

| final candidate outcome | candidates | calls |
|---|---:|---:|
| passed | 24 | 167 |
| distance failure | 68 | 642 |
| other quality failure | 35 | 333 |

Thus at least 975 calls, 75.2% of all 1,297 calls, were attached to candidates
eventually rejected. A further 155 calls were request/waypoint work not
attributed to a completed ring outcome. Total calls per traced passing
candidate were 54.0; total calls per offered route were 92.6.

### Baseline offered-route quality

| measure | baseline |
|---|---:|
| offered routes | 14 |
| mean / median absolute distance error | 6.63% / 6.40% |
| mean / median quality score | 65.73 / 67.5 |
| mean / median repeated ground | 1.66% / 1.10% |
| total u-turns | 1 |
| worst geometric pair overlap | 37.8% |
| worst physical-edge pair overlap | 38.5% |

No production experiment changed geometry, so quality and diversity remain
this baseline rather than being compared with a controller arm.

## 2. Why Phase 4 failed, and why Phase 5 differed

Phase 4 independently reserved an estimated closure cost:

```text
remaining target - estimated closure = budget for outward shape
```

That created positive contraction feedback. An expensive predicted closure
shortened the next outward guide; moving inward made the eventual closure
cheaper; subsequent guides contracted again. The corrected prototype doubled
calls from about 1,297 to 2,806, reduced pass rate from 18.9% to 7.5%, and
created 217 distance failures, 180 of them too short. It remains rejected.

Phase 5 did not reserve closure separately. At every historical stage it built
one coupled geometric object containing all prospective corner segments and
the final return segment, then evaluated:

```text
actual routed distance already used
+ estimated network length of the entire remaining skeleton
```

This avoided Phase 4's conceptual error, but the data still did not support a
production controller.

## 3. P1 — distance-failure anatomy

The full-shape trace contained 482 intermediate states from 128 completed
candidates. One concurrency-race candidate more completed than in the clean
1,297-call reference, giving 69 rather than 68 distance failures. Conclusions
are reported against this analysis corpus; the baseline figures above remain
the P0 reference.

| fixture | pass | too short | too long | other quality |
|---|---:|---:|---:|---:|
| douglas-5km | 5 | 5 | 6 | 8 |
| douglas-3km | 4 | 4 | 2 | 2 |
| peel-5km | 5 | 31 | 6 | 17 |
| onchan-5km | 5 | 4 | 3 | 2 |
| wp-two | 5 | 5 | 3 | 6 |
| **total** | **24** | **49** | **20** | **35** |

Median final errors for too-short candidates were -1,253 m Douglas 5 km,
-1,056 m Douglas 3 km, -1,472 m Peel, -1,205 m Onchan, and -1,578 m for the
two-waypoint fallback rings. Peel alone contributed 31 of 49 undershoots.

F0's accepted-band classification became useful primarily at the last corner:

| completed legs | actual short correctly classified | actual long correctly classified | remaining radius authority |
|---:|---:|---:|---|
| 0 | 0 / 49 | 0 / 20 | high |
| 1 | 5 / 49 | 1 / 20 | high |
| 2 | 10 / 44 | 8 / 19 | moderate |
| 3 | 24 / 33 | 9 / 16 | almost none for normal three-corner rings |

The detailed fixture/corner-count/stage/outcome tables are generated in
`bench/phase5/results/offline-analysis.md`. They resolve the older closure
diagnosis empirically: overall median final closure is smaller than remaining
target budget, with large fixture variation. Closure alone is not a stable
explanation of final error.

## 4. Full-shape estimators

All estimators use the same remaining skeleton. Future corner guides use the
current equal-share radius and existing heading/turn plan, followed by the
direct geometric segment from the last intended guide to the start.

```text
F0 = used + remaining crow length
F1 = used + 1.35 * remaining crow length
F2 = used + bounded median(completed network/crow ratios) * remaining crow
F3 = used + blended stretch * remaining crow
```

F2 uses the Phase 4 generic 1.05–2.25 clamps. F3 blends the neutral 1.35 with
the bounded local median using `n / (n + 2)` confidence, equivalent to two
neutral pseudo-observations. No fixture-specific constant is fitted.

## 5. Estimator accuracy by stage

Bias is predicted minus actual final candidate distance.

| stage / completed legs | estimator | median abs m | p75 | p90 | median bias m | classification accuracy |
|---:|---|---:|---:|---:|---:|---:|
| 0 | F0 | 731 | 1,350 | 2,114 | +350 | 46.1% |
| 0 | F1/F2/F3 | 2,129 | 3,053 | 3,787 | +2,125 | 15.6% |
| 1 | F0 | 722 | 1,433 | 2,031 | +238 | 50.8% |
| 1 | F1 | 1,647 | 2,585 | 3,217 | +1,605 | 18.8% |
| 1 | F2 | 1,434 | 2,375 | 3,585 | +1,304 | 25.8% |
| 1 | F3 | 1,573 | 2,581 | 3,179 | +1,543 | 19.5% |
| 2 | F0 | 613 | 1,072 | 1,548 | +87 | 59.5% |
| 2 | F1 | 924 | 1,805 | 2,380 | +882 | 37.2% |
| 2 | F2 | 1,130 | 1,980 | 2,725 | +1,063 | 35.5% |
| 2 | F3 | 1,008 | 1,939 | 2,545 | +943 | 35.5% |
| 3 | F0 | 254 | 659 | 1,208 | -97 | 71.7% |
| 3 | F1 | 335 | 771 | 1,327 | +194 | 68.7% |
| 3 | F2 | 423 | 847 | 1,580 | +187 | 68.7% |
| 3 | F3 | 411 | 765 | 1,455 | +205 | 68.7% |

F0 is the simplest and has the best median absolute error at every actionable
stage. Multiplying by network stretch makes the early estimate much worse.
The planner's radius already represents a share of the desired network-distance
budget; applying 1.35 to the entire intended perimeter effectively counts
network stretch twice.

### Median absolute error by fixture and stage

| fixture | stage | F0 | F1 | F2 | F3 |
|---|---:|---:|---:|---:|---:|
| Douglas 5 km | 0 / 1 / 2 / 3 | 570 / 573 / 434 / 175 | 1,811 / 1,572 / 883 / 357 | 1,811 / 1,147 / 1,174 / 559 | 1,811 / 1,429 / 957 / 504 |
| Douglas 3 km | 0 / 1 / 2 / 3 | 350 / 438 / 352 / 177 | 1,244 / 944 / 469 / 211 | 1,244 / 997 / 644 / 250 | 1,244 / 868 / 380 / 227 |
| Peel 5 km | 0 / 1 / 2 / 3 | 1,089 / 763 / 686 / 433 | 2,432 / 1,849 / 1,034 / 526 | 2,432 / 1,860 / 1,207 / 628 | 2,432 / 1,918 / 1,272 / 519 |
| Onchan 5 km | 0 / 1 / 2 / 3 | 295 / 291 / 341 / 199 | 1,716 / 1,288 / 686 / 224 | 1,716 / 1,139 / 999 / 134 | 1,716 / 1,291 / 723 / 187 |
| wp-two | 0 / 1 / 2 / 3 | 836 / 836 / 771 / 458 | 2,824 / 2,054 / 1,238 / 257 | 2,824 / 2,266 / 1,297 / 338 | 2,824 / 1,718 / 1,161 / 235 |

Waypoint results are analysis-only. Waypoint generation has a materially
different backbone and was excluded from any prospective production decision.

## 6. Radius monotonicity

Predicted total length was sampled at 0.7, 0.85, 1.0, 1.15, and 1.3 times the
current radius. “Actionable” means non-decreasing with a non-zero range.

| stage | states | actionable monotonic relation |
|---:|---:|---:|
| 0 | 128 | 128 (100.0%) |
| 1 | 128 | 121 (94.5%) |
| 2 | 121 | 96 (79.3%) |
| 3 | 99 | 6 (6.1%) |
| 4 | 6 | 0 (0.0%) |

The cheap geometric function is mostly monotonic while radius authority
exists. The problem is not search mechanics; it is prediction quality and the
rapid loss of useful control authority.

## 7. P4 theoretical recoverability ceiling

A historical failure is “predictably bad” only when the estimator names the
correct failure side. It is “plausibly correctable” only when the sampled
radius range also moves predicted total distance far enough in the correct
direction to cover the oracle metres needed to reach the accepted band.

| stage | estimator | failures observed | predictably bad | plausibly correctable |
|---:|---|---:|---:|---:|
| 0 | F0 | 69 | 0 | 0 |
| 0 | F1/F2/F3 | 69 | 20 | 17 |
| 1 | F0 | 69 | 6 | 1 |
| 1 | F1 | 69 | 24 | 13 |
| 1 | F2 | 69 | 20 | 11 |
| 1 | F3 | 69 | 24 | 13 |
| 2 | F0 | 63 | 18 | 1 |
| 2 | F1/F2 | 63 | 23 | 6 |
| 2 | F3 | 63 | 24 | 6 |
| 3 | F0 | 49 | 33 | 0 |
| 3 | F1 | 49 | 29 | 0 |
| 3 | F2/F3 | 49 | 31 | 0 |

F1–F3's early 17-candidate ceiling is not a usable controller result: all
three label every stage-0 candidate too long, including all 49 actual
undershoots and all 59 actually acceptable-distance candidates. Their apparent
recovery is selection of the 20 true overshoots inside a very large false
positive set. F0 avoids that bias but cannot distinguish failures early.

## 8. Explicit GO / NO-GO gate

**NO-GO.**

Reasons:

- Best optimistic unique ceiling: 24.6%, below the ~40% requirement.
- Best early estimator by absolute error, F0, predicts every stage-0 candidate
  as acceptable and has only a 2.9% unique correction ceiling.
- F1–F3 appear to find some overshoots only because of severe early positive
  bias; controlling on that signal would contract viable and too-short loops.
- Useful classification appears mostly after the third routed leg, when a
  normal three-corner candidate has no remaining corner radius to adjust.
- Peel's large fixture-specific undershoot concentration warns against a
  generic production constant.

## 9. Controller, probes, and early abort

No controller flag was added because the gate failed. Consequently there is
no Phase 5 controller benchmark arm and no GraphHopper call-count, pass-rate,
or wall-time claim beyond the unchanged Phase 3B baseline.

The optional late direct-home probe was not tested. Phase 4 already showed it
becomes informative late, and Phase 5 found the same late-authority problem;
adding calls cannot rescue the failed zero-routing ceiling.

Early abort was also not tested. F1–F3 would false-abort many viable or
too-short candidates, while F0 does not identify doomed candidates early.
False-positive safety therefore fails before call savings are considered.

## 10. Benchmark comparison and success classification

| measure | Phase 3B production | Phase 5 production controller |
|---|---:|---:|
| wall time | 1,848 ms warm median | not implemented |
| GraphHopper calls | 1,297 | not implemented |
| completed trace pass rate | 18.9% | not implemented |
| distance failures | 68 (48 short / 20 long) | not implemented |
| calls on rejected candidates | at least 975 | not implemented |
| offered routes | 14 | unchanged |

Phase 5 meets none of STRONG PASS, PASS, or STRUCTURAL SUCCESS because the
required gate correctly stopped production work. Classification is
**NO MATERIAL WIN**.

## 11. Retained and rejected changes

Retained:

- `src/loops/fullShape.ts`: deterministic remaining-skeleton construction and
  F0–F3 estimates;
- passive `leg-plan` fields for current position, intended heading, segment
  crow lengths, complete-shape predictions, and stretch evidence;
- `bench/phase5/analyse.mts` and generated offline result tables;
- `bench/phase5/baseline.mts` and warm baseline results;
- focused unit tests.

The new calculation is gated by `LOOPER_TRACE_FILE` through `tracingCalls` and
does not execute in normal production generation.

Rejected/not implemented:

- full-shape production controller and feature flag;
- binary/bracketed radius search;
- sampled-radius controller;
- direct-home production probe;
- prediction-based early abort;
- any Phase 4 closure-reserve behavior.

## 12. Reproduction commands

From `route-service/`, with the retained GraphHopper facade on `:8991`:

```sh
# P0: clean passive baseline trace and Phase 4-compatible anatomy
npx tsx bench/phase4/capture.mts P5_BASELINE
CORPUS=corpus-P5_BASELINE npx tsx bench/phase4/analyse.mts

# P1-P4: full-shape passive trace and offline analysis
npx tsx bench/phase4/capture.mts P5_FULL
CORPUS=../phase4/corpus-P5_FULL npx tsx bench/phase5/analyse.mts

# Untraced repeated warm wall-time and quality baseline
ROUNDS=4 RUNS=7 npx tsx bench/phase5/baseline.mts

# Verification
npm run typecheck
npm test
npm run lint
```

Trace capture writes synchronously and must not be used as a wall-time result.
`baseline.mts` is the untraced repeated-warm measurement.

## 13. Recommendation for the next routing phase

Do not try another global stretch multiplier or closure reserve. The next
analysis should decompose why the intended perimeter is not retained:

```text
initial equal-share skeleton
→ route-leg endpoint displacement
→ leg retries and shorter reaches
→ join pullbacks / trims
→ later replanning
→ final candidate distance
```

The key next quantity is perimeter retention or contraction by mechanism and
fixture, especially Peel, rather than a generic network-distance multiplier.
That analysis can reveal whether one specific transformation systematically
destroys intended scale early enough to correct locally. If no such mechanism
has a large oracle ceiling, candidate-family design—not distance control—is the
next structural bottleneck.
