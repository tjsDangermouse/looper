# Loop generation: implementation report

Work carried out in seven phases against the baseline recorded in
`routing-baseline.md`. Every phase is behind its own flag; three ship on, five
ship off, and the evidence for each decision is below.

## 1. Architecture, after

Unchanged in outline. GraphHopper 11 with the custom `foot` profile, landmarks,
CH deliberately disabled, ordinary point-to-point legs, deterministic
multi-start candidates, soft avoidance corridors, hard gates then weighted
score, diversity selection, per-request and global concurrency limits. No new
routing dependency and no paid service.

What changed underneath:

- **Overlap is measured on the network.** GraphHopper is asked for `edge_id`
  path details, and retracing and route-to-route similarity are computed from
  the edges a walk actually traversed, length-weighted. Geometry remains the
  truth for shape, spikes, bounding boxes, compactness, avoidance corridors and
  rendering, and remains the fallback wherever edge ids are absent.
  (`loops/edges.ts`)
- **Candidate bearings are dispatched spread round the compass** rather than in
  order round it, so stopping partway leaves a sample of the ground rather than
  one quarter of it. (`loops/candidates.ts`)
- **Waypoint mode is a different algorithm.** Ordered anchors, a routed
  backbone, a slack budget, per-gap alternatives, and a bucketed dynamic
  programme that spends the slack across the gaps. (`loops/waypoints.ts`)
- Five further algorithms are implemented, tested and switched off:
  diversity-aware stopping, a Pareto archive, bounded local repair,
  network-aware seeding, two-stage screening, and an exact request cache.

## 2. Phase by phase

### Phase 0 — baseline, instrumentation, fixtures ✅

Audit in `routing-baseline.md`. Added `loops/metrics.ts` (engine calls by
purpose, candidate counts, rejection reasons, repairs, early-stop reason,
overlap source, per-candidate timings — no coordinate anywhere in it), and
`bench/`: twenty deterministic scenarios over five synthetic pedestrian
networks with real nodes, real edges, a real Dijkstra search, and GraphHopper's
own JSON parsed by the service's own `parseLeg`.

Two findings worth carrying forward:

- **The profile's route is not a lower bound on distance.** Every priority rule
  in `looper_foot.json` is a multiplier at or below 1, and GraphHopper divides
  by priority, so the weight-minimal route can be physically longer than the
  shortest one. The existing 125% waypoint check therefore over-estimated the
  minimum and could refuse a walk that was actually possible. Phase 4 fixes it.
- **`edge_id` was never actually requested**, despite a comment claiming it was
  a supporting signal for repeat detection.

**One production defect found and fixed.** `@turf/union` throws on degenerate
corridor geometry — a walk doubling back along exactly the same line — and the
exception escaped `buildAvoidanceAreas` to fail the whole request with a 500
rather than losing one candidate. Merging is now an optimisation that may fail;
where corridors cannot be merged they are sent separately. This is the only
intentional behaviour change in Phase 0 and it only affects requests that
previously failed.

Files: `loops/metrics.ts`, `loops/avoidance.ts`, `graphhopper.ts`,
`loops/routing.ts`, `loops/generate.ts`, `server.ts`, `bench/*`,
`tsconfig.check.json`.

### Phase 1 — edge overlap and diversity-aware stopping ✅ / ❌

**`edgeOverlap` — on.** −2% calls on its own, −15% with the bearing spread,
identical routes, and it is the only measure that can tell a back lane from the
road it runs behind. Geometry fallback tested and kept.

**`spreadCandidateBearings` — on.** Found while diagnosing why diversity-aware
stopping never fired: attempts were emitted in order round the dial, so any
prefix covered one arc. Bit-reversing the dispatch order costs nothing and is a
strict win — **−13.8% engine calls and better-separated alternatives**.

**`diversityAwareEarlyStop` — off.** Implemented, order-independent (the stop
decision is taken on an unbroken *prefix* of attempts, so it cannot depend on
which routing calls were quick), and tested. It costs **+30% engine calls over
the bearing spread alone for 0.5 percentage points of extra separation.** The
mechanism is sound and the price is not.

