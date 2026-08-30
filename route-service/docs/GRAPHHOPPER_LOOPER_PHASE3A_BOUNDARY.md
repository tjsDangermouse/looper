# The Looper↔GraphHopper boundary — Phase 3A

Phase 1 established that Looper's routing *is* GraphHopper's. Phase 2 measured
where the time goes and found the search was 4% of it, the engine 19%, and the
boundary and the contention between six concurrent legs the rest — then said
the next phase should stop tuning the engine and start reusing what Looper
keeps telling it.

Phase 3A does exactly that, and reports what it was worth.

Measured 2026-08-30 on darwin/arm64, Docker Desktop, GraphHopper 11.0, Isle of
Man (35,088 nodes, 42,016 edges), against the same 1,863-call workload Phase 2
captured. Reproduce with:

```sh
./bench/phase3a/facades.sh                  # :8991 reuses weightings, :8992 rebuilds them
npx tsx bench/phase3a/anatomy.mts           # §1, §2, §11, §12 — what the bodies carry
npx tsx bench/phase3a/equivalence.mts       # §24 — all 1,863 calls, both protocols
npx tsx bench/phase3a/transport.mts         # §13, §14 — the boundary, nothing queued
npx tsx bench/phase3a/batch.mts             # §17 — several legs per exchange
npx tsx bench/phase3a/concurrency.mts       # §18 — the six-way fan-out, swept
npx tsx bench/phase3a/end-to-end.mts        # §25, §26, §27 — the gate
npx tsx bench/phase3a/capture.mts && npx tsx bench/phase3a/calls.mts   # §19, §33
```

## Executive conclusion: **NO MATERIAL WIN**

```
Phase 2 baseline, full suite, warm, median of 9 across 4 alternating rounds:  2,230 ms
Phase 3A retained combination:                                               2,170 ms
improvement:                                                                    2.7%
  paired within each round, where the comparison is more sensitive:      3.3% mean
                                                                       4.0% median
```

Against a threshold of 20% for a PASS — and against the baseline's own spread
of **4.2%** when measured four times against itself. Between three and four
percent is the most this phase can honestly claim, and it is a seventh of what
would have counted as a result.

Everything this phase built works, and every mechanism was measured doing what
it was built to do:

| what was asked for | what was delivered | measured |
|---|---|---|
| stop re-serialising corridors | a corridor is registered once and named after | **−65% request bytes**, 5.57 MB → 1.99 MB |
| a bounded, request-scoped lifecycle | one scope per `POST /v1/loops`, released in a `finally` | 0 leaked scopes, 0 lost handles |
| reuse safe GraphHopper state | the parsed `CustomModel` and the `CustomWeighting` built from it | **738 weightings instead of 1,495** |
| answer exact duplicates without routing | a request-scoped, single-flight memo | **118 calls in 1,863 (6.3%) answered without the engine** |
| identical routes | | **path-identical on all 1,863 calls** |

And the walker waited very nearly as long as before.

That is not a contradiction, and the reason is the most useful thing this phase
produced. **The boundary's cost is per call, not per byte.** A `GET /info`
against the facade — no routing, a two-line response — costs 0.58 ms on a warm
keep-alive connection. Cutting two thirds of the request payload moved a leg's
round trip by 0.4 ms and moved a walker's wait by nothing measurable, because
what a leg was paying for was never the kilobytes.

Only one of the three mechanisms moved the end-to-end number at all, and it is
the one that does not touch the boundary: the memo, which removes 6.4% of the
calls. Adding the registry and the weighting cache on top of it is worth well
under a further percent. That is the shape of the whole result.

There is a calibration in it that the next phase should take with it, because
it is not the flattering one. **Removing 6.4% of the calls returned 2.7% of the
wall clock — a little under half its share.** Two reasons, both measurable: a
memoised call still pays for parsing its answer and for everything Looper does
around it, and a generation's wall time is not purely the sum of its calls.
Phase 3B should expect a call it removes to be worth roughly half of what its
share of the call count suggests — which still makes the call count the only
lever left of any size.

> **Phase 3B's premise is confirmed by measurement rather than assumed: what a
> walker waits for tracks the number of engine calls, and tracks nothing else
> this phase could find.**

