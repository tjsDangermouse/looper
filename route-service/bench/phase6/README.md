# Phase 6 — perimeter retention and contraction attribution

Phase 6 is passive and analysis-first. The capture retains the Phase 3B flags;
the analyser makes no GraphHopper calls and cannot change candidate generation.

```sh
npx tsx bench/phase6/capture.mts P6
CORPUS=corpus-P6 npx tsx bench/phase6/analyse.mts
ROUNDS=4 RUNS=7 npx tsx bench/phase6/paired.mts
npx tsx bench/phase6/capture.mts P6_PROTO LOOPER_PERIMETER_RETENTION=true
```

`initialIntendedPerimeter` is the crow-distance perimeter of the candidate's
initial equal-share guide skeleton, including its geometric closure. Retention
uses a deliberately labelled hybrid effective scale: routed distance already
committed plus the current remaining crow skeleton, divided by that initial
perimeter. Raw values are retained so alternate definitions can be evaluated.

The offline combined-deficit oracle passed its analysis gate, but the bounded
prototype failed the paired production benchmark. It remains default OFF; see
`docs/GRAPHHOPPER_LOOPER_PHASE6_PERIMETER_RETENTION.md`.