Files: `loops/edges.ts`, `loops/flags.ts`, `loops/quality.ts`,
`loops/diversity.ts`, `loops/candidates.ts`, `graphhopper.ts`, `config.ts`.

### Phase 2 — Pareto archive and local repair ❌ / ❌

**`paretoArchive` — off.** Non-dominated filtering across five cost dimensions,
taken *per compass octant* — a first attempt across the whole batch dropped
uniquely-directed candidates and measurably hurt diversity, because direction
is not one of the traded dimensions. Per-octant is provably harmless and
changes nothing measurable: the candidate pools are too small for a front to
bind. Kept, off, until something produces a pool large enough to mean anything.

**`localRepair` — off.** One bounded, aimed rebuild for a candidate that failed
exactly one gate and failed it narrowly, with a strict per-request call budget.
It works: **four in five repairs succeed, for about five calls each, +11
passing candidates for +1.7% calls.** And the walks offered do not improve for
it — the extra candidates rank well and separate badly, and mean alternative
overlap worsens from 26.3% to 29.5%. Better pool, worse offer. Off.

Files: `loops/pareto.ts`, `loops/repair.ts`, `loops/generate.ts`,
`loops/routing.ts` (`preAvoidGeometries`), `loops/quality.ts`.

### Phase 3 — network-aware seeds ❌

**`networkAwareSeeds` — off.** One shortest-path-tree probe per request
summarises reach and network stretch per 30° sector, and candidate bearings
with real network behind them are dispatched first. Deliberately a reordering
and never a cull: a probe does not get to veto a direction.

It does exactly what it is for — **coastal −13%, promenade −11% engine calls** —
and costs one call everywhere else, netting **−0.5%** across this fixture mix.
Worth switching on for a coastal region and measuring there; not worth
switching on everywhere on that evidence. Bridge and rural fixtures do not
improve, correctly: a chokepoint is not a reachability problem.

Files: `loops/network.ts`, `graphhopper.ts` (`/spt` with timeout and fail-open),
`server.ts`, `config.ts`, `bench/network.ts`.

### Phase 4 — waypoint backbone and slack allocation ✅

**`waypointBackbone` — on. The largest single win.**

Each anchor gap is routed once directly; those routes are both the backbone
`B` and the "spend nothing here" option, so nothing is paid for twice. Slack
`Δ = K − B` is offered to each gap as a handful of detours of different sizes,
placed allowing for the network stretch measured on that gap's own direct
route. A bucketed dynamic programme picks one option per gap, preferring
combinations that spread the slack rather than dumping it in one place, and
returning several combinations that differ in *which* gaps they spend in.

The lower bound is checked properly: only when the ordinary routes already look
too long is a shortest-path model (`distance_influence`) used to establish a
real floor before refusing, with a 5% tolerance for snapping. A request that
plainly fits never pays for it.

A pin on the doorstep is handed back to the ordinary loop generator — a
backbone of nearly nothing and slack of nearly everything is not a route
problem.

Waypoint mode, baseline → shipping:

| | baseline | shipping |
| --- | --- | --- |
| engine calls | 1,498 | **227** (−85%) |
| scenarios producing walks | 5/7 | **7/7** |
| routes offered | 12 | 13 |
| worst distance error | 20.8% | **10.0%** |
| alternative overlap (mean) | 36.2% | 65.1% |

Two fixtures that previously returned nothing — a pin across a chokepoint and a
pin at the end of a promenade — now return walks.

**The honest cost is the last row.** Waypoint alternatives now share much more
ground. That is largely real: where pins force every walk over the same bridge,
every walk shares the bridge. But it is a genuine regression in choice, and the
unbounded score-based top-up that used to paper over it has been removed in
favour of a single relaxation of the separation bar to 80% — because three
walks that are 95% the same walk are one walk with two extra taps to dismiss.

Files: `loops/waypoints.ts`, `loops/generate.ts`, `loops/avoidance.ts`.

