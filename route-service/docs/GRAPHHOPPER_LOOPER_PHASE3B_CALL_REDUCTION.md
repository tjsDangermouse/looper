# Asking GraphHopper fewer questions — Phase 3B

Phase 3A removed two thirds of the request payload, halved the weighting
builds, and returned 2.7% of the walker's wait. It ended by saying the only
lever left with any size in it is the number of calls, and that a call removed
should be budgeted at roughly half of what its share of the call count
suggests.

Phase 3B removed 29.2% of the calls and returned 15.6% of the wall clock.
The exchange rate held to within a fifth of a percentage point, which is the
most useful thing this phase can hand the next one.

Measured 2026-08-30 on darwin/arm64, Docker Desktop, GraphHopper 11.0, Isle of
Man (35,088 nodes, 42,016 edges), against the same six production probes Phases
1, 2 and 3A used. Reproduce with:

```sh
npx tsx bench/phase3b/capture.mts B0                       # one traced generation per fixture
npx tsx bench/phase3b/capture.mts B6noB5 \
  LOOPER_PULLBACK_REUSES_PREVIOUS=true \
  LOOPER_BUDGET_ONCE_PER_LEG=true \
  LOOPER_BACKTRACK_NEEDS_BUDGET=true                       # the same, after
CORPUS=corpus-B0 npx tsx bench/phase3b/graph.mts           # §2–§5, §8, §21–§24
npx tsx bench/phase3b/experiments.mts                      # §25 — the stages, one at a time
npx tsx bench/phase3b/scheduling.mts B0                     # §16–§18 — the fan-out, swept
npx tsx bench/phase3b/gate.mts                              # §29, §30, §32 — the gate
```

## Executive conclusion

```
Phase 3A baseline:   2,255 ms   1,849 calls
Phase 3B retained:   1,904 ms   1,310 calls

wall-time improvement:  15.6%
call reduction:         29.2%

calls per returned route:  132.1 → 93.6
```

**Classification: below PASS.** §32 asks for 20% of the wall clock *and* 25%
of the calls. The call target is met with room — 29.2% against 25%, and it
holds to within thirteen calls across four rounds — and the wall-time target is
missed by four and a half points. It is comfortably clear of the 10% floor that
would have made it no material win, so the phase is neither a pass nor a
failure by the brief's own vocabulary, and saying so plainly is more useful
than rounding it into either.

The reason it lands there is not a surprise, and it was predicted before any of
this was built:

> Phase 3A: *"expect a call it removes to be worth roughly half of what its
> share of the call count suggests."*

Half of 29.2% is 14.6%. The measurement is 15.6%. **To reach a 20% wall-time
improvement this phase would have had to remove about 40% of the calls**, and
the analysis below says where the remaining 40% is and why it is not reachable
from where Looper's generator currently stands.

Four things were built, three retained:

| what | measured |
|---|---|
| a join fix-up that trims the previous leg instead of routing it again | **416 calls → 260**, over the same 193–208 seams |
| a cheaper reroute asked once per leg rather than once per attempt at it | **201 → 142** |
| a short backtrack no longer forcing a retry on its own | **848 leg attempts → 665**, 570 retries → 327 |
| the fan-out cut from six to four | **1,450 → 1,297 calls**, and *faster* |
| keeping the closest-fitting attempt rather than the last | measured, **not retained** — buys calls, costs wall time |

GraphHopper is untouched: same version, profile, custom-model semantics,
avoidance multipliers, LM configuration, algorithm and path details. Nothing
was forked. This phase changed only what Looper decides to ask.

## What the trace now carries

Phase 3A's per-call record said what a call carried and what it cost. It could
not say who asked for it. Phase 3B adds that, in `src/loops/trace.ts`: an async
context carrying the candidate, the leg of it, the retry of that leg and the
call that a fix-up hangs off, plus a decision line written wherever a fix-up or
a candidate is judged.

It is an async context rather than six changed signatures for two reasons: the
waypoint builders reach the same routines by a different path and would
otherwise go unlabelled, and a parameter threaded through `buildLoopIncrementally`
→ `attemptLeg` → `routeLegAttempt` → `applyJoinPullback` → the router would be
five functions changed for something none of them is about. It costs one
`getStore()` per call when `LOOPER_TRACE_FILE` is unset, and enters no store at
all.

## Call graph