No routing logic was changed. No candidate generation, avoidance geometry,
avoidance multiplier, retry, join-pullback, leg-budget, spike-repair or
GraphHopper configuration was touched. Nothing was forked; one GraphHopper
extension point was used for what it exists for.

## Baseline boundary anatomy

The workload is Phase 2's corpus, unchanged: 1,863 real calls captured from the
six production probes. Its request bodies, measured by `bench/phase3a/anatomy.mts`:

| what a request body carries | MB across the corpus | share |
|---|---:|---:|
| corridor geometry | **4.66** | 84% |
| the rest of the custom model | 0.37 | 6% |
| points | 0.12 | 2% |
| profile, details, snap preventions, flags | 0.41 | 7% |
| **total sent** | **5.57** | |
| **total received** | **11.45** | |

Serially — nothing concurrent, so nothing queued and every millisecond is
attributable (`bench/phase3a/transport.mts`):

| | ms across 1,863 calls | per call |
|---|---:|---:|
| `JSON.stringify` in Node | 108 | 0.06 |
| the round trip | 5,854 | 3.14 |
| — of which, inside the facade | 3,097 | 1.66 |
| — — of which `hopper.route` | 2,762 | 1.48 |
| — of which transport | 2,757 | 1.48 |
| `JSON.parse` in Node | 246 | 0.13 |

And the floor underneath all of it, measured against three servers on the same
machine:

| a round trip that does no routing at all | ms |
|---|---:|
| Node to Node, same host | 0.27 |
| Node to the minimal facade, in Docker | 0.58 |
| Node to the shipped GraphHopper container (Dropwizard), in Docker | 1.37 |

Two things follow. **Keep-alive is already in use and already worth having** —
forcing `Connection: close` costs 2.14 ms per call instead of 0.67 and creates
one `TIME_WAIT` socket per request (602 for 600 requests), which the ordinary
path does not. There is nothing to win there. And **more than a third of what a
Looper leg spends on transport is spent before a byte of it is about walking**:
0.58 ms of the 1.48 ms is the exchange itself, and against the shipped
Dropwizard container it would be 1.37 ms.

## Model duplication

Counted per generation, because the registry is scoped to one — a corridor
repeated in a different fixture is not a repeat it can do anything about.

| fixture | calls | whole requests repeated | avoidance calls | distinct models | model reuse | distinct corridor sets | sets used at both strengths |
|---|---:|---:|---:|---:|---:|---:|---:|
| douglas-3km | 215 | 13 (6.0%) | 181 | 86 | 52.5% | 75 | 11 |
| douglas-5km | 291 | 16 (5.5%) | 244 | 112 | 54.1% | 90 | 22 |
| onchan-5km | 181 | 8 (4.4%) | 151 | 78 | 48.3% | 65 | 13 |
| peel-5km | 763 | 47 (6.2%) | 614 | 282 | 54.1% | 243 | 39 |
| wp-one | 34 | 0 (0.0%) | 16 | 16 | 0.0% | 16 | 0 |
| wp-two | 379 | 35 (9.2%) | 289 | 164 | 43.3% | 147 | 17 |
| **total** | **1,863** | **119 (6.4%)** | **1,495** | **738** | **50.6%** | **636** | **102** |

This reproduces Phase 2's two rates exactly, and they remain different claims
at different scales: **6.4% of calls repeat a whole request**, and **50.6% of
avoidance calls repeat a model**. The first is worth a whole call; the second
is worth a compile, a polygon preparation and three kilobytes of wire.

**The measurement that decided the protocol's design.** A model is the ground
walked *so far*, so leg four's model contains leg three's plus one new polygon.
Registering whole corridor *sets* would therefore re-send nearly every polygon
on nearly every new set — and the numbers say so plainly:

```
2,784 corridor polygons named across the six generations
  658 distinct polygons
76.4% of every polygon reference is one already sent

4.66 MB of polygon geometry sent today
1.22 MB if each polygon were sent once
```

So the unit of registration is one corridor, not one corridor set. The
difference is not a detail:

| fixture | request KB today | KB, corridor set as the unit | KB, one corridor as the unit |
|---|---:|---:|---:|
| douglas-3km | 533 | 331 | 187 |
| douglas-5km | 891 | 534 | 287 |
| onchan-5km | 552 | 363 | 195 |
| peel-5km | 2,234 | 1,346 | 701 |
| wp-one | 45 | 45 | 45 |
| wp-two | 1,446 | 1,025 | 552 |
| **total** | **5,701** | **3,644 (−36%)** | **1,967 (−65%)** |

## Model registry design

**Identity.** A corridor polygon is named by a SHA-1 of its GeoJSON geometry; a
model by a SHA-1 of its ordered corridor names, its multiplier and its distance
influence. Both are the caller's own content hashes, computed in Node, so
nothing ever waits on a round trip to learn a handle. Object identity is used
only as a fast path in front of the content hash, never instead of it —
`buildAvoidanceAreas` returns fresh objects on every call, so a reference check
alone would find almost no reuse.

Corridor geometry and routing strength are separated exactly as §5 asks. The
same corridor set at 0.05 and at 0.2 is two models over one set of polygons:
102 corridor sets in the corpus are used at both strengths, and under this
protocol the relaxed retry describes no polygon the strong attempt has not
already described.

**Shapes the protocol declines.** Looper builds two shapes of custom model —
corridors at a strength, and the bare lower-bound model — and the facade knows
how to rebuild those two. Anything else (a second priority rule, a condition
that is not the canonical `in_looper_avoid_0 || …` join, a non-polygon area) is
sent whole, as before. That is not a fallback to a different model; it is the
same model carried the old way, and it is the only honest answer for a shape
the far side was not told how to rebuild.

**Lifecycle.** `POST /generation` at the start of one `POST /v1/loops`, `DELETE
/generation/{id}` in the `finally` — so the scope is released on the paths that
failed, timed out or were abandoned, which are exactly the ones a scope would
otherwise be left behind by. Behind that, the facade evicts generations idle
for five minutes and trims the oldest past sixty-four, so a client that dies
mid-request cannot grow the registry without bound. Registration itself rides
on the route request rather than taking a round trip of its own.

**Thread safety.** A generation is shared by all six of a request's in-flight
legs. Everything reachable from a registered model is immutable once published;
the maps are `ConcurrentHashMap`; `computeIfAbsent` gives the weighting build
its single-flight, so two legs arriving together on a new corridor set compile
the class once between them. Nothing is serialised that GraphHopper was running
in parallel before.

**Failure.** A handle the facade does not hold is answered `409
unknown_handle`, and the caller describes the model again in full — once. It is
never routed around: routing under a different custom model than the caller
asked for would be a wrong walk returned as a right one. Unknown generation,
unknown model, unknown area and a model with areas but no multiplier are all
explicit errors.

That path is real and it fired. Marking a corridor known the moment a request
carrying it was *dispatched* let a second leg reference it while the first was
still in flight; processed out of order, **1.4% of calls (25 of 1,849)** were
told the handle was unknown and had to say it again. Acknowledging on the
facade's *answer* instead removes the race entirely — measured at **0
rediscoveries** — and costs 5% more model definitions and 1.4% more request
bytes, because two legs that reach a new corridor together now both describe
it. Registration is idempotent, so the second costs the facade a map lookup.
A refusal (`400`, "no path") counts as an acknowledgement, because it means the
facade read the request and kept what it carried; a timeout or a dead socket
does not.

## Custom weighting reuse

Phase 2 found that turning an avoidance model into a `CustomWeighting` cost
more across the workload than the graph search did, and that GraphHopper cannot
avoid it: `CustomModelParser`'s compiled-class cache is keyed on
`CustomModel.toString()`, which prints every corridor vertex — so building the
*key* is proportional to the corridor set — and the generated helper's `init`
builds a fresh `PreparedPolygon` per area on a cache hit as readily as on a
miss. What GraphHopper cannot know, and Looper does, is that the model is the
same one.

The hook is `GraphHopper.createWeightingFactory()`, which is `protected`
because subclassing is how GraphHopper intends a host to supply one.
`LooperWeightingFactory` wraps `DefaultWeightingFactory` and delegates every
build to it; what it adds is remembering the answer, keyed on the model handle
carried in the request hints. Nothing is copied and nothing is reimplemented.