### Phase 5 — two-stage screening ❌

**`twoStageScreening` — off, and the reason is the interesting part.**

Stage A routes the bare ring for every bearing in one multi-point request with
no avoidance and no repair, screens on loose thresholds, and passes only the
survivors to the full incremental build.

HTTP calls barely move (+1%). **Path searches inside the engine rise 37%**
(3,244 → 4,432), with no extra walks offered and no latency gained. This is
exactly the trap the brief warned about: putting a whole ring in one request
saves round trips, not the engine's work. The benchmark now counts routed legs
separately from HTTP calls for precisely this reason.

Coastal is the one clear win (−46% calls), the same case network-aware seeding
addresses more cheaply.

Files: `loops/screening.ts`, `loops/generate.ts`, `loops/metrics.ts`,
`bench/network.ts` (honest multi-point routing).

### Phase 6 — request cache ❌ (recommended first to enable)

**`requestCache` — off.** A bounded LRU with TTL, keyed on graph version,
region, profile, profile version, algorithm flags, generation settings and
every field of the request, with coordinates at full precision — rounding a
start point is how a cache serves a walk from the next street over. Refusals
get a much shorter TTL than answers, because "no clean loop here" is a
statement about a moment as much as a place.

Only finished answers are stored, and two callers never share one in-flight
computation: an entry nobody can abort halfway cannot be corrupted halfway.
The graph version is re-asked every five minutes rather than fixed at start-up,
so a reimport under a running service invalidates naturally.

Off because there is no measurement of hit rates here — but its correctness
rests on key tests rather than on benchmarks, which makes it the safest of the
unproven flags to enable first, watching the `cacheHits`/`cacheMisses` metrics.

Load testing was not possible in this environment. What could be tested is
tested: the concurrency limiter is now proven not to leak a permit when work
throws, when a waiting caller aborts, when the queue is full and callers are
refused, or across a 200-request burst mixing all three.

Files: `loops/cache.ts`, `server.ts`, `config.ts`.

### Phase 7 — chokepoints ⏸ not implemented

Written up in `chokepoints-spike.md` with a design and a benchmark plan
instead. The short version: the structural-retrace signal is **already
available at zero extra cost** — a leg that came back `relaxed`, or whose spike
reroute failed, has already demonstrated there is no way round, and that fact
is currently discarded. But relaxing the retrace gate is the highest-risk
change in this brief, the only fixtures available are synthetic networks whose
chokepoints I placed myself, and a detector that finds a bridge I told it about
is not evidence. Not shipped.

## 3. Benchmark

`npm run bench` in `route-service/`. See `bench/README.md` for what the numbers
do and do not mean — call counts and route quality are exact and comparable
across machines; wall-clock timings are only comparable within one run.

Overall, twenty scenarios:

| | baseline | shipping | change |
| --- | --- | --- | --- |
| valid scenarios | 18/20 | **20/20** | +2 |
| routes offered | 50 | 51 | +1 |
| engine calls | 5,373 | **3,244** | **−40%** |
| routed legs | 5,373 | 3,244 | −40% |
| median wall time | 517 ms | **235 ms** | −55% |
| p95 wall time | 1,230 ms | **717 ms** | −42% |
| fallback (retracing) uses | 0 | 0 | — |

Split by mode, which the overall figures hide:

| standard mode | baseline | shipping |
| --- | --- | --- |
| engine calls | 3,875 | 3,017 (−22%) |
| routes offered | 38 | 38 |
| valid scenarios | 13/13 | 13/13 |
| median distance error | 4.4% | 4.4% |
| max alternative overlap (mean) | 28.3% | **22.3%** |

| waypoint mode | baseline | shipping |
| --- | --- | --- |
| engine calls | 1,498 | **227 (−85%)** |
| routes offered | 12 | 13 |
| valid scenarios | 5/7 | **7/7** |
| worst distance error | 20.8% | **10.0%** |
| max alternative overlap (mean) | 36.2% | 65.1% |

Each flag on its own, against the shipping set:

| flag | engine calls | routed legs | routes | verdict |
| --- | --- | --- | --- | --- |
| `edgeOverlap` | −2% alone, −15% with spread | same | same | **on** |
| `spreadCandidateBearings` | −13.8% | same | same | **on** |
| `waypointBackbone` | −85% on waypoints | same | +1, +2 scenarios | **on** |
| `diversityAwareEarlyStop` | +30% | same | same | off |
| `paretoArchive` | 0% | same | same | off |
| `localRepair` | +1.7% | same | same, worse separation | off |
| `networkAwareSeeds` | −0.5% | same | same | off |
| `twoStageScreening` | +1% | **+37%** | same | off |
| `requestCache` | not measurable offline | — | — | off |

## 4. Tests

`npm test` — **401 passing** (209 at baseline). `npm run typecheck`,
`npm run lint` clean.

New suites: `edges`, `pareto`, `repair`, `network`, `waypoints`, `screening`,
`cache`, `metrics`, plus additions to `generate`, `candidates`, `avoidance` and
`concurrencyLimiter`.

Covering, as required: length-weighted edge overlap; repeated traversal of one
edge; route-to-route shared edges; geometry fallback; **parallel-but-distinct
paths not treated as shared**; Pareto dominance and stable tie-breaking;
diversity-aware stopping; completion-order and concurrency independence;
single-failure repair eligibility, separately from execution; repair budget
enforcement; **waypoint immutability under every flag**; ordered backbone;
distance and duration lower-bound feasibility; slack allocation across gaps; DP
state bounds and determinism; network-aware seed fallback; cache key
completeness; and cancellation and semaphore release.

## 5. Public API and configuration

**No breaking change.** Response shape, warnings, route labels and error shapes
are untouched. `diagnostics` gains a `metrics` object; the contract already
reserves extra diagnostic fields for the service's own tools, and no client
reads them.

New configuration, all optional and all defaulting to current behaviour — see
`.env.example`: nine `LOOPER_*` algorithm flags, `NETWORK_PROBE_TIMEOUT_MS`,
`ROUTE_CACHE_*`, and `GRAPHHOPPER_PROFILE_VERSION` (bump by hand when
`looper_foot.json` is retuned; it invalidates every cached answer).

## 6. Risks and limitations

- **No live GraphHopper and no Docker in this environment.** Every number here
  comes from synthetic networks. `edge_id` support, `/spt` availability, real
  snapping, real network stretch and real latency are all **unverified**. Each
  depends on a runtime probe with a fallback rather than an assumption, but
  "falls back correctly" is not the same as "works".
- **The synthetic networks cannot exhibit the failure mode edge overlap fixes.**
  A grid has no pavement twelve metres from another pavement, so geometry and
  edge measurement agree to within 1.5 points on every fixture. The case for
  edge overlap rests on the unit test that constructs it directly, plus the
  argument, not on the benchmark.
- **Waypoint alternatives now share much more ground** (36% → 65% mean). Partly
  real, partly a consequence of building all alternatives from one backbone.
  The first thing to look at next.
- **`waypoint-suburban` returns one walk where the baseline returned three**,
  and hits the distance no better. Cul-de-sac ground gives the per-gap detours
  little to work with.
- **Waypoint route counts are sensitive to the detour ladder and the assembly
  limit.** Small changes moved individual fixtures between 1 and 3 routes while
  the totals stayed flat, which is a sign of a fixture set too small to tune
  against. Treat the current constants as provisional.
- **No load test.** Concurrency and queue defaults remain untuned against real
  traffic, exactly as they were.
- Repair and screening ran once each per configuration; wall-clock figures are
  single-run medians on one machine.

## 7. Recommended rollout

One at a time, checking the `cost` log line between each.

1. **Already on** — `edgeOverlap`, `spreadCandidateBearings`,
   `waypointBackbone`. Watch `overlapFromGeometry`: if it is not near zero in
   production, the engine is not returning `edge_id` and the geometry fallback
   is carrying everything.
