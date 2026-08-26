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