Every fix-up call names its parent. Nothing in the workload is unattributed.

| purpose | calls | with a named parent | distinct parents | calls per parent |
|---|---:|---:|---:|---:|
| `leg` | 1,010 | — | — | — |
| `join-pullback` | 416 | 416 | 208 | **2.00** |
| `leg-budget` | 201 | 201 | 201 | 1.00 |
| `waypoint-leg` | 147 | — | — | — |
| `spike` | 59 | 59 | 59 | 1.00 |
| `waypoint-direct` | 8 | — | — | — |
| `leg-relaxed` | 2 | — | — | — |
| **total** | **1,843** | | | |

Read as trees, one ordinary leg call at a time:

| what hangs off one ordinary leg call | legs | share | calls it costs |
|---|---:|---:|---:|
| — nothing | 764 | 65.9% | 764 |
| `join-pullback → join-pullback` | 148 | 12.8% | 444 |
| `leg-budget` | 141 | 12.2% | 282 |
| `leg-budget → join-pullback → join-pullback` | 47 | 4.1% | **188** |
| `spike` | 33 | 2.8% | 66 |
| `spike → join-pullback → join-pullback` | 13 | 1.1% | 52 |
| `leg-budget → spike` | 13 | 1.1% | 39 |
| **total ordinary leg calls** | **1,159** | | **1,843** |

**Fix-up chains are shallow and they do not nest deeply.** A seam is never
pulled back twice — 208 seams, 208 invocations — and a leg never pays for more
than three fix-ups. What makes fix-ups a third of the workload is not depth; it
is that a third of legs need one at all.

The ten most expensive compound patterns are the seven rows above and their
waypoint equivalents: `leg-budget → join-pullback → join-pullback` at 188
calls is the most expensive single chain shape in the corpus, and
`spike → join-pullback → join-pullback` at 52 the next. Both begin with a leg
that came back wrong and end with the seam it left behind, which is why fixing
the first fix-up is worth more than fixing the last.

## Calls per candidate

```
calls per candidate build: mean 9.3, median 9, p90 16, max 64, over 199 builds
```

| candidate outcome | builds | GH calls | % of calls | calls per build |
|---|---:|---:|---:|---:|
| **failed quality** | 129 | **1,513** | **82.1%** | 11.7 |
| passed | 25 | 175 | 9.5% | 7.0 |
| abandoned or dropped past the stop prefix | 43 | 150 | 8.1% | 3.5 |
| unattributed | 2 | 5 | 0.3% | 2.5 |

**Eighty-two per cent of every call in the workload is spent on a candidate
that is thrown away**, and a candidate that fails costs 67% more than one that
passes, because passing early is what stops a candidate paying for retries.

By the gate that refused it:

| first rejection reason | builds | GH calls | % of calls | calls per build |
|---|---:|---:|---:|---:|
| **distance** | 95 | **1,138** | **61.7%** | 12.0 |
| out-and-back-spur | 18 | 206 | 11.2% | 11.4 |
| leg-too-long | 6 | 66 | 3.6% | 11.0 |
| u-turns | 4 | 50 | 2.7% | 12.5 |
| shapeless | 4 | 39 | 2.1% | 9.8 |
| leg-too-short | 1 | 9 | 0.5% | 9.0 |
| repeated-corridor | 1 | 5 | 0.3% | 5.0 |

Three fifths of every call Looper makes goes into a loop that comes back the
wrong length. That is the headline number of the whole analysis, and §23's
answer to it — stop building a candidate that already cannot meet its target —
does not apply, because of what the failures actually are:

```
95 distance failures:  25 too long,  70 too short
distance ÷ target:  p10 0.41   p25 0.50   median 0.75   p75 1.14   p90 1.25
a passing loop:     0.88 .. 1.08
```

**Seventy-four per cent of the distance failures are undershoot.** A candidate
that is going to come back short cannot be recognised as doomed partway,
because until the closing leg lands there is always enough budget left in
principle. Checked directly: of the 25 over-long builds, **none** had passed
the +12% ceiling after one leg or after two, so there is not a single call in
the corpus that early termination on distance could have prevented. §23 is
answered in the negative, on evidence, and nothing was built for it.

## join-pullback anatomy

