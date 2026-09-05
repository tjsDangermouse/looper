# iOS ↔ remote engine parity audit

Phase 0 of the parity plan
(`~/.claude/plans/internal-ios-routing-is-serene-widget.md`). Every place the
on-device engine (`ios/LooperKit/Sources/LooperKit/NativeRouting/`, from
`a618a89`) diverges from the remote `route-service` loop engine.

Goal: 100% parity, then improvements. Class A = port does less (add it).
Class B = port does something different/extra (revert to remote). Class C =
forced by the GraphHopper→A* / planet-import→Overpass / signs→geometry
substitution (match as far as possible, measure the rest).

Status key: ✅ verified against current code · 🔍 needs a verification read ·
⬜ not started

---

## Area 1 — candidate generation (`candidates.ts` ↔ `LocalRingRouter`)

| # | Divergence | remote | iOS | class | status |
|---|---|---|---|---|---|
| 1.1 | `generateLoopAttempts` — mirrored pairs, `mulberry32`, `BEARING_JITTER_DEGREES=12` | `candidates.ts:40-55` | `LocalRingRouter.swift:137-150` `ringAttempts` | — (matches) | ✅ |
| 1.2 | `spreadAcrossCompass` bit-reversal | `candidates.ts:76-88` | `LocalRingRouter.swift:160-174` | — (matches) | ✅ |
| 1.3 | seed = `hashString(lon.toFixed(4)\|lat.toFixed(4)\|round(target)\|variation)` | `random.ts` / `seedFor` | `LocalRingRouter.swift:100-119` | — (matches) | ✅ |
| 1.4 | attempt count 24 | `config.ts:56` | `LocalRingRouter.swift:41` | — (matches) | ✅ |
| 1.5 | network-probe seeding (`biasAttemptsToNetwork`) / skeleton screening (`screenAttempts`) | `candidates.ts`, `generate.ts` | absent | — (off in prod flags) | ✅ |
| 1.6 | ~~batch / re-aim ordering~~ **DONE** — batch 0 -> re-aim -> discovery loop gated on selector, matching `generateLoops`. //
| 1.7 | ~~re-aim trigger~~ **DONE** — `candidates.count < wanted` (was `&& observed>=3`), median over all built. //
| 1.8 | **time-mode re-aim** — remote re-aims distance from `clampScale(targetSeconds/observed)` over `durationOnly` misses | `generate.ts:363-372` | absent | **C5** | ✅ |
| 1.9 | ~~discovery-batch gate~~ **DONE** — loop runs while selector can't fill `wanted`. //

## Area 2 — leg routing (`routing.ts` + `graphhopper.ts` ↔ `LocalLegRouter`)