**Safe to share across concurrent requests, and why:**

| state | verdict | reason |
|---|---|---|
| `CustomWeighting` | **safe** | `final class`, every field assigned in the constructor, no mutable state |
| the Janino-compiled `CustomWeightingHelper` subclass | **safe** | its encoded-value and polygon fields are assigned in `init` and only read while routing |
| `PreparedPolygon` (JTS) | **safe** | documented "thread-safe and immutable"; both lazy indexes are built under `synchronized` — and shared, they are built once per corridor instead of once per call |
| the parsed `CustomModel` and its `JsonFeature` geometry | **safe** | never mutated after the request that registered it returns |

**Not shared, deliberately:**

| state | verdict | reason |
|---|---|---|
| `QueryGraph`, `Snap`, the algorithm instance | **request-specific** | GraphHopper builds these per request and they are where a route's own state lives; none of them is touched here |
| a weighting built with a heading penalty, `cm_version`, or turn costs | **declines the cache** | those feed the build and are not named by the handle. Looper sets none of them; a caller that started to would get the ordinary path, not the wrong weighting |
| the compiled class for two strengths over one corridor set | **cannot be shared** | the class key includes the multiplier, so 0.05 and 0.2 compile separately. Their *geometry* is shared — the same `JsonFeature`, parsed once — which is as far as GraphHopper's API permits without a fork |
| the landmark storage, the location index, the base graph | **graph-global** | GraphHopper's, untouched |

Measured: **738 weightings built instead of 1,495**, and `hopper.route` fell
from 2,762 ms to 2,504 ms serially across the corpus (**−258 ms, −9.3%**).

That is worth checking against Phase 2's prediction rather than against its
headline. Phase 2's ~650 ms was the *whole* cost of building weightings, most
of which is irreducible: 738 of the 1,495 models are seen once and must be
built once. What a registry can remove is the 757 repeats, which Phase 2's own
cache-hit figure of 0.22 ms puts at about 166 ms. The measurement is 258 ms —
slightly more, because skipping the build also skips `CustomModel.merge`
deep-copying the corridor set and `CustomModel.toString()` printing every
vertex of it to make a cache key.

## Exact request memoisation

Request-scoped, single-flight, keyed on the ordered points and the model
identity — which between them name everything that can change a path, since
every other field of the body is fixed for the life of the process by
`buildRouteBody`. A hit re-runs `parseLeg` over the remembered payload rather
than handing back the same object: callers trim and join what they are given,
and a shared leg would let one candidate's tidying reach another's walk. A
failure is never memoised; leaving one in would turn a transport blip into a
candidate that can never be routed.

| | |
|---|---:|
| calls the generator made | 1,863 |
| answered from an identical call already completed | 74 |
| joined onto an identical call still in flight | 44 |
| **calls that never reached the engine** | **118 (6.3%)** |
| request bytes avoided | ~0.13 MB |
| response bytes avoided | **0.72 MB** (11.73 → 11.01 MB, measured) |
| `hopper.route` avoided | ~158 ms summed (118 calls at the measured 1.34 ms mean) |
| whole-generation wall time returned | **2.7%** |

The in-flight joins are worth naming separately: 44 of the 118 are two
identical requests racing each other, which is duplication the generator has
not merely repeated but has not yet noticed. Single-flight was measured worth
having rather than assumed — at 6-way concurrency it is more than a third of
all hits.

## Payload comparison

| request class | calls | mean request bytes today | mean with a handle | reduction |
|---|---:|---:|---:|---:|
| avoid-strong (`multiply_by 0.05`) | 1,227 | 4,030 | 1,433 | **64.4%** |
| avoid-relaxed (`multiply_by 0.2`) | 268 | 2,955 | 576 | **80.5%** |
| plain (no custom model) | 368 | 275 | 275 | 0.0% |
| **corpus** | **1,863** | **3,134** | **1,081** | **65.5%** |

Relaxed calls do best because a relaxed retry is by construction a second
strength over corridors the strong attempt has already described.