| | |
|---|---:|
| calls | 416 (22.6% of the workload) |
| invocations, each two calls | 208 |
| trigger: a join turn past 150° | **208 (100%)** |
| median join turn | **180°** |
| median pullback movement | 357 m (mean 406, p90 648, max 1,000) |
| kept | 145 (69.7%) |
| paid two calls and left the join no straighter | **63 (30.3%)** |
| invocations on any one seam | always exactly 1 |
| median turn straightened, where kept | 86° |

`pullbackTurnOnly` ships on, so the boundary-spike trigger is never evaluated
and every occurrence in the corpus is the turn. The median trigger is a
**180° reversal** — the walk arrives at the corner and leaves back down the
same stub — which is exactly the cul-de-sac the mechanism was written for. It
is not firing speculatively; it is firing on the thing it was built to catch,
and keeping its answer seven times in ten.

The waste is not in *whether* it fires. It is in what it pays to find out.

## join-pullback experiment (B1)

§7 asks whether the answer is already in hand before the reroute is issued. It
is, and the measurement that says so is short:

```
route START → END, take the point at 65% along the returned line,
then route START → that point:

six probes across Douglas:
  the returned geometry is byte-identical to the prefix, every time
  GraphHopper's own distance agrees with the sum of its geometry to 0.015%
```

So **routing to a point that lies on an already-routed path buys back the
prefix of that path** — a call spent to learn something already paid for. The
fix-up's first call, redoing the previous leg as far as the pulled-back corner,
is exactly that call whenever the corner can be placed on the previous leg's
own line.

The corner is therefore chosen from the previous leg's geometry: the point on
it whose distance from the start is closest to what the geometric rule asked
for. The rule's intent is preserved — a corner this much nearer home — and the
leg arriving there becomes a trim rather than a request. The current leg is
still routed, because that is the call that re-aims the loop.

**Two guards, and they are the whole difference between a saving and a
different algorithm.** Measured without them:

| | |
|---|---:|
| pullbacks placed on the previous leg's path | 297 |
| where the wanted reach is nearer the start than the leg ever gets | **144 (48%)** |
| pullbacks keeping a tenth of the previous leg or less | 26 (9%) |
| kept fraction of the previous leg | p10 **14%**, median 75% |

A leg heading away from the start need never come as near it as the rule asks,
and the nearest point it can then offer is its own beginning — which collapses
the leg to nothing and hands the loop a corner it never chose. So the point is
taken only when the path passes within 15% of the wanted reach and at least 40%
of the leg survives; everything else falls back to routing, at the price it
always cost. With the guards:

| | without guards | with guards |
|---|---:|---:|
| placed on the path | 297 | **175** |
| kept fraction of the previous leg, p10 | 14% | **55%** |
| miss against the wanted reach, median / p90 | 1% / 42% | 1% / **5%** |
| collapses to a tenth or less | 26 | **0** |

Before and after, on the corpus:

| | before | after |
|---|---:|---:|
| join-pullback calls | 416 | **260** |
| invocations | 208 | 193 |
| calls per invocation | 2.00 | **1.35** |
| kept | 69.7% | **75.1%** |
| left the join no straighter | 30.3% | **24.9%** |

**B1 on its own makes things worse**, and that is worth stating rather than
hiding: 2,199 ms → 2,611 ms, 1,849 calls → 2,166. A trimmed previous leg is a
shorter previous leg, and a shorter leg feeds the retry churn that B3 exists to
remove. Alongside B3 it is worth 165 calls (1,591 → 1,426 with B2 also on).
**The two are retained together and neither is retained alone**, which is the
opposite of what a flag-at-a-time convention normally produces and is the
reason the stages were measured separately.

## leg-budget anatomy

| | |
|---|---:|
| calls | 201 (10.9%) |
| memo hits | **0** — every one is a genuinely different question |
| kept | 132 (65.7%) |
| metres saved where kept | median 1,385, mean 2,079, p90 3,366 |
| the strong leg's length ÷ its budget | median 1.37×, mean 1.57×, p90 2.18× |

**It is not solving by iteration.** §9 asks whether the retries are numerical
convergence on a length. They are not: each firing is a single relaxed reroute
of one leg attempt, and the reason 201 calls fall on only 100 leg steps is that
the *outer* attempt loop re-pays for it on each try:

| leg-budget calls on one leg step | steps |
|---|---:|
| 1 | 34 |
| 2 | 31 |
| 3 | 35 |

