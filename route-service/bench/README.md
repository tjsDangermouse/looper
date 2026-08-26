# Offline benchmark

```
npm run bench                          every scenario, printed as a table
npm run bench -- --save baseline       also write bench/results/baseline.json
npm run bench -- --compare baseline    diff this run against a saved one
npm run bench -- --only urban,rural    subset by id substring
npm run bench -- --repeats 3           repeat each scenario; medians are reported
```

## What it runs against

There is no GraphHopper here and no OSM extract in a unit test, so the
benchmark routes over small synthetic pedestrian networks built in
`network.ts`: real nodes, real edges, a real Dijkstra search, and avoidance
modelled the way GraphHopper models it — a priority multiplier folded into the
weight denominator, so a penalised corridor costs twenty times its length and
is walked anyway when nothing else exists.

Responses are emitted as GraphHopper's own JSON and parsed with the service's
own `parseLeg`, so the benchmark exercises the real response path rather than a
hand-made object that can drift from what the engine sends.

The five networks are chosen for their structure, not their realism:

| network | what it is for |
| --- | --- |
| `dense-grid` | the easy case every other number is read against |
| `suburban` | cul-de-sacs and missing through-links: where spurs come from |
| `sparse-rural` | few circuits exist at any given length |
| `coastal` | half the compass is sea, so half the candidate bearings are wasted |
| `bridge-chokepoint` | two banks, one bridge: retracing that is structural, not sloppy |

## What the numbers mean

**Exact and comparable across machines:** engine call counts, routes offered,
distance error, retrace percentage, alternative-to-alternative shared ground.
The network is fixed and the search is deterministic, so any change in these is
a real change in the algorithm.

**Not comparable across machines:** wall-clock timings. They are useful within
one run — which scenario is expensive relative to the others — and for
comparing two runs on the same machine back to back. Nothing more.

**Not a claim about real ground.** A synthetic grid cannot tell you what a walk
through Douglas looks like. It can tell you that a change costs 40% more engine
calls, or that it stopped finding anything at all on a coastal start. Real-map
verification needs a running engine (see `docker-compose.yml`) and is a
separate exercise.

`valid` in the table means the scenario produced what it was supposed to
produce — routes where routes should exist, and nothing where the request was
genuinely impossible. A `MISS` is a case where a walk plausibly exists and the
generator did not find it; those are the rows worth improving.
