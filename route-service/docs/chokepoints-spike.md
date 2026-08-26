# Phase 7 — chokepoints and unavoidable retracing

A research note, not a change. Nothing in this document is implemented behind a
flag, and the global retrace gate is untouched.

## The question

Looper rejects a walk that spends more than 12% of itself on ground it already
covered. Most of the time that is right: a walk that doubles back has usually
gone wrong. But some ground offers no choice. A town on one side of a river
with a single bridge, a headland with one road along it, a pier — any walk that
visits both sides walks the shared part twice, and no amount of avoidance
weighting changes that, because the alternative does not exist.

Today the gate cannot tell the two apart. `MIN_BACKTRACK_METRES` is the current
approximation: a backtrack under 500 m is held against a walk, and one over it
is excused as "long enough that it can only be a real feature". That is a proxy
for structure, using length, and it is wrong in both directions — a 600 m
avoidable detour round a housing estate is excused, and a 300 m bridge is not.

The benchmark shows both failure modes. `waypoint-across-bridge` returned
nothing at all before Phase 4; it now returns three walks, all of which share
74% of their ground, because they must.

## What the graph could tell us

In graph terms the thing being looked for is an **articulation edge** (a
"bridge" in the graph-theoretic sense as well as the civil-engineering one): an
edge whose removal disconnects the graph. Every walk from one component to the
other and back traverses it twice. Tarjan's algorithm finds all of them in one
linear pass.

Three ways to get at it, in increasing order of invasiveness:

**1. Ask the engine, at request time — no preprocessing.** When a route repeats
an edge, route that pair again with the repeated ground penalised, and see
whether an alternative exists at a tolerable cost. If nothing within, say,
three times the detour comes back, the repetition is structural.

This is already happening. `routeLegAttempt` penalises walked ground, retries
under a relaxed penalty when the strong one leaves a leg unroutable, and
circles a dead-end branch and asks again. A leg that came back `relaxed: true`,
or whose spike reroute failed, has already *demonstrated* that there is no way
round — and that fact is currently thrown away. `RoutedLeg.relaxed` and
`avoidanceAreaCount` are on every leg and nothing reads them.

**This is the finding worth acting on**: the structural signal costs zero extra
engine calls, because the calls that establish it have already been made.

**2. Derive it from `edge_id` details across a request's own routes.** Every
route in a batch reports the edges it used. An edge that appears in every
single candidate, in both directions, is a strong hint at a chokepoint — no
matter which way the generator aimed, every walk went through it. Cheap, needs
no new data, and is a heuristic rather than a proof: it cannot distinguish "the
only way" from "the obvious way".

**3. Preprocess the graph.** Export the pedestrian network once per import,
run Tarjan's algorithm, and ship a set of articulation edge ids alongside the
graph. Exact, and invasive: it needs a graph export path GraphHopper does not
offer over HTTP, a second artefact to build, version and ship with every
import, and a way to keep edge ids stable across rebuilds — which GraphHopper
does not guarantee. **Not recommended.** The cost is a new build pipeline; the
benefit over (1) is precision in cases where (1) already answers correctly.

## Why this was not shipped

Weakening the retrace gate is the highest-risk change in this whole piece of
work. It is the gate that stops Looper offering a walk out and back along one
road and calling it a loop, and it is the one a walker notices immediately when
it is wrong.

To justify relaxing it, the evidence has to show that the relaxation fires
*only* where the retrace is genuinely unavoidable. The only fixtures available
here are synthetic networks whose chokepoints I placed myself, so a detector
that works on them proves that it can find a bridge I told it about. That is
not evidence, and shipping a flag on the strength of it would be dressing up a
guess as a measurement.

## Design, if it is taken further

Add to `RoutedCandidate` a record of which repeated sections the builder
already failed to route around — it has that information at the moment it gives
up, in `routeLegAttempt` and `applyJoinPullback`.

In `analyseRouteQuality`, split `repeatedMeters` into two figures rather than
raising the limit:

```
avoidableRepeatedMeters    counted against maxRepeatedFraction as it is today
structuralRepeatedMeters   excused, and surfaced to the walker as a warning
```

Structural metres are only those the builder demonstrably tried and failed to
avoid. The gate itself does not move: a walk with 30% avoidable retracing is
still refused, and a walk with 30% structural retracing is offered *with the
existing constrained-route warning*, so nobody is told they are getting a clean
loop when they are not.

Behind `LOOPER_STRUCTURAL_RETRACE`, off.

## Benchmark plan

Structural cases must gain and avoidable cases must not, so both have to be in
the table:

| fixture | expectation |
| --- | --- |
| `bridge-4km`, `waypoint-across-bridge` | more walks offered; every excused metre attributable to the bridge |
| `waypoint-narrow-spur` | the promenade excused; more than one walk offered |
| `dense-grid` (all) | **no change at all** — nothing here is structural, so nothing may be excused |
| `suburban-5km`, `suburban-8km` | no change; a cul-de-sac is avoidable by construction |
| `rural-6km`, `rural-3km-tight` | watched closely: sparse ground is where a detector is most likely to call an avoidable detour structural |

The gate: **zero excused metres on the dense grid and suburban fixtures.** A
detector that excuses anything there is excusing avoidable retracing, and no
gain on the bridge fixtures pays for that.

Beyond the synthetic fixtures, this needs a real engine and real ground before
it goes anywhere near production — specifically a set of Isle of Man starts
where the correct answer is known by looking at the map: Peel harbour, the
Douglas promenade, Laxey, and a landlocked start in Onchan as the control.
