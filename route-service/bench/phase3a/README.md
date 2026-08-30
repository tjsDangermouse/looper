# Phase 3A bench: what the boundary costs, and what naming a corridor saves

Findings live in
[docs/GRAPHHOPPER_LOOPER_PHASE3A_BOUNDARY.md](../../docs/GRAPHHOPPER_LOOPER_PHASE3A_BOUNDARY.md).

Phase 2 established the shape of the problem: of every millisecond Looper
attributes to "the engine", GraphHopper spends about a fifth and the actual
pathfinding about a twenty-fifth. The rest is the boundary and the contention
between six concurrent legs. Phase 3A asks whether the boundary can be made
cheaper without changing a single route, and the honest answer is measured
here rather than argued.

The one idea everything is built on: **stop paying to describe the same
routing state**. A corridor is registered once, under the caller's own content
hash, and referred to by name afterwards; the facade keeps the parsed model and
the weighting GraphHopper built from it; and an identical request is answered
from the one already asked.

## The corpus

The same 1,863 real calls Phase 2 captured (`bench/phase2/corpus`), replayed,
so the two phases' tables are about the same work. `capture.mts` here records a
*new* trace at this phase's configuration, with per-call boundary detail —
which corridor set the call named, whether the answer had already been given,
and where the time went — for the phase after this one.

## The scripts

| script | question |
|---|---|
| `anatomy.mts` | §1, §2, §11, §12 — what a request body carries, how much of it repeats, and what a handle would leave out |
| `equivalence.mts` | §24 — all 1,863 calls both ways, fingerprinted over the full `edge_id` sequence |
| `transport.mts` | §13, §14 — the boundary with nothing queued behind it, before and after |
| `batch.mts` | §17 — what an HTTP exchange costs when several legs share one |
| `concurrency.mts` | §18 — the six-way fan-out swept 1/2/4/6/8, as a diagnostic |
| `end-to-end.mts` | §25, §26, §27 — whole generations, the only measurement that decides anything |
| `capture.mts` + `calls.mts` | §19, §33 — the traced generation, and the call anatomy Phase 3B starts from |
| `warm.mts` | the whole corpus against a facade, before anything is timed |
| `facades.sh` | the two facades every comparison needs |

```sh
./bench/phase3a/facades.sh                  # :8991 reuses weightings, :8992 rebuilds them
npx tsx bench/phase3a/anatomy.mts
npx tsx bench/phase3a/equivalence.mts
npx tsx bench/phase3a/transport.mts
npx tsx bench/phase3a/batch.mts
npx tsx bench/phase3a/concurrency.mts
npx tsx bench/phase3a/end-to-end.mts
npx tsx bench/phase3a/capture.mts && npx tsx bench/phase3a/calls.mts
```

## Three traps this bench walks into if you let it

**A cold JVM is not slower by a little.** Phase 2's lesson, and it still
applies: every script here warms the facade against the whole corpus before it
times anything. `warm.mts` is not optional politeness.

**Two facades, or the two wins cannot be told apart.** Naming a corridor saves
bytes on the wire *and* saves GraphHopper rebuilding a weighting. `:8992` runs
with `-Dlooper.registry.reuse_weighting=false`, which keeps the first and drops
the second, so P1 and P2 are a measurement rather than an attribution.

**The trace changes what it measures.** `capture.mts` appends a line per call
synchronously, which blocks the event loop and inflates every concurrent call's
latency — a traced generation runs roughly 40% slower than an untraced one. Its
*proportions* and its *counts* are sound; its totals are not comparable with
`end-to-end.mts`, and the doc uses each for what it can answer.

## Determinism

As in Phases 1 and 2: engine-call count is reported and never asserted, because
`diversityAwareEarlyStop` races concurrent candidates and arrival order decides
which have landed when the stop trips. What must match is the walks — and here,
additionally, the full `edge_id` sequence of every individual call.