| # | Divergence | remote | iOS | class | status |
|---|---|---|---|---|---|
| 2.1 | **engine** — GraphHopper landmark A* over planet import vs custom Swift A* over Overpass graph | `graphhopper.ts:79-99` | `LocalLegRouter.swift:236-293` | **C1/C2** | ✅ |
| 2.2 | **cost model** — GraphHopper custom weighting `time/priority + distance_influence·d` vs `metres × (1/priority) × penalty` | `looper_foot.json`, `config.yml` | `LocalLegRouter.swift:174-177` | **C1** | ✅ |
| 2.3 | **per-way speed** — GraphHopper `foot_average_speed` per edge vs fixed 5 km/h | `looper_foot.json:59-61` | `LocalInstructions.swift:40` | **C1/C5** | ✅ |
| 2.4 | **ring legs weighted, waypoint legs NOT** — remote routes every leg pavement-weighted | `routing.ts` (all legs via `avoidanceCustomModel`) | `LocalWaypointRouter.swift:107-109,168-171` (`weighted:false`, penalty 4) | **A2** | ✅ |
| 2.5 | **relaxed-penalty retry** (`RELAXED_AVOID_PRIORITY=0.2`) when a leg is unroutable under the strong penalty | `routing.ts:216-229` | absent; `LocalLegRouter.relaxedAvoidPenalty` defined, called by nothing | **A3** | ✅ |
| 2.6 | **leg-budget cheaper reroute** — overshoot + detour → reroute at relaxed penalty, keep if shorter | `routing.ts:240-255` | absent | **A3** | ✅ |
| 2.7 | **in-leg spike reroute** — `findLegSpike` + `buildSpikeAvoidanceArea` disc, reroute once | `routing.ts:257-275` | only global post-assembly `LocalSpikeTrim.trimming` at `LocalRingRouter.swift:293` (geometry splice); no reroute | **A3** | ✅ |
| 2.8 | German bridleway rule — NOT PORTED: needs a country encoded value the Overpass graph has no source for, and cannot fire on the Isle of Man. Documented, deferred. //
| 2.9 | mtb_rating — NO MATERIAL DIVERGENCE: GraphHopper's `mtb_rating` encoded value is the same leading-integer parse of `mtb:scale` that `mtbRating()` does. //
| 2.10 | ~~access-restricted deleted~~ **DONE** — `private/restricted/delivery/customers` priced x10 (`foot_road_access==PRIVATE`), only `no`/`military` refused. //
| 2.11 | `hike_rating>=2` — remote: weight 0; iOS: hard block in `decide` | `looper_foot.json:49` | `PedestrianAccessPolicy.swift:179-181` | — (same net effect) | ✅ |
| 2.12 | **snap preventions** `tunnel, bridge, ferry` | `config.yml:47`, `graphhopper.ts:95` | none — `LocalEdgeIndex.snap` (`:145`) has no tunnel/bridge/ferry awareness. Also check `OSMData` retains those tags | **A10** | ✅ |
| 2.13 | **tie-breaking** on equal-weight paths | GraphHopper edge-id order | `LocalLegRouter` heap order | **C1** | 🔍 |
| 2.14 | ~~short-backtrack on edges~~ **DONE** — `overlapMetres`: geometric, both directions, 20 m ignore, vs the committed previous leg. //
| 2.15 | keep *last* leg attempt (`keepBestLegAttempt` off) | `routing.ts` | `LocalRingRouter.swift:237-241` | — (matches) | ✅ |

## Area 3 — anti-retrace / avoidance (`avoidance.ts` ↔ `ringCorridor`)

| # | Divergence | remote | iOS | class | status |
|---|---|---|---|---|---|
| 3.1 | **start exclusion** — `START_EXCLUSION_RADIUS_METRES=75` circle cut out of every corridor before widening | `avoidance.ts:20-21,88` | ~~none~~ **DONE** `d3834ef` — `ringCorridor(around:from:)` drops samples within 100 m of start | **A1** | ✅ done |
| 3.2 | `MAX_AVOIDANCE_AREAS=12` cap + polygon simplification | `avoidance.ts` | iOS unions all prior legs' edges, exact | — (iOS stricter but exact; leave) | ✅ |
| 3.3 | corridor half-width 25 m, sample 15 m (remote) vs 12 m (iOS) | `quality.ts` `SAMPLE_METRES` | `LocalRingRouter.swift:352` | 🔍 (check sample spacing) | 🔍 |
| 3.4 | penalty magnitude — `AVOID_PRIORITY=0.05` (20×) both sides | `avoidance.ts` | `LocalLegRouter.swift:37` | — (matches) | ✅ |
| 3.5 | spike avoidance disc (`buildSpikeAvoidanceArea`) | `avoidance.ts` | absent (ties to 2.7) | **A3** | 🔍 |

## Area 4 — waypoint planning (`waypoints.ts` ↔ `LocalWaypointPlanner`)

| # | Divergence | remote | iOS | class | status |
|---|---|---|---|---|---|
| 4.1 | `DETOUR_SHARES`, `guideForDetour`, `planSegmentOptions`, `allocateSlack` DP, four-tier ordering, `spreadAllocations`, `FEASIBILITY_TOLERANCE` | `waypoints.ts` | `LocalWaypointPlanner.swift` | — (near-exact port) | 🔍 |
| 4.2 | `formatShare` / option-id string forms drive an id-sorted tie-break | `waypoints.ts:96` | `LocalWaypointPlanner.swift:106-108` | 🔍 (fragile; add test) | 🔍 |
| 4.3 | allocation `measure` in seconds vs always metres | `generate.ts:1370-1373` | `LocalWaypointPlanner.swift:142` | **C5** | 🔍 |

## Area 5 — waypoint/backbone router (`generate.ts generateBackboneWaypointLoops` ↔ `LocalWaypointRouter`)