2. **`requestCache`.** Lowest risk, correctness established by tests. Watch
   `cacheHits`/`cacheMisses` for a week before drawing conclusions about TTLs.
3. **`networkAwareSeeds`, Isle of Man only.** It is a coastal region and this is
   the case the flag is for. Measure there; do not roll it to England on an
   Isle of Man result.
4. **Re-measure `localRepair` against real ground.** Its benefit is a better
   candidate pool; the synthetic fixtures always had enough candidates for
   three offers, so the benefit had nowhere to show. Real sparse ground may
   differ. It has a strict call budget either way.
5. Leave `diversityAwareEarlyStop`, `paretoArchive` and `twoStageScreening` off.
   Two of the three have measured costs and no measured benefit; the third
   needs a pool nothing currently produces.

Rollback is a flag per change; nothing here requires a redeploy to undo.

---

# Addendum: what production actually said

Written after the above shipped and real traffic was measured. It corrects two
claims in it.

## The benchmark was measuring the wrong thing

Five production requests across the Isle of Man, against the deployed service:

| start | wall | calls | `leg` | `join-pullback` | `leg-budget` | `spike` |
| --- | --- | --- | --- | --- | --- | --- |
| Douglas 5 km | 4.8 s | 472 | 262 | 126 (27%) | 74 | 10 |
| Douglas 3 km | 1.8 s | 230 | 135 | 64 (28%) | 29 | 2 |
| Douglas 10 km | 4.9 s | 284 | 166 | 82 (29%) | 33 | 3 |
| Peel 5 km | 10.1 s | 961 | 551 | 258 (27%) | 114 | 35 |
| Onchan 5 km | 4.5 s | 401 | 238 | 102 (25%) | 54 | 7 |

**Fix-up retries are 43% of every engine call**, consistently, everywhere. The
synthetic fixtures produced 3.2% and no spikes at all, because the synthetic
engine snapped requested points to *junctions*. GraphHopper snaps to the
nearest point **on an edge**, and that single difference is what creates the
dead-end joins the fix-ups exist to repair. A benchmark that cannot produce a
dead-end join cannot measure what fixing one costs — so every phase above was
tuned against a fixture set blind to nearly half the real work.

`bench/network.ts` now snaps to edges. The fixtures reproduce production's
profile (24.3% pullback against 25–29%), and the numbers below were measured
on that.

## Which fix-ups earn their calls

| fix-up | attempted | kept | calls each | wasted calls |
| --- | --- | --- | --- | --- |
| `join-pullback` | 765 | **72%** | 2 | 428 |
| `leg-budget` | 607 | **34%** | 1 | 399 |
| `spike` | 24 | **0%** | 1 | 24 |

`join-pullback` is the biggest line item and mostly earns it — the opposite of
what I assumed when I called it "the obvious target". `leg-budget` is the
waster: two calls in three come back no shorter.

Two gates, both on by default:

- **`pullbackTurnOnly`** — a short branch straddling a leg seam is spliced out
  of the finished walk for free by the tiny-spike trim, which reaches further
  (80 m round trip) than the detector that triggers the pullback (~40 m). Two
  engine calls were being spent to route around something already removed for
  nothing. **−6.4% calls, identical walks, and better-separated alternatives**
  (27.0% → 23.3% mean overlap).
- **`budgetDetourGate`** — a leg only shortens under a weaker penalty if the
  penalty is what made it long. One running under twice its straight-line
  distance did not go round anything. **−1.8% calls**, and it raises the
  fix-up's own keep rate from 34% to 39%.

Together: **−8.2% engine calls, 50 routes offered either way, no gate changed.**

## The largest remaining lever is not an algorithm

| start | engine time | wall | achieved parallelism |
| --- | --- | --- | --- |
| Douglas 5 km | 21.5 s | 4.8 s | 4.4× |
| Douglas 3 km | 7.1 s | 1.8 s | 3.9× |
| Peel 5 km | 49.5 s | 10.1 s | 4.9× |