## Whether a better estimate could replace a retry (§9, §10) — no

The proposal is to treat each attempt as a sample of how the network answers a
guide radius, and interpolate the next radius rather than shrinking it blindly.
Measured on the corpus, over 1,145 base leg calls:

```
routed distance ÷ crow-flight ask:
  p10 0.90   p25 1.17   median 1.46   p75 2.15   p90 3.55   max 12.78

consecutive attempts at the same leg step, 485 pairs:
  |stretch(n+1) − stretch(n)| ÷ stretch(n):   median 20%,  p90 64%
  a ratio correction from attempt n mispredicts attempt n+1 by a median 20%
```

**The response is not stable enough to interpolate.** A ratio correction —
`R₂ = R₁ × D_target ÷ D₁`, the form §9 offers as an example — carries a median
20% error and a p90 of 64% into its next guess, against a leg-fit tolerance of
40%. It would land inside the tolerance rather more than half the time, which
is not enough to replace a retry, and it would do so while adding a mechanism
whose failures are silent. **Nothing was built for §10, and the reason is a
measurement rather than a preference.**

What is left is the observation that gave B2: where the first firing on a leg
step did not shorten anything, later firings on that same step were kept **8
times in 37** — the ground offers no cheaper way round and asking again with a
slightly different target does not change that. Where the first firing *did*
help, later ones were kept 63 times in 64. So the answer is latched per leg.

## leg-budget experiment (B2)

| | before | after |
|---|---:|---:|
| calls | 201 | **142** |
| kept | 65.7% | **71.1%** |
| leg steps firing it more than once | 66 of 100 | 31 of 92 |
| whole suite | 2,199 ms / 1,849 calls | 2,208 ms / 1,832 calls |

On its own it is within noise on the clock and worth seventeen calls — the
smallest of the three, retained because it is free, correct on its own terms
and compounds with the others.

## The retry that does not work (B3)

The largest single finding in the phase, and it came out of the parent/child
graph rather than out of the fix-up audit:

```
848 leg attempts
172 accepted first time
570 retried
145 exhausted their retries

why a retry was asked for:
  a short backtrack alone      212
  over its planned length only 194
  both                         164

retries provoked by a short backtrack:  256
    ... where the next attempt cleared it:  15  (6%)
```

`attemptLeg` retries a leg whose path shares ground with the leg before it but
not enough of it to be a real feature — a corner that turned out to be a dead
end. The retry swings the bearing twenty degrees and shortens the reach a
fifth. **Measured against the workload, that clears the backtrack six times in
a hundred.** And because the builder keeps whichever attempt came last rather
than whichever fitted best, the other 241 end up holding a leg that is shorter,
more swung, and still backtracking than the one they started with.

B3 requires the budget to have failed too before a short backtrack forces a
retry. The seam is still checked — `applyJoinPullback` runs unchanged, and it
is the mechanism that actually repairs a dead-ended corner.

| | before | after |
|---|---:|---:|
| leg attempts | 848 | **665** |
| retried | 570 | **327** |
| exhausted their retries | 145 | **50** |
| retries for a short backtrack alone | 212 | **0** |
| whole suite | 2,199 ms / 1,849 calls | **1,956 ms / 1,596 calls** |

−11.1% wall and −13.7% calls, from one flag, and the largest single-stage
effect in the phase.

## The attempt that is kept (B5) — measured, not retained

`attemptLeg` overwrites its answer on every attempt, so a step that exhausts
its retries keeps the last guess rather than the closest. On the corpus, 145
steps exhausted their retries and **only 61 of them were keeping their closest
fit**. Keeping the best-fitting attempt instead is correct in isolation and
costs nothing to compute.

| | B0 | B5 alone | B6 with it | B6 without it |
|---|---:|---:|---:|---:|
| wall ms | 2,199 | 2,381 | 2,021 | **1,913** |
| calls | 1,849 | 1,858 | **1,437** | 1,426 |

It buys eleven calls and costs 108 ms. A better-fitting leg is often a longer
one, and a longer leg pushes its candidate into the fix-ups the other stages
just removed. **Left off**, with the measurement recorded, exactly as
`localRepair` and `paretoArchive` were.

## Candidate duplication

| | calls |
|---|---:|
| answered by the exact memo (settled + joined) | 118 |
| first legs of a mirrored bearing pair, which ask the identical question | **76** |
| first-leg calls in all | 154 |