| # | Divergence | remote | iOS | class | status |
|---|---|---|---|---|---|
| 5.1 | **`trueLowerBound` pass** — remote re-routes every gap on `shortestPathCustomModel` before refusing | `generate.ts:1300-1305,1526-1544` | absent (A* on metres already is the bound) | — (correct given C1; revisit after C1 changes the cost model) | 🔍 |
| 5.2 | **time-mode re-aim** of `assemble()` | `generate.ts:1449-1458` | absent | **C5** | 🔍 |
| 5.3 | backbone legs unweighted (see 2.4) | | | **A2** | ✅ |
| 5.4 | ~~join-reversal repair~~ **DONE** — removed; gaps assembled with no cross-gap avoidance, gate rejects u-turns, as `assemble`+`joinAndTrimLegs`. //
| 5.5 | ~~both trims judged~~ **DONE** — single `LocalSpikeTrim.trimming(_, protecting: [])`, `keepPinnedSpurs` off. //
| 5.6 | **`spurForced` / `excusedRetraceMetres` / `excusedUTurns` / `stemMetres`** gate params | `quality.ts:329-352` has none | `LocalWaypointRouter.swift:256-264,613-647` + `RouteQuality.swift` | **B2** | ✅ |
| 5.7 | ~~hitsPins ranking~~ **DONE** — removed; `pickWithFallbackSeparation` (strict then WAYPOINT_RELAXED_SHARED). //
| 5.8 | ~~guided fallback bearings~~ **DONE** — `generateLoopAttempts(seedFor(...), guideCount*2)` clockwise half; variant=pair. //
| 5.9 | guide-radius samples 48 both sides | `WAYPOINT_GUIDE_RADIUS_SAMPLES` | `LocalWaypointRouter.swift` | 🔍 | 🔍 |

## Area 6 — duration / units

| # | Divergence | remote | iOS | class | status |
|---|---|---|---|---|---|
| 6.1 | **displayed duration** — remote: client pace or GraphHopper `path.time`; iOS: fixed 5 km/h, saved pace ignored for display | `generate.ts:917-921` | `LocalRingRouter.swift:670`, `LocalInstructions.swift:40` | **C5 / A7-adjacent** | ✅ |
| 6.2 | `targetDifferencePercent` — duration ratio in time mode vs always distance ratio | `generate.ts:1154` | `LocalRingRouter.swift:676` | **C5** | ✅ |

## Area 7 — quality gate (`quality.ts` ↔ `RouteQuality.swift`)

Thresholds verified identical: `maxDistanceError 0.12`, `maxRepeatedFraction
0.12`, `minBacktrackMetres 500`, `outAndBackShareThreshold 0.3`, `startStubShare
0.04`, `maxStartStubMetres 150`, `maxUTurns 1`, `maxBoundingBoxRatio 4.5`,
`minCompactness 0.2`, `maxLegShare 0.45`, `minLegShare 0.08`, `endpointTolerance
40`, all repeat-detection tunings, score weights `0.35/0.25/0.20/0.10/0.10`. ✅

| # | Divergence | remote | iOS | class | status |
|---|---|---|---|---|---|
| 7.1 | elongation "reach" escape hatch | none | ~~`RouteQuality.swift`~~ **DONE** — gate reverted to plain bbox>4.5 / shape<0.2; reach* kept as diagnostics only (beam still uses the constants) | **B1** | ✅ done |
| 7.2 | **duration gate** — `durationErrorFraction > 0.15` → `'duration'`, an essential rejection | `quality.ts:476` | `RouteQuality.analyse` takes no `targetSeconds` | **A7** | ✅ |
| 7.3 | **U-turn sign cross-check** — `max(geometric, signs.filter(isUTurnSign).length)` | `quality.ts:287-311` | geometry only (`RouteQuality.swift:414-427` → `WalkUTurns`) | **A8 / C3** | ✅ |
| 7.4 | `stemMetres` / `excusedRetraceMetres` / `excusedUTurns` gate params | none | ~~`RouteQuality.swift`~~ **DONE** — params removed from `analyse`; `spurForced` deleted; callers updated | **B2** | ✅ done |
| 7.5 | symmetric doorstep in `edgeRepeatReport` (`along+metres` vs `along` at the close) | `edges.ts:145` | ~~`RouteQuality.swift:352`~~ **DONE** — keyed on `along` at both ends, as the reference | **B3** | ✅ done |
| 7.6 | `legShares` always computed (remote) vs only when passed (iOS) | `quality.ts:485-486` | `RouteQuality.swift:664-671` | — (equivalent in practice) | ✅ |
| 7.7 | frame math — `MetricFrame` vs `projector`/`resample` | — | — | — (noise) | ✅ |