GraphHopper answers a foot leg in **30–65 ms**. The wait is almost entirely
serialisation, not engine speed, and achieved parallelism is 3.8–4.9 against a
`ROUTING_CONCURRENCY` limit of 6 — the shortfall is that each candidate's legs
must be routed in order, and the tail of a batch runs with fewer than six in
flight.

Doubling per-request concurrency projects **Douglas 5 km at ~1.8 s (from 4.8 s)
and Peel at ~4.1 s (from 10.1 s)** — far more than any algorithm change here
delivered. It is a projection from measured engine time, not a measurement:
per-call latency may rise under load. It costs one environment variable to
find out, and `GRAPHHOPPER_MAX_CONCURRENCY` should rise with it.

## Waypoint mode does not work on real ground

Three waypoint requests around Douglas, all well inside their plans, all
returned **no routes at all**, taking 5.5–10.3 s to do so:

```
wp-near-6km   5.5s  routes=0  "We couldn't make a clean loop through those waypoints"
wp-far-8km    7.5s  routes=0  same
wp-two-8km   10.3s  routes=0  same
```

That message comes from the *old* generator, so the backbone path produced
nothing that passed the gates and fell through to code whose behaviour has not
changed — which means waypoint mode was very likely already failing this way
before Phase 4, and Phase 4 now adds wasted calls ahead of the same failure.
It is not established either way, because **waypoint mode reports no
`diagnostics` at all**, so there is no way to see which stage gave up.

The most likely cause, from the design: each anchor gap's alternatives are
routed independently, so nothing stops the return gap retracing the outward
one, and the assembled walk is refused on `repeated-corridor`. The synthetic
grid had enough parallel streets for the DP to find combinations that missed
each other; a real town does not.

**This is the most important open item in this document**, and it is
user-visible in a way none of the call-count work is. It needs, in order:
diagnostics on the waypoint path so the failing stage is visible; then almost
certainly routing later gaps against the earlier gaps' chosen ground.

## What this changes about the recommendations above

The rollout order in §7 stands, with two corrections:

- Raising `ROUTING_CONCURRENCY` should come **first**. It is the only change
  measured here that a walker would notice.
- Every "off, no measured benefit" verdict above was reached against fixtures
  that missed 40% of real engine work. `localRepair` in particular deserves
  re-measuring against the edge-snapping fixtures before it is written off.

---

# Addendum 2: what was actually wrong with waypoint mode

The addendum above said waypoint mode failing was "the most important open
item" and guessed at the cause. The guess was wrong, twice, and the diagnostics
added to find out are what eventually found it.

## The bug

`buildLoopIncrementally` finishes with `trimTinySpikes(joinLegGeometries(legs))`.
The trim splices out any backtrack under an 80 m round trip — the short duck
into a driveway that the ground genuinely offers no way round, small enough
that showing it does more harm than quietly not showing it.

Both waypoint generators joined their legs and never trimmed them. Every one
of those forty-metre spikes survived into the finished walk, and
`out-and-back-spur` — which refuses any reverse run under 500 m — threw the lot
out. Measured on the deployed build: **20 of 24 assembled walks**, against
`repeated-corridor` at 1.

This predates the backbone work entirely. The older guide-point generator
joined without trimming too, so both paths failed the same way for the same
reason, and waypoint mode has been broken like this for as long as it has
existed.

Joining and trimming are now one exported step, `joinAndTrimLegs`, used by all
three builders.

## What it did, measured on production

| | before | after |
| --- | --- | --- |
| wp-one | 0 routes, 7.0 s, 353 calls | **2 routes, 0.6 s, 34 calls** |
| wp-two | 0 routes, 11.8 s, 528 calls | **1 route, 0.8 s, 54 calls** |
| stage | `legacy-empty` | `backbone` |
| plans enclosing ground | unknown | 24 of 24, best shape 0.64–0.68 |

Standard loops unchanged: 415 calls and 5.0 s at Douglas either way.

## The two wrong guesses, and what they cost