Response bytes are unchanged by the handle protocol at 11.45 MB, deliberately
— the memo is what reduces them, by 0.72 MB. Phase 2 established
that `instructions` and `edge_id` are load-bearing during candidate selection —
the u-turn count gates whether a candidate is offerable at all — so deferring
them would change which walks get offered. §23 holds.

## Transport breakdown

Serial, so nothing is queued (`bench/phase3a/transport.mts`):

| | model in every body | model named by handle | change |
|---|---:|---:|---:|
| `JSON.stringify`, Node | 108 ms | 46 ms | **−57.5%** |
| round trip | 5,854 ms | 5,055 ms | −13.6% |
| — inside the facade | 3,097 ms | 2,737 ms | −11.6% |
| — — `hopper.route` | 2,762 ms | 2,504 ms | −9.3% |
| — transport | 2,757 ms | 2,319 ms | −15.9% |
| `JSON.parse`, Node | 246 ms | 189 ms | −23.1% |
| request bytes | 5.57 MB | 1.99 MB | **−64.3%** |
| response bytes | 11.45 MB | 11.45 MB | 0.0% |

Everything moves in the right direction and nothing moves far. The reason is in
the floor: 0.58 ms of the 1.24 ms of transport that remains is the exchange
itself, and no payload change touches it.

A typed request DTO was considered and not built. §13 makes it conditional on
JSON remaining a significant measured bottleneck, and after the handle protocol
everything the facade does outside `hopper.route` — Jackson in, handle
resolution, response building — is at most 2,737 − 2,504 = 233 ms across 1,863
calls, 0.13 ms a call, against a 0.58 ms floor it sits underneath. §16 applies:
the payload cost is no longer near the top of the bill, so it keeps JSON.

## Batching experiment

`/routeBatch` carries several ordinary route bodies in one exchange. Each is
routed by GraphHopper independently — this is not multi-target routing — and in
parallel inside the facade, because what it is being compared against is six
concurrent HTTP calls using six threads. Routing a batch on one thread would
have measured the loss of that concurrency instead of the saving on the
envelope. Verified first: a batch of eight returns the same `edge_id` sequences
as eight separate calls.

| legs per exchange | separate exchanges | one batched exchange | change |
|---:|---:|---:|---:|
| 1 | 5,969 ms | 6,039 ms | −1.2% |
| 2 | 3,187 ms | 3,918 ms | **−22.9%** |
| 4 | 2,024 ms | 2,479 ms | **−22.5%** |
| 6 | 1,544 ms | 2,008 ms | **−30.1%** |
| 8 | 1,255 ms | 1,656 ms | **−32.0%** |
| 12 | 1,032 ms | 1,382 ms | **−33.9%** |

**Batching is worse at every size, and worse the larger the batch.** The
envelope it saves is real — one exchange instead of six — and it is bought at a
price that is larger: a batch cannot answer until its slowest member does, and
Looper's leg latencies are skewed (mean 6.4 ms, p95 12 ms, max 30 ms), so a
batch of six pays close to the maximum where six separate calls each pay their
own. Rejected, and the endpoint is left in the facade as the evidence rather
than as a feature. Nothing in the route service uses it.

This is also the answer to §15 and §16. The per-exchange floor is 0.58 ms and
the only mechanism available to amortise it makes things worse, so there is
nothing a Unix socket or a length-prefixed binary framing could buy that would
be worth its own bug surface. No lower-overhead transport was built.

## Concurrency results

A diagnostic, per §18: the objective is to understand the six, not to move it.
The whole suite, at the retained configuration, at five fan-out limits:

| fixture | 1 | 2 | 4 | **6** | 8 |
|---|---:|---:|---:|---:|---:|
| douglas-5km | 1,152 | 569 | 398 | **349** | 339 |
| douglas-3km | 600 | 254 | 218 | **216** | 276 |
| peel-5km | 1,713 | 777 | 597 | **648** | 865 |
| onchan-5km | 348 | 186 | 164 | **174** | 214 |
| wp-one | 124 | 119 | 123 | **120** | 128 |
| wp-two | 1,576 | 934 | 751 | **721** | 720 |
| **total** | **5,513** | **2,839** | **2,251** | **2,228** | **2,542** |
| calls that reached the engine | 1,400 | 1,470 | 1,618 | 1,722 | 1,895 |
| summed call-site latency | 4,157 | 4,033 | 6,035 | 8,993 | 13,774 |
| waiting on the shared engine limiter | 5 | 8 | 16 | 21 | 32 |