## Area 8 — graph / data source (`config.yml` / GraphHopper import ↔ `LocalWalkingGraph` / Overpass)

| # | Divergence | remote | iOS | class | status |
|---|---|---|---|---|---|
| 8.1 | source — planet OSM import vs `way["highway"](bbox);(._;>;)` chunk fetch | `config.yml` | `RoutingDataSource.swift:234-243` | **C2** | ✅ |
| 8.2 | **partial ways at chunk seams** — way cut where a node is in an unloaded chunk → dead-end | n/a (one graph) | `LocalWalkingGraph.swift:178-198` | **C2** | ✅ |
| 8.3 | **subnetwork pruning** `prepare.min_network_size: 200` | `config.yml:40` | none | **A9** | ✅ |
| 8.4 | **ferries** — GraphHopper foot model routes `route=ferry`; Overpass query fetches only `highway=*` | | | **C4** | ✅ |
| 8.5 | `ignored_highways: motorway,trunk` at import | `config.yml:36` | `PedestrianAccessPolicy` motorway/trunk handling | 🔍 (confirm equivalent) | 🔍 |
| 8.6 | barrier nodes — GraphHopper barrier handling vs `PedestrianAccessPolicy.canPass` way-split | | `LocalWalkingGraph.swift:186-196` | 🔍 | 🔍 |
| 8.7 | `area=yes` / `indoor` | GraphHopper area handling | blocked (`PedestrianAccessPolicy.swift:202-203`) | 🔍 | 🔍 |
| 8.8 | one-way — both ignore `oneway`, honour `oneway:foot` | | `PedestrianAccessPolicy.swift:246-273` | — (matches) | ✅ |

## Area 9 — diversity / refresh (`diversity.ts` ↔ `RouteDiversity.swift`)

| # | Divergence | remote | iOS | class | status |
|---|---|---|---|---|---|
| 9.1 | `MAX_SHARED_FRACTION 0.55`, `INITIAL_BEARING_METRES 500` / `FRACTION 0.2`, `bearingOctant` | `diversity.ts` | `RouteDiversity.swift` | — (matches) | 🔍 |
| 9.2 | ~~unseen-aware early stop~~ **DONE** — `enough()` counts all passing, uses `selectPreferred` (octant pass), stops on 5 OR diversity-satisfied. //
| 9.3 | ~~top-up from already-seen~~ **DONE** — removed; exclusion filters the pool, selector returns fewer. //
| 9.4 | selector passes — 3 (octant+shape / octant / drop) vs remote's 2 (octant / drop) | `diversity.ts:102-138` | ~~`RouteDiversity.swift`~~ **DONE** — `selecting` is now the reference's 2 passes | **B1** | ✅ done |
| 9.5 | pareto/octant archive — `paretoArchive` off in prod; iOS omits `choose()` octant-Pareto branch | `generate.ts:405-433` | — | — (correct) | ✅ |

## Area 10 — instructions (`graphhopper.ts` steps + `routing.ts joinLegGeometries` ↔ `LocalInstructions`)

| # | Divergence | remote | iOS | class | status |
|---|---|---|---|---|---|
| 10.1 | **source** — GraphHopper instruction `text`/`sign`/`street_name`/`interval` passed through vs synthesised from turn angles | `graphhopper.ts:251-261` | `LocalInstructions.swift:48-167` | **B11 / C3** | ✅ |
| 10.2 | turn taxonomy — 19 GraphHopper signs / `maneuverName` vs `continue<20° / keep<45° / turn<120° / sharp<160° / u-turn` | `graphhopper.ts:101-119` | `LocalInstructions.swift` | **B11 / C3** | ✅ |
| 10.3 | no roundabout / keep-left-right / waypoint instruction on iOS | | | **B11 / C3** | ✅ |
| 10.4 | terminal "You're back where you started" step appended (iOS) vs GraphHopper `sign 4` finish | | `LocalInstructions.swift:109-117` | **B11** | ✅ |
| 10.5 | step distance/duration apportioning — real leg duration vs `metres/(5000/3600)` | | `LocalInstructions.swift:40` | **C5** | ✅ |
| 10.6 | `tidySteps` — iOS-only extra pass | | `LocalRingRouter.swift:678` | **B11** | 🔍 |