**"It's `repeated-corridor`, from gaps routed independently retracing each
other."** It was 1 of 24. The reasoning was plausible and the fixtures
supported it; nothing had measured it.

**"It's the shape ranking."** Half right. The allocation genuinely was ranking
a plan with a compactness of *zero* first — right length to within five metres,
enclosing no ground at all — and fixing that dropped `shapeless` from 18 to 14.
But the first attempt at the fix changed nothing at all, because the filter
governed only the three combinations picked for variety while the other twenty
were filled in unfiltered. A preference applied to three of twenty-four is not
a preference.

Both were caught only because the diagnostics report a stage and a rejection
tally. Before that, every one of these failures reached the walker as the same
sentence and reached the logs as nothing.

## What is still wrong

- **Suburban pins still fail** — `out-and-back-spur` 23 of 24 on the fixture.
  Cul-de-sac ground puts guide points down dead ends longer than the 80 m trim
  budget. The ring builder repairs exactly this with `applyJoinPullback`, and
  the waypoint builders never call it; guide points are the generator's own and
  may be moved, so that is the obvious next lever.
- **wp-one offers two walks and wp-two offers one**, not three. Fixed now
  rather than broken, but not finished.

## Corner-count sweep

Separately: an attempt tries corner counts until one passes, so the order is
the cost. Starting at three — what most ground wants — rather than at a
two-legged there-and-back is **6% of all engine calls for no change to what is
offered**, and slightly better distance error. Now the default.

Trying *only* the two shapes that usually work is **26%**, and costs about one
walk in twenty plus some separation between the ones that remain. That is a
trade rather than a win, so it is `LOOPER_NARROW_CORNER_SWEEP`, off.

## Guide-point repair

The ring builder repairs a corner that lands in a cul-de-sac: it pulls the
corner in and re-routes the two legs meeting there. The waypoint builders never
did, because they never asked — so a shaping point that landed down a dead end
forced the leg in and the leg out along the same short stub, and the walk was
refused for it.

`LOOPER_GUIDE_POINT_PULLBACK` applies the same repair at guide points. Only the
generator's own invisible shaping points are ever moved; a walker's pin is the
problem statement and is passed to the engine exactly as given, which is
asserted directly in the tests rather than assumed.

Measured across six waypoint fixtures:

| | off | on |
| --- | --- | --- |
| engine calls | 1,372 | **891** (−35%) |
| `u-turns` rejections | 22 | **0** |
| routes offered | 15 | 13 |
| suburban pin | 3 routes, 589 calls | 1 route, **42 calls** |

The U-turn column is the repair doing exactly what it is for. The route column
is the cost, and it is all one fixture: with the repair, suburban ground now
succeeds on the backbone path with a single walk instead of failing over to the
older generator, which found three at fourteen times the price.

Which of those a walker would rather have is a product question, not a routing
one — one walk in half a second against three in seven — so it ships off, with
the flag there to settle it against real ground. The case to watch is
`wp-one`/`wp-two`, which currently offer two walks and one: if the repair takes
those to three, it pays for the suburban regression several times over.

---

# Phase 8 — pins through the trim, minutes through the table, and the sweep turned inside out

Three things the post-Phase-7 review raised, checked against the code before
anything was built. Two were real, one was not.

## What the review got right

**Trimming was pin-blind.** `trimTinySpikes()` splices any reversal under 80 m
out of the *joined* geometry and never saw the anchors. Since Phase 4 put
`joinAndTrimLegs()` in front of all three builders, a pin at the tip of a short
cul-de-sac could be routed through correctly and then spliced back out — and
nothing downstream would notice, because every check on what we *asked for*
still passed. The trim now takes the walker's pins and refuses any splice that
would remove one. Guides are deliberately not protected: moving and trimming
round a guide is the whole point of the exercise.

The protected points are found again on every pass rather than carried and
remapped alongside the steps and edges. The trim runs to a fixed point, and a
pin is never what gets trimmed, so looking it up again cannot go stale the way
a carried index quietly can — which the nested driveway-off-a-cul-de-sac test
exists to hold in place.