**Six stays.** Four is indistinguishable from it and eight is 14% worse. All
five return identical walks on all six fixtures.

Two things in that table matter more than the recommendation.

**Phase 2's "queueing" is not a queue.** The shared engine limiter — 24 wide
across all walkers — accounts for 21 ms of the whole suite at six-way. What
Phase 2 attributed to queueing is *contention*: a leg that costs 2.97 ms at
one-way costs 5.22 ms at six-way, in Node's event loop, in the JVM's thread
pool and in Docker's networking. It is not a queue anything can be taken out
of, and it is why summed call-site latency triples between one-way and eight-way
while the walker's wait halves and then rises again.

**Concurrency buys speed by doing more work.** 1,400 calls reach the engine at
one-way and 1,895 at eight-way, for the same three walks: the early stop
dispatches speculatively, and the faster the wave the more of it lands before
the stop trips. That is a fact about the generator, not the boundary, and it is
squarely Phase 3B's.

## Full benchmark

Every stage against the same facade except P1, which runs against a second
facade started with `-Dlooper.registry.reuse_weighting=false` — the same
registry with the weighting cache off, so the wire saving and the engine saving
are measured apart rather than one inferred from the other.

| stage | what it adds | total ms |
|---|---|---:|
| P0 | Phase 2 baseline: the model in every request body | 2,310 |
| P1 | + the model registry, weighting rebuilt every call | 2,265 |
| P2 | + the weighting reused per model handle | 2,334 |
| P3 | + the exact route memo | 2,278 |
| — | the memo alone, no registry | 2,202 |

**That column is inside its own noise and must not be read as an ordering** —
P2 appears slower than P0 there, which it is not. It is printed because the
counters beside it are not noise at all, and they are what the stages were run
to produce:

| per stage, summed over the six generations | P0 | P1 | P2 | P3 |
|---|---:|---:|---:|---:|
| calls the generator made | 1,879 | 1,869 | 1,863 | 1,849 |
| calls that reached the engine | 1,865 | 1,858 | 1,852 | **1,722** |
| answered from the memo (settled + joined) | 0 | 0 | 0 | **74 + 44** |
| corridor registrations | 0 | 693 | 692 | 694 |
| model definitions | 0 | 774 | 774 | 778 |
| model references | 0 | 1,500 | 1,495 | 1,480 |
| handles the facade had lost | 0 | **0** | **0** | **0** |
| request KB | 5,718 | **2,092** | **2,087** | **2,057** |
| response KB | 11,775 | 11,760 | 11,728 | **11,007** |
| round trip, summed | 9,125 | 8,874 | 9,214 | **8,614** |
| `hopper.route`, summed | 2,744 | 2,631 | 2,633 | **2,533** |
| response building in the facade | 172 | **89** | **91** | **83** |
| `JSON.parse`, Node | 76 | 76 | 77 | 73 |
| waiting on the shared engine limiter | 7 | 7 | 7 | 19 |

Resident memory of the facade was unchanged at 475 MiB against 506 MiB for the
one rebuilding weightings — the registry holds one generation's corridors, and
a generation's corridors are about 200 KB.

**The gate.** Because one stage's spread against itself is larger than every
effect above, the retained combination was measured against the baseline in
**four alternating rounds**, each a fresh service, each fixture the median of
nine warm generations:

| fixture | P0 baseline | P3 retained | memo alone |
|---|---:|---:|---:|
| douglas-5km | 359 | 344 | 350 |
| douglas-3km | 217 | 213 | 212 |
| peel-5km | 635 | 622 | 629 |
| onchan-5km | 166 | 166 | 169 |
| wp-one | 117 | 119 | 121 |
| wp-two | 736 | 706 | 714 |
| **total** | **2,230** | **2,170** | **2,195** |
| **change** | | **−2.7%** | **−1.6%** |

