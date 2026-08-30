# Phase 5 — Full-Shape Distance Control

Phase 5 is analysis-first. `analyse.mts` reads a passive Phase 4/5 trace and
evaluates F0–F3 against eventual complete candidate distance. It issues no
routing calls and does not alter candidate generation.

```sh
npx tsx bench/phase4/capture.mts P5_FULL
CORPUS=../phase4/corpus-P5_FULL npx tsx bench/phase5/analyse.mts
ROUNDS=4 RUNS=7 npx tsx bench/phase5/baseline.mts
```

The capture's synchronous JSONL timing is not an end-to-end benchmark.
