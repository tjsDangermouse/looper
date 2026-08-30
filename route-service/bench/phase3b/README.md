# Phase 3B — reducing the number of GraphHopper calls

Phase 3A said the only lever left is the call count. These scripts find out
where the calls come from, remove the ones that are avoidable, and measure what
that was worth. See `docs/GRAPHHOPPER_LOOPER_PHASE3B_CALL_REDUCTION.md`.

Everything needs a facade on `:8991` (`bench/phase3a/facades.sh`).

| script | what it answers |
|---|---|
| `capture.mts <label> [FLAG=value ...]` | one traced generation per fixture at a named configuration, into `corpus-<label>/` |
| `corpus.mts` | reads a corpus back; `CORPUS=corpus-B0` selects which |
| `graph.mts` | §2–§5, §8, §21–§24 — the parent/child graph, fix-up anatomy, calls per candidate and what each candidate came to |
| `experiments.mts` | §25 — every stage on its own service, one flag at a time |
| `scheduling.mts <label> [FLAG=value ...]` | §16–§18 — the fan-out swept, with route identity asserted across levels |
| `gate.mts` | §29, §30, §32 — the retained combination against the baseline, paired inside alternating rounds |

```sh
npx tsx bench/phase3b/capture.mts B0
CORPUS=corpus-B0 npx tsx bench/phase3b/graph.mts
npx tsx bench/phase3b/experiments.mts
npx tsx bench/phase3b/scheduling.mts B0
npx tsx bench/phase3b/gate.mts
```

The trace costs what it always did: a line per call, written synchronously, so
a traced generation runs about a third slower than an untraced one. Counts and
proportions are sound; its wall times are not comparable with the benchmarks.