| the same, paired within each round | round totals | |
|---|---|---:|
| P0 baseline | 2,300 / 2,241 / 2,308 / 2,215 | spread **4.2%** |
| P3 retained | 2,172 / 2,186 / 2,171 / 2,234 | spread 2.9% |
| memo alone | 2,199 / 2,203 / 2,224 / 2,187 | spread 1.7% |
| P3 against P0, round by round | −5.9% / −5.6% / −2.5% / +0.9% | median **−4.0%** |
| the memo alone against P0, round by round | −4.4% / −3.6% / −1.7% / −1.3% | median **−2.7%** |

Paired within rounds the effect is real but small: **the retained combination
is worth 3–4%, and the memo alone accounts for nearly all of it.** Adding the
registry and the weighting cache on top of the memo is worth well under a
further percent — which is the same statement as "removing 65% of the request
bytes changed nothing", reached from the other direction.

**Classification: NO MATERIAL WIN.** Below 10%, so §27's rule applies.

## Equivalence

**All 1,863 calls are path-identical.** `bench/phase3a/equivalence.mts` replays
every call twice — model in the body, then model by handle — and compares the
whole answer: distance, weight, time, the full geometry, the complete `edge_id`
sequence, `street_name`, `road_class`, every instruction's sign and interval,
the snapped waypoints and `visited_nodes.sum`. Both protocols fingerprint to
`df1ccef6070f0fd4`.

End-to-end, every stage returned identical route counts, distances, quality
scores, repeated-ground fractions and geometry hashes on all six fixtures, as
did every concurrency level from one to eight.

Engine-call count is reported and never asserted, as in Phases 1 and 2:
`diversityAwareEarlyStop` races concurrent candidates, so `peel-5km` gives
743–779 calls across runs while returning byte-identical walks every time.

## Remaining bottlenecks, ranked by measured contribution

1. **The number of calls — everything.** A leg costs 5.22 ms of call-site
   latency at six-way concurrency, and the only change in this phase that moved
   the end-to-end number is the one that removed calls. It returned about half
   of its share of the call count, which is the exchange rate the next phase
   should budget with.
2. **Contention between concurrent legs — 43% of a leg's latency.** 2.97 ms
   serial against 5.22 ms at six-way. Not a queue; not removable by making a
   call cheaper; only by making fewer.
3. **The per-exchange floor — 0.58 ms a call**, 47% of the 1.24 ms of
   transport that remains, and 1.37 ms against the shipped Dropwizard
   container. Payload cannot touch it and batching costs more than it saves.
   What *would* touch it is fewer exchanges.
4. **`hopper.route` — 1.34 ms a call after this phase**, of which the graph
   search is roughly a quarter. Phase 2's conclusion stands: GraphHopper is not
   where the time is.
5. **JSON, both ends — 0.13 ms a call after this phase**, down from 0.19. No
   longer near the top of the bill, which is why it stays JSON.

## Phase 3B call anatomy

From a traced generation at the retained configuration
(`bench/phase3a/capture.mts`, `calls.mts`). Note the trace itself costs: it
appends a line per call synchronously, which blocks the event loop and inflates
every concurrent call's latency, so a traced generation runs about 30% slower
than an untraced one (2,814 ms against 2,170). The counts and proportions are sound; the totals are not
comparable with the benchmark above.

| where a call's latency went | ms summed | per call | share |
|---|---:|---:|---:|
| waiting for a slot on the shared engine limiter | 19 | 0.01 | 0.2% |
| the round trip, engine included | 11,193 | 6.01 | 95.8% |
| — of which `hopper.route` itself | 2,501 | 1.34 | 21.4% |
| Looper's own work either side of the call | 472 | 0.25 | 4.0% |
| **summed call-site latency** | **11,684** | **6.27** | |

