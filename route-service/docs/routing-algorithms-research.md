# Research: route-finding algorithms for the loop-routing service

## Context
This document surveys the algorithm landscape for "generate a set of routes that satisfy the walker's criteria" — the job `route-service/src/loops/*` does — and grades each approach against how this specific service is actually built. It's a research/advisory note, not a commitment to any change.

## How the current service actually works
(`route-service/src/loops/*`, on top of a self-hosted GraphHopper pedestrian-profile server)

- **Not** a global optimizer. It's **randomized multi-start heuristic sampling with local repair and rejection filtering**:
  - Generates up to 16 deterministic candidate bearings (`candidates.ts`).
  - Builds each loop **incrementally, leg by leg** (`routing.ts: buildLoopIncrementally`), re-aiming after each leg using GraphHopper's own point-to-point solver (which internally does the real graph-search work — likely Contraction Hierarchies/A*, not exposed to this layer).
  - Steers away from already-walked ground via penalized "avoid area" polygons fed back into GraphHopper (`avoidance.ts`), rather than a global no-repeat constraint.
  - Detects and splices out dead-end "spikes"/backtracks geometrically after the fact (`routing.ts:434-519`).
  - Runs every finished candidate through a hard multi-objective **quality gate** (`quality.ts`) — distance error, overlap %, U-turns, leg balance, compactness, elongation, start-stub length — and rejects anything that fails.
  - If too few loops pass, it resamples a fresh batch of bearings and tries again (up to 3 batches).
  - Picks 3 diverse finalists by a weighted score (overlap 35%, distance closeness 25%, shape 20%, balance 10%, simplicity 10%).
- Explicitly replaced an earlier "guess a whole triangle blind, then filter" approach because it needed far more attempts.
- Hard constraint: this runs against a **small self-hosted GraphHopper container** — concurrency is capped at 6 because "twenty-four at once is more load than a small routing container should take" (generate.ts:640). Each candidate/retry/repair costs real HTTP routing calls. **The routing backend's throughput, not algorithmic cleverness, is the binding constraint.**

## Algorithm survey — graded for *this* app's constraints

| Algorithm family | What it's good for | Grade for this app |
|---|---|---|
| **Dijkstra / A\* / Contraction Hierarchies** | Optimal single-leg shortest path | Already the substrate — GraphHopper does this per-leg. Not a replacement, it's what's already being called under the hood. |
| **Randomized multi-start + rejection sampling** (current approach) | Simple, easy to reason about, works | Functional but wasteful — a full resample-from-scratch on failure burns routing calls without using what was learned from the failed attempt. |
| **Simulated annealing / local search on the existing quality score** | Directed improvement of a mediocre candidate instead of discarding it | **Best fit.** `quality.ts` already computes a multi-objective score — SA/hill-climbing could perturb one leg's bearing/length and re-score instead of resampling the whole loop from bearing zero. Likely fewer routing calls to reach a passing loop than the current "reroll everything" retry. |
| **2-opt / Or-opt style local repair** | Untangling self-intersections/backtracks in a tour | Good, narrow-scope win — could replace the current ad hoc geometric spike-splicing (`routing.ts:434-519`) with a well-understood, more general move set. Low risk, incremental. |
| **Genetic algorithms / evolutionary search** | Multi-objective optimization over a large solution space | Theoretically a good match for the existing weighted quality score, but each fitness evaluation = real routing calls; a population-based search multiplies backend load, which is the actual bottleneck here. Overkill given container capacity. |
| **Orienteering Problem (max profit within a distance budget) / Team Orienteering** | Routes that must also visit/prioritize points of interest | Not applicable today — `LoopRequest` has no POI/scenic-value criteria, only explicit waypoint coordinates + distance/time. Would become the *right* framework if you ever add "prefer parks/POIs" as a criterion — worth remembering, not worth building now. |
| **Ant Colony Optimization** | Finding several diverse near-optimal paths, natural overlap-avoidance | Conceptually a nice match for the "3 diverse non-overlapping loops" requirement (which today is hand-rolled in `avoidance.ts`/`diversity.ts`), but heavy to implement/tune for a small self-hosted backend. Interesting, not pragmatic. |
| **TSP heuristics (nearest-neighbor, 2-opt, Lin-Kernighan) for waypoint ordering** | Choosing the best order to visit a set of stops | Not currently relevant — waypoints are passed in as an ordered list already. Would matter only if you let users drop pins with no required order. |
| **Constraint satisfaction / systematic backtracking** | Principled search with constraint propagation instead of independent retries | More rigorous than current ad hoc retry logic, but awkward over a continuous bearing/distance space; SA/local-search (above) gets similar benefit more simply. |
| **Reinforcement learning / learned routing policy** | Learning a leg-selection policy from reward signal | Large overkill — needs training infra disproportionate to the problem size and data available. |
| **Geometric decomposition (circle-sampling, pie-slice partitioning)** | Simple heuristic loop shaping | Roughly what the current bearing-based candidate generation already does; not a meaningfully different or better idea. |

## Bottom line
The current design (incremental build + reject) is a reasonable, well-evolved heuristic — not naive. The most promising *upgrade path*, if pursued, isn't swapping in a different global algorithm — it's replacing "resample from scratch on failure" with a **local-search/simulated-annealing repair step** that perturbs a near-miss candidate using the quality score already built, plus applying standard **2-opt-style repair** to the existing spike/backtrack cleanup. Both reuse the existing scoring and avoid multiplying calls to the routing backend, which is the actual scarce resource. Orienteering-style scoring is worth keeping in mind only if POI/scenic criteria get added later.

---