Mirrored attempts share a starting bearing by construction, so **half of all
first legs in the corpus are literally the same request** — same start, same
target, no avoidance, because nothing has been walked yet. Phase 3A's memo
already answers all of them, and structurally suppressing them would save the
parse and not the call. That is why B3 in §25's ordering is not a duplicate
suppressor here: the exact duplicates are already gone, and no near-duplicate
measure was introduced, per §12's instruction not to quantise coordinates on
this evidence.

Skeleton-level duplication (§13) is therefore reported as what it is: the
generator's 24 bearings are 12 questions asked twice at the first leg and 24
distinct questions after it, and the memo is the right place for the first
kind.

## Speculative concurrency

`mapWithConcurrency` checks its stop condition **before taking the next item
and never afterwards**. A candidate build is a chain of seven to ten sequential
engine calls, so the unit of speculation is a whole build, not a call. Nothing
is cancelled: `options.signal` is the walker's request being abandoned, not the
batch deciding it has enough.

Measured at the retained algorithm, by sweeping the fan-out with everything
else held fixed — every level returns identical walks on all six fixtures, so
this is speculation and nothing else:

| fan-out | wall ms | GH calls | speculation over one-way |
|---:|---:|---:|---:|
| 1 | 3,919 | 1,122 | — |
| 2 | 2,287 | 1,193 | +71 |
| 3 | 1,930 | 1,246 | +124 |
| **4** | **1,850** | **1,297** | **+175** |
| 5 | 1,972 | 1,382 | +260 |
| 6 | 1,941 | 1,450 | +328 |
| 8 | 2,058 | 1,626 | +504 |

And the same sweep at the Phase 3A baseline:

| fan-out | wall ms | GH calls |
|---:|---:|---:|
| 1 | 5,337 | 1,506 |
| 4 | 2,229 | 1,736 |
| 6 | 2,237 | 1,869 |

Classified per §17, at the retained algorithm and four-way: 1,122 calls are
necessary, 175 are speculative, and of the speculative ones **150 belong to 43
builds that never reached a verdict at all** — dispatched, run to completion,
and dropped because they fell past the prefix that decided the stop.

## Scheduling experiment (B4)

| strategy | wall ms | GH calls | candidates attempted | walks offered |
|---|---:|---:|---:|---|
| six-way, Phase 3A algorithm | 2,237 | 1,869 | 24 per batch | 3/3/3/3/1/1 |
| six-way, Phase 3B algorithm | 1,941 | 1,450 | 24 | 3/3/3/3/1/1 |
| **four-way, Phase 3B algorithm** | **1,850** | **1,297** | 24 | 3/3/3/3/1/1 |
| three-way, Phase 3B algorithm | 1,930 | 1,246 | 24 | 3/3/3/3/1/1 |

**Four is now both faster and cheaper than six.** Phase 3A found four
"indistinguishable from six" and kept six; that was true of an algorithm where
a third of the calls were fix-ups. With the fix-ups removed a build is shorter,
so a wave lands closer together, so a wider fan-out overshoots the stop by
more. Three is 51 calls cheaper than four and 80 ms slower, and §30's rule —
the product metric is the walker's wait — settles it at four.

No staged wave scheme was built. §18's `6+6+6+6` and `8+8+8` shapes are the
same experiment as this sweep with an extra barrier between waves, and the
sweep already shows the curve is flat between three and six and rising outside
it; a barrier would add the cost of the slowest member of each wave, which is
the mechanism that made Phase 3A's batching lose.

## Cancellation

Not built, and the numbers say not to. In-flight speculation at four-way is 175
calls, of which 150 sit in builds that a candidate-level check between legs
could have cut short — but those builds already average 3.5 calls each because
`abandonAboveMetres` cuts most of them off early, so what is recoverable is a
fraction of 150 in a workload of 1,297. §20's own instruction applies: the
better answer is not to dispatch, and not dispatching is what the fan-out
change does.

## Candidate pre-screening

Nothing was built, and the false-rejection analysis is why. §14 permits a
reject only on information already held. The one candidate class worth
rejecting is the corner-count wave that will produce nothing, and peel-5km is
the case that makes it look attractive — its 24 three-corner builds cost 313
calls and pass **zero**. But the evidence refuses the rule:

| fixture | wave | builds | calls | passed | distance ÷ target, median | max |
|---|---:|---:|---:|---:|---:|---:|
| **peel-5km** | 3 | 24 | 313 | **0** | 0.90 | 1.19 |
| douglas-5km | 3 | 24 | 291 | 5 | 0.92 | 1.39 |
| douglas-3km | 3 | 20 | 215 | 7 | 1.00 | 1.91 |
| onchan-5km | 3 | 17 | 181 | 4 | 0.97 | 1.30 |
| wp-two | 3 | 24 | 258 | 4 | 0.99 | 1.41 |

Peel's failing wave and Douglas's passing one are indistinguishable on every
cheap statistic available before the gate runs: same median distance ratio,
same shape, same failure mix. A screen that killed peel's wave would kill
douglas-5km's five passing candidates with it. **Rejected on false-rejection
grounds**, per §14's requirement, rather than tuned until it looked acceptable.

## Cumulative benchmark

Each stage its own service, its own flags, seven warm generations per fixture,
the median reported. Wall ms / calls:

| stage | douglas-5km | douglas-3km | peel-5km | onchan-5km | wp-one | wp-two | total ms | total calls |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **B0** baseline | 360 / 291 | 223 / 221 | 614 / 743 | 170 / 181 | 117 / 34 | 715 / 379 | **2,199** | **1,849** |
| B1 join-pullback | 507 / 420 | 194 / 201 | 607 / 725 | 163 / 167 | 118 / 34 | 1,022 / 619 | 2,611 | 2,166 |
| B2 leg-budget | 355 / 275 | 219 / 220 | 627 / 750 | 169 / 180 | 121 / 34 | 717 / 373 | 2,208 | 1,832 |
| B3 backtrack retry | 328 / 266 | 130 / 131 | 516 / 629 | 164 / 173 | 120 / 34 | 698 / 363 | 1,956 | 1,596 |
| B5 best attempt | 355 / 285 | 224 / 227 | 771 / 731 | 180 / 198 | 119 / 34 | 732 / 383 | 2,381 | 1,858 |
| B6 = B1+B2+B3+B5 | 364 / 241 | 175 / 115 | 588 / 601 | 141 / 144 | 117 / 34 | 636 / 302 | 2,021 | 1,437 |
| B6 without B1 | 312 / 258 | 139 / 128 | 581 / 650 | 156 / 168 | 117 / 34 | 705 / 359 | 2,010 | 1,597 |
| **B6 without B5** | 330 / 238 | 130 / 113 | 547 / 591 | 150 / 148 | 120 / 34 | 636 / 302 | **1,913** | **1,426** |

The retained combination is the last row, plus the fan-out at four.

Where the calls went, before and after:

| purpose | B0 | retained | change |
|---|---:|---:|---:|
| `leg` | 1,010 | 815 | −19.3% |
| `join-pullback` | 416 | 260 | **−37.5%** |
| `waypoint-leg` | 147 | 147 | 0.0% |
| `leg-budget` | 201 | 142 | −29.4% |
| `spike` | 59 | 51 | −13.6% |
| other | 10 | 11 | |
| **total** | **1,843** | **1,426** | **−22.6%** |

The remaining fix-ups all earn their calls: `spike` is kept 83% of the time,
`join-pullback` 75%, `leg-budget` 71%. **There is no under-performing fix-up
left to gate.**

## The gate

Four alternating rounds, a fresh service per arm per round, each fixture the
median of seven warm generations.

| fixture | P3A ms | P3B ms | change | P3A calls | P3B calls | change |
|---|---:|---:|---:|---:|---:|---:|
| douglas-5km | 366 | 351 | −4.1% | 291 | 238 | −18.2% |
| douglas-3km | 222 | 113 | **−49.1%** | 221 | 96 | **−56.6%** |
| peel-5km | 652 | 516 | −20.9% | 743 | 530 | −28.7% |
| onchan-5km | 173 | 139 | −19.7% | 181 | 127 | −29.8% |
| wp-one | 121 | 127 | +5.0% | 34 | 34 | 0.0% |
| wp-two | 726 | 642 | −11.6% | 379 | 285 | −24.8% |
| **total** | **2,255** | **1,904** | **−15.6%** | **1,849** | **1,310** | **−29.2%** |