| purpose | calls | memo hits | model references | distinct models | ms summed | mean | mean visited | request KB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `leg` | 1,024 | 76 | 811 | 359 | 6,684 | 6.53 | 495 | 1,168 |
| `join-pullback` | 422 | 22 | 332 | 255 | 2,585 | 6.13 | 262 | 485 |
| `leg-budget` | 201 | 0 | 201 | 92 | 1,436 | 7.14 | 785 | 84 |
| `waypoint-leg` | 147 | 16 | 90 | 74 | 602 | 4.10 | 1,288 | 288 |
| `spike` | 59 | 1 | 59 | 42 | 350 | 5.93 | 372 | 57 |
| `waypoint-direct` | 8 | 3 | 0 | 0 | 11 | 1.38 | 273 | 1 |
| `leg-relaxed` | 2 | 0 | 2 | 1 | 16 | 8.00 | — | 0 |
| **total** | **1,863** | **118** | **1,495** | **738** | **11,684** | | | **2,084** |

| request class | calls | ms summed | mean | median | p95 | mean visited |
|---|---:|---:|---:|---:|---:|---:|
| avoid-strong (`multiply_by 0.05`) | 1,227 | 8,415 | 6.86 | 7 | 12 | 605 |
| avoid-relaxed (`multiply_by 0.2`) | 268 | 1,891 | 7.06 | 7 | 11 | 648 |
| plain (no custom model) | 368 | 1,378 | 3.74 | 4 | 9 | 197 |

Read for the next phase, three things stand out.

**`join-pullback` is 416 calls with 252 distinct models between them.** It
reroutes two legs around a corner pulled back out of a cul-de-sac, and it is
the second-largest consumer of calls in the workload. Almost every one draws a
corridor set nothing else uses — which is why registration helps it least and
why not making the call at all would help it most.

**`leg-budget` never repeats a request.** 201 calls, zero memo hits: a budget
retry is by construction a *different* question (a different bearing, a shorter
reach), so nothing about reuse can touch it. 92 distinct models across 201
calls, and the highest mean settled-node count in the workload at 785.

**`leg` carries 76 of the 118 memo hits.** Where Looper asks the same question
twice, it is overwhelmingly in ordinary leg routing, across candidates that
have converged on the same stretch of ground from different starting bearings.
That is a candidate-generation observation, not a boundary one.

Everything the next phase needs is in the trace: per call, its purpose, the
model handle it named, whether that model had been seen, whether the answer had
been given, what it waited for a slot, what the round trip cost and what
`hopper.route` cost inside it.

## Recommendation

> **Is there meaningful boundary overhead left, or should the next phase focus
> almost entirely on reducing the number of GraphHopper calls?**

**Reduce the number of calls.** There is boundary overhead left, and it is not
addressable by anything that makes a call cheaper.

The evidence is not an impression. Two thirds of the request payload was
removed and the walker's wait did not move. The weighting build was halved and
the walker's wait did not move. The only intervention that moved it removed
6.3% of the calls and returned 2.7% of the wall clock. Meanwhile the per-exchange
floor is 0.58 ms whatever the request says, batching to amortise it costs more
than it saves, keep-alive is already on, and concurrency buys its speed by
dispatching more speculative work rather than by making anything faster.

The brief's own rule applies: the improvement is below 10%, so **boundary state
reuse alone is insufficient and Phase 3B's call-count reduction is the
priority**. 1,863 calls answer six requests; `join-pullback` is 416 of them and
`leg-budget` 201, so a third are fix-ups of legs already routed once. Every
millisecond of every bottleneck ranked above is proportional to that number.

## What is retained, and how to turn it on

Both switches ship **off**, and both need a facade that keeps corridors between
calls. The shipped GraphHopper container does not, says so by not advertising
the capability, and against it the registry turns itself off after one round
trip — so leaving them on where they cannot work is safe, and pointing at a
facade that can is the whole change.

```
LOOPER_MODEL_REGISTRY=false   # name a corridor set once, refer to it after
LOOPER_ROUTE_MEMO=false       # answer an identical request from the one already asked
```

They are deliberately not `AlgorithmFlags`: nothing here can change a route,
and nothing that cannot belongs beside the switches that can.

Retained rather than shipped is the honest status. They are correct, they are
tested, they are path-identical over the whole captured workload, and they cost
less of everything measurable — bytes, JSON, engine time. What they do not do
is make a walker wait less, and until something reduces the call count they
will not. When Phase 3B does reduce it, the boundary work will still be there
and will still be worth its 65%.