# Implementation sketch: near-miss local repair for `attempt()`

## Context
Currently, when a candidate loop fails `analyseRouteQuality` for a single, narrow, shape-related reason (e.g. slightly elongated, one leg a bit too long, one extra U-turn), the generator has no way to nudge that specific candidate — it either accepts it as-is if nothing better turns up, or (at the outer level, `generate.ts:221-227`) discards the whole batch and samples an entirely fresh set of up to `candidateCount` independent bearings from scratch. That's expensive (each bearing tries up to 4 corner counts, each corner count is several real GraphHopper calls) against a backend explicitly documented as capacity-constrained (`generate.ts:637-638`: "twenty-four at once is more load than a small routing container should take").

The fix: when a candidate is a *near miss* (exactly one, non-essential quality rejection), spend a couple of cheap, targeted bearing nudges repairing that specific candidate before falling back to a fresh batch. This reuses `buildLoopIncrementally` and `analyseRouteQuality` as-is — no new algorithm, just a tighter retry loop where one already existed structurally (the corner-count loop right next to it).

## Changes — all in `route-service/src/loops/generate.ts`

1. **Add repair constants and a repairability check**, near `CORNER_COUNTS_TO_TRY`/`MAX_DISCOVERY_BATCHES` (generate.ts:28-31):
   ```ts
   const REPAIR_ATTEMPTS = 2
   const REPAIR_BEARING_STEP_DEGREES = 15
   const REPAIRABLE_REJECTIONS = new Set([
     'elongated', 'shapeless', 'leg-too-long', 'leg-too-short', 'u-turns', 'out-and-back-spur',
   ])
   function isRepairable(report: QualityReport): boolean {
     return report.rejections.length === 1 && REPAIRABLE_REJECTIONS.has(report.rejections[0])
   }
   ```
   `distance`/`duration`/`open-ended` (the `ESSENTIAL_REJECTIONS` from `quality.ts:388`) are deliberately excluded — those are already handled correctly at the *batch* level by the existing duration/radius retry (generate.ts:171-200), which re-aims the whole target rather than one candidate's shape.

2. **Track which corner count produced the current best**, and after the existing `CORNER_COUNTS_TO_TRY` loop (generate.ts:285-318) ends without a pass, attempt repair before falling through:
   ```ts
   let best: Analysed | undefined
   let bestCornerCount = 0
   for (const cornerCount of CORNER_COUNTS_TO_TRY) {
     // ...existing candidate build + analyseRouteQuality...
     if (report.pass) { best = entry; bestCornerCount = cornerCount; break }
     if (!best || entry.report.quality.score > best.report.quality.score) { best = entry; bestCornerCount = cornerCount }
   }
   if (best && !best.report.pass && isRepairable(best.report)) {
     best = await repairNearMiss(best, bestCornerCount, loopAttempt, constructionTarget, qualityTarget, targetSeconds, options, overrides)
   }
   ```

3. **Add `repairNearMiss`**, a small local function alongside `attempt()`: tries `REPAIR_ATTEMPTS` bearing offsets (`± REPAIR_BEARING_STEP_DEGREES`, `± 2×` on the second try) at the *same* `cornerCount` that produced the near miss, rebuilding via `buildLoopIncrementally` and re-scoring via `analyseRouteQuality` exactly as the main loop does. Returns the first passing result, or whichever scores highest if none pass — never worse than the original `best`, since it's only used to replace `best` when it improves on it.

4. **Diagnostics**: add a `repaired: number` counter to the `Diagnostics` type (generate.ts:121-132) and increment it whenever `repairNearMiss` changes the outcome, so the tuning panel/logs can see how often this path fires versus the fresh-batch fallback — this is the signal for whether the repair step is pulling its weight.

## Why this is bounded and safe
- Worst case adds `REPAIR_ATTEMPTS` (2) extra `buildLoopIncrementally` calls — each a handful of leg requests — only for candidates that already almost passed. That's small next to a full fresh batch of `candidateCount` independent bearings × up to 4 corner counts each.
- No change to `routing.ts` or `quality.ts` — the scoring and leg-building primitives are reused unmodified, so existing tests for those files stay valid.
- Falls back to today's behaviour unchanged whenever a candidate isn't a clean single-reason near miss, or repair doesn't improve it.

## Verification plan (if implemented)
- Framework: Vitest (`route-service/package.json`, `npm test` → `vitest run`). Existing `route-service/test/generate.test.ts` already builds a `fakeEngine()` mock router (accepting a configurable "detour" multiplier / simulated failure) injected as `generateLoops(request(), { route: fakeEngine() })` — no real GraphHopper needed.
- New tests to add in `generate.test.ts`:
  - Craft a `fakeEngine` detour scenario that reliably produces a single-reason near miss (e.g. a mild elongation) at the default bearing, and assert `repaired` diagnostics increments and/or that the returned route now passes where it previously wouldn't.
  - Assert the repair path is *not* invoked for a candidate with an essential rejection (distance/duration/open-ended) or multiple simultaneous rejections — confirm behaviour matches today's (fresh-batch fallback).
  - Bound-check: assert repair never issues more than `REPAIR_ATTEMPTS` extra router calls per near-miss candidate (via the existing call-recording pattern already used in `straightRouter`/`fakeEngine`).
- Run `cd route-service && npm test` and confirm the full existing suite (`generate.test.ts`, `routing.test.ts`, `quality.test.ts`, `avoidance.test.ts`, `diversity.test.ts`, `candidates.test.ts`, `api.test.ts`) still passes unmodified.
- No UI/frontend surface changes — this is server-side generation logic only, so no simulator/browser verification needed.