**The slack table added up the wrong quantity.** `allocateSlack()` summed
`distanceMeters` and was handed `targetMetres` even in time mode. It now takes
a `measure` selector and adds up whichever quantity the walker asked for; every
option already carried both figures. The shaping *points* are still placed in
metres — a guide is a place on the ground, not a duration — which is the one
boundary where the two units legitimately meet.

## What the review got wrong, and it mattered

**The duration defect was narrower than described, and worse.** With a
walker-supplied pace, duration is a strict linear function of distance, so
bucketing distance was already exactly equivalent — no bug. The defect was
confined to time mode *without* a pace. And the real gap was not the bucket
unit at all: the ring generator re-aims once when the 5 km/h estimate proves
wrong for the terrain, and the backbone path had no equivalent. It assembled to
the wrong metres and then failed its own candidates on the `duration` gate. It
now re-aims the same way, and says so in the diagnostics.

Measured honestly: the `measure` selector changes **nothing** end-to-end on any
fixture tried. Every allocation the table returns is routed and gated anyway,
so the right-duration combination is found whatever order the table ranked them
in. It is kept because ranking by the wrong quantity is a latent bug that binds
as soon as the combination count exceeds `BACKBONE_ASSEMBLY_LIMIT`, and because
it costs ten lines — not because it earned a number. The re-aim is what does
the work, and only when the pace is wrong enough to put the answer outside the
reach of the options offered.

**"415 vs 162 is a discrepancy to reconcile."** It is not. 415 is a production
Douglas probe; 162 is the synthetic straight-line fixture, on different ground
at a different candidate count. The obvious suspect — production's
`candidateCount` of 24 against the bench's 16 — is not it either:
`urban-5km-production-width` raises the cap and costs *exactly* what
`urban-5km` costs, because the early stop fires long before the cap binds. The
difference is the ground, which is the one thing the synthetic bench cannot
lend the live engine.

## The sweep turned inside out

`CORNER_COUNTS_TO_TRY = [3, 2, 1, 4]` was a loop *inside* each candidate, so a
bearing that never works paid for all four shapes before any other bearing was
asked a single question. `progressiveCornerSweep` makes it the outer loop:
every bearing at three corners, then only the bearings that failed get two, and
only what still fails gets one and four. Same shapes, same order, and — unlike
`narrowCornerSweep` — the awkward tail is delayed rather than dropped.

| | `diversityAwareEarlyStop` off | on |
| --- | --- | --- |
| **`progressiveCornerSweep` off** | 5,753 | 6,427 (+11.7%) |
| **on** | 5,250 (**−8.7%**) | **5,114 (−11.1%)** |

55 walks offered and 21/21 scenarios valid in every cell — no scenario lost a
route, and every scenario whose cost moved, moved down: `rural-6km` −133,
`waypoint-suburban` −103, `suburban-5km` −66, `coastal-5km` −60.

The interaction is the interesting half, and it was worth measuring rather than
assuming. `diversityAwareEarlyStop` was shelved in Phase 1 at +30% calls for
half a point of separation. Under waves it reverses sign: the pool is being
evaluated at each wave boundary anyway, so asking it the stricter question is
nearly free, and the pair together beat either alone.

### Two things that did not work, recorded so they are not retried

**Splitting the waves as `[3,2]` then `[1,4]`** — the intuitive reading of
"delay the awkward shapes" — is *worse* than `[3] [2] [1,4]`: 5,512 against
5,250, and 5,546 against 5,114 with diversity on. Separating three from two
matters as much as separating out the tail.

**On a uniform straight-line fixture progressive costs +74%** (162 → 282
calls), and this is a real property rather than a bug. Where every bearing is
equally good and shape two rescues what shape three missed, trying another
*shape* on a bearing already paid for is much cheaper than starting a fresh
bearing — and sweeping across the batch does the opposite. That fixture has no
street network at all, and every synthetic network with one says the reverse.
Which is why the flag ships off: this is a question about ground, and the
production probe is the only thing that can answer it for Douglas.