## Area 11 — smaller items

| # | Divergence | remote | iOS | class | status |
|---|---|---|---|---|---|
| 11.1 | `abandonAboveMetres = target*2.2`, `legBudgetMetres = target*0.5` | `generate.ts:830` | `LocalRingRouter.swift:193` | — (matches; but iOS never does the budget *reroute*, see A3) | ✅ |
| 11.2 | `cancellingReversals` — same-edge-reversed cancellation inside every `LocalLegRouter` leg | n/a (remote has only a polyline) | `LocalLegRouter.swift:455-467` | **B?** (iOS extra, but arguably forced — no server equivalent possible) | 🔍 |
| 11.3 | `MAX_TOTAL_TRIM_METRES 300`, spike constants (80 / 15 / 150°) | `routing.ts:76-87` | `LocalSpikeTrim.swift:50` | — (matches) | ✅ |
| 11.4 | concurrency — `concurrency ?? 6` vs `concurrentPerform` sliced by core count | `generate.ts` | `LocalRingRouter.swift:571-588` | — (same determinism guarantee) | ✅ |

---

## Open verification tasks (🔍 items)

Highest priority for a verification read before Phase 1:
1. **1.6 / 1.7** — re-aim ordering & trigger. Read `generate.ts` ring generator batch loop.
2. **2.7 / 3.5** — in-leg spike reroute + spike disc. Confirm truly absent on iOS.
3. **2.12** — snap preventions.
4. **9.4** — which selector the default iOS ring path uses.
5. **5.1** — whether `trueLowerBound` matters once C1 changes the cost model to match GraphHopper (if the iOS A* stops being a pure-metres lower bound, the backbone-refusal logic needs the pass).
6. **8.5 / 8.6 / 8.7** — motorway/trunk, barriers, areas.

## Instructions (Area 10) — C3-bound, deferred

B11 / 10.4 / 10.5 / 10.6: the remote passes GraphHopper's step objects
(`text`, `sign`, `street_name`, `interval`, apportioned duration) straight
through; on-device there are no signs, so `LocalInstructions` synthesises turns
from geometry. This cannot be made byte-identical without the signs (C3). A
focused instructions pass would: align the turn taxonomy and thresholds to
GraphHopper's `maneuverName` mapping where geometry supports the distinction,
drop the always-appended "back where you started" step in favour of a
`sign 4`-style finish, and reconcile `tidySteps` with `joinLegGeometries` +
`trimTinySpikes` step remapping. Route geometry is unaffected by any of this.
11.2 (`cancellingReversals`) is kept: it compensates for `LocalLegRouter`
routing through several guides in one call (which GraphHopper never does), not
for anything the remote engine also has.

## Class rollup

- **Class A** (add): A1 corridor start-exclusion · A2 weighted waypoint legs · A3 per-leg salvage (relaxed retry, budget reroute, spike reroute) · A4 access-penalise-not-delete · A5 German bridleway · A6 mtb_rating derivation · A7 duration gate · A8 u-turn sign cross-check (→ C3 approx) · A9 subnetwork pruning · A10 snap preventions
- **Class B** (revert): B1 reach hatch · B2 spur/stem/excused gate params · B3 symmetric doorstep · B4 unseen-aware early stop + top-up · B5 dual-trim pin preservation · B6 hitsPins ranking · B7 re-aim ordering & trigger · B8 short-backtrack measure · B9 join-pullback re-test · B10 guided fallback bearings · B11 instruction synthesis (bounded by C3) · plus 5.4 join-reversal repair, 10.6 tidySteps, 11.2 cancellingReversals (decide per-item)
- **Class C** (match / measure): C1 GraphHopper weighting + speed + snapping + tie-break · C2 Overpass graph + chunk-seam mitigation · C3 no turn signs · C4 ferries · C5 pace-aware duration + time-mode