| paired within each round | |
|---|---|
| P3A round totals | 2,247 / 2,142 / 2,281 / 2,255 — spread **6.5%** |
| P3B round totals | 1,904 / 2,039 / 1,853 / 1,862 — spread 10.0% |
| P3B against P3A, round by round | −15.3% / −4.8% / −18.8% / −17.4% — median **−16.4%** |
| calls, round by round | 1,849 / 1,849 / 1,843 / 1,849 → 1,310 / 1,310 / 1,297 / 1,297 |

**The call reduction is deterministic to within thirteen calls; the wall-time
reduction is not.** Round two returned −4.8% where the others returned −15% to
−19%, and P3A's own spread across four measurements of itself is 6.5%. The
median of the paired differences is the honest figure and it is −16.4%; the
pooled one is −15.6%. Both are well outside the baseline's spread, and neither
reaches 20%.

`wp-one` is unchanged in both columns and always will be: it never routes a
ring, so none of the three retained changes can reach it.

## Route-quality regression

| fixture | walks | distance, P3A → P3B | quality | repeated % | geometry |
|---|---|---|---|---|---|
| douglas-5km | 3 → 3 | 5064, 4930, 4446 → 4930, 4433, 5398 | 82.6, 82.5, 58.7 → 82.5, 55.9, 69.4 | 0.2, 0.1, 1.3 → 0.1, 0.7, 0.0 | differs |
| douglas-3km | 3 → 3 | 3011, 2768, 2702 → 2806, 3192, 2768 | 81.9, 62.1, 57.9 → 70.9, 67.5, 62.1 | 0.6, 2.3, 0.3 → 0.5, 1.1, 2.3 | differs |
| peel-5km | 3 → 3 | 4877, 4727, 4885 → 4930, 4885, 4877 | 72.7, 63.6, 63.3 → 74.1, 63.3, 72.7 | 1.8, 2.2, 1.8 → 2.3, 1.8, 1.8 | differs |
| onchan-5km | 3 → 3 | 4850, 5034, 5295 → 4850, 5180, 5295 | 76.3, 69.8, 57.4 → 76.3, 59.6, 57.4 | 1.1, 4.3, 6.9 → 1.1, 3.9, 6.9 | differs |
| wp-one | 1 → 1 | 6911 → 6911 | 57.2 → 57.2 | 0.4 → 0.4 | **identical** |
| wp-two | 1 → 1 | 9410 → 9410 | 51.3 → 51.3 | 0.3 → 0.3 | **identical** |

| across all fourteen offered walks | P3A | P3B |
|---|---:|---:|
| walks offered | 14 | **14** |
| mean quality | 66.9 | 65.7 |
| total u-turns across the offered set | 1 | **1** |
| mean repeated ground | 1.69% | **1.66%** |
| mean distance error | 6.0% | 6.6% |

**The routes change, and they change because B1 and B3 change what is asked
for, not because of scheduling.** The fan-out sweep confirms this directly: all
five fan-out levels return byte-identical walks on all six fixtures, at both
algorithms. Every walk that differs differs because a leg was aimed
differently.

The offered set is equivalent in count on every fixture, better on retracing
by a hair, and 1.2 points worse on mean quality — a shift of the same size as
the difference between two adjacent candidates from one bearing. Peel improves
(66.5 → 70.0 mean quality), Douglas 5 km and Onchan lose a point or two,
Douglas 3 km and both waypoint fixtures are level. **This is not a quality
trade in either direction so much as a reshuffle**, and it is stated rather
than averaged away because §29 asks for it stated.

The two waypoint fixtures return byte-identical geometry, which is the check
that the retained changes do only what they claim: `wp-one` routes no ring at
all, and `wp-two` routes its rings through the same code and comes back with
the same walk.

## Remaining bottlenecks, ranked by measured contribution

1. **Candidate volume — 76% of what is left.** 1,086 of 1,426 calls go to
   candidates the quality gate refuses, and 727 of those to loops that came
   back the wrong length. No fix-up remains that does not earn its call; what
   remains is 186 builds to find 27 passing candidates to offer 14 walks.
2. **The aim, and specifically undershoot.** Three quarters of distance
   failures are short. The corner legs meet their planned shares — median
   got ÷ planned 1.06 to 1.12 across all three corners — and the closing leg
   is never planned at all: it is however far home happens to be, and it comes
   back at a median **1.94×** the budget that was left for it. A ring whose
   last leg is unplanned cannot be aimed at a length, and no leg-level retry
   can fix an aim.
3. **The exchange rate — half.** 29.2% of the calls returned 15.6% of the
   clock, holding Phase 3A's prediction to a fifth of a point. A memoised or
   removed call still costs Looper everything it does around one, and a
   generation's wall time is not the sum of its calls.
4. **Speculation — 175 calls at four-way**, 13% of the workload, of which 150
   sit in builds that ran to completion past the deciding prefix. Bounded, and
   bounded further only by dispatching less, which costs wall time faster than
   it saves calls below four.
5. **Everything Phase 3A ranked** — the 0.58 ms per-exchange floor, contention
   between concurrent legs, `hopper.route` at 1.34 ms — unchanged, and now
   multiplied by 1,310 instead of 1,849.

## Recommendation for the next phase

> **Is Looper's current high-level loop-generation algorithm efficient enough
> to take forward, or does the next phase need a structural redesign of
> candidate generation?**

**It needs the redesign, and the analysis says precisely which part.**

The fix-up machinery is now in good order and should be left alone. Three
quarters of every fix-up call is kept, no fix-up chain runs deeper than three,
no seam is repaired twice, and the one retry criterion that did not work has
been removed. There is no second B3 waiting in the fix-ups; this phase went
looking and the keep rates say there is nothing left to gate.

What is not in good order is that **Looper builds 186 candidates to offer 14
walks, and 76% of every call it makes is spent on one it throws away.** That is
not a fix-up problem and it cannot be reached from the boundary, from
scheduling, or from another retry rule. It is the shape of the search: 24
bearings, blind, each committed to a fixed compass turn, each aiming its corner
legs at even shares of a budget and then discovering how long the way home
happens to be.

The specific defect to attack is the closing leg. Every ring plans `cornerCount`
legs and then closes with one nobody planned, at a median 1.94× whatever budget
was left for it. Three quarters of the distance failures are the consequence,
and they cost 727 calls in a workload of 1,426. **A generator that chose its
corners so the loop closed at the right length would not need most of the
candidates it currently builds**, and by this phase's own measured exchange
rate, removing 40% of the calls is what a 20% wall-time improvement costs.

That is a change to how candidates are generated, not to how they are routed or
scheduled, and it is squarely what Phase 3B was asked to find out. It is not
implemented here.

## What is retained, and how to turn it on

```
LOOPER_PULLBACK_REUSES_PREVIOUS=true   # trim the previous leg instead of routing it again
LOOPER_BACKTRACK_NEEDS_BUDGET=true     # a short backtrack alone no longer forces a retry
LOOPER_BUDGET_ONCE_PER_LEG=true        # the cheaper reroute asked once per leg
ROUTING_CONCURRENCY=4                  # was 6
```

plus Phase 3A's two, which are still worth their 65% of the wire and now ride
on 29% fewer calls:

```
LOOPER_MODEL_REGISTRY=true
LOOPER_ROUTE_MEMO=true
```

All three new switches ship **off**, as `AlgorithmFlags` requires and for the
reason it requires it: they change which walks are offered. The fan-out is not
a flag because it changes nothing about a walk — every level returns identical
geometry — and four is simply better than six at the retained algorithm.

**Turn the first three on together or not at all.** B1 measured *worse* alone
than the baseline and better than B3 alone when combined with it, and that is
not a curiosity: a trimmed leg is a shorter leg, and B3 is what stops a shorter
leg being retried into the ground.

`LOOPER_KEEP_BEST_LEG_ATTEMPT` is implemented, tested and left off. It is
correct in isolation — 84 of 145 exhausted leg steps keep an attempt that was
not their closest fit — and it costs 108 ms to buy eleven calls, which is the
wrong side of this phase's own exchange rate.

## Equivalence and what was not touched

All 484 unit tests pass unchanged. No GraphHopper version, profile, custom
model, avoidance multiplier, landmark setting, routing algorithm, traversal
mode or path detail was altered. No custom algorithm, multi-target request,
shared search tree, CH change or graph-format change was written; nothing in
§35 was approached.

The retained changes touch three places: where a pulled-back corner is chosen
(`applyJoinPullback`), when a leg is retried (`attemptLeg`), and how often the
cheaper reroute is asked (`routeLegAttempt`). Everything else in the generator
is as Phase 3A left it.
