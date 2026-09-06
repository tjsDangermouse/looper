# Phase 4a — iOS ↔ remote parity measurement

Remote: `https://www.woollams.com/looper_router`  ·  on-device: /private/tmp/claude-501/-Users-simonwoollams-GitHub-Walkabout/f86d3076-4c9a-48c4-afbe-28ef75fde441/scratchpad/baseline-parity.log
Generated 2026-09-06T09:43:40.713Z

Each cell is **remote / on-device**. `sameWalk%` is the best geometry
overlap between any remote offer and any on-device offer for that fixture
(≥ 95% ⇒ the two engines found the same walk).

| fixture | offered | sameWalk% | dist err % | pave % | hops/km | u-turns | compactness | worst overlap % |
|---|---|---|---|---|---|---|---|---|
| douglas-3km | 3 / 3 | 73.7 | 6.0 / 3.0 | 72.2 / 60.6 | 4.12 / 4.80 | 0 / 0 | 0.381 / 0.351 | 45.1 / 14.9 |
| douglas-4km | 3 / 3 | 53.4 | 6.0 / 5.8 | 76.1 / 72.0 | 3.29 / 4.44 | 0 / 0 | 0.401 / 0.360 | 12.2 / 20.7 |
| douglas-5km | 3 / 3 | 36.4 | 4.6 / 3.4 | 84.2 / 54.5 | 2.72 / 2.82 | 0 / 1 | 0.427 / 0.276 | 18.2 / 10.7 |
| douglas-8km | 3 / 3 | 87.6 | 1.9 / 4.3 | 86.6 / 74.9 | 1.85 / 2.96 | 0 / 0 | 0.353 / 0.380 | 45.8 / 27.6 |
| peel-5km | 3 / 3 | 96.0 | 4.5 / 4.1 | 59.6 / 67.6 | 1.99 / 1.34 | 0 / 0 | 0.345 / 0.308 | 23.2 / 28.8 |
| onchan-5km | 3 / 3 | 93.5 | 6.3 / 4.7 | 53.2 / 48.6 | 2.60 / 3.08 | 1 / 0 | 0.330 / 0.319 | 13.7 / 32.7 |
| douglas-prom-4km | 3 / 3 | 38.0 | 0.8 / 6.0 | 88.4 / 78.8 | 3.08 / 4.47 | 0 / 0 | 0.427 / 0.382 | 38.2 / 57.0 |
| douglas-wp1-6km | 1 / 3 | 71.8 | 15.2 / 20.7 | 86.4 / — | 2.20 / — | 0 / 0 | 0.595 / 0.333 | 0.0 / 45.8 |
| douglas-wp2-8km | 1 / 2 | 17.0 | 17.6 / 9.1 | 85.3 / — | 1.89 / — | 0 / 2 | 0.243 / 0.271 | 0.0 / 37.8 |

## Per-route best match (offer-set agreement)

For each remote offer, its best geometry overlap with any on-device
offer, and vice versa. Three high numbers ⇒ the same three walks.

- **douglas-3km** — remote→device best overlap: [74, 45, 31] %  ·  device→remote: [74, 24, 31] %
- **douglas-4km** — remote→device best overlap: [18, 53, 15] %  ·  device→remote: [18, 25, 53] %
- **douglas-5km** — remote→device best overlap: [26, 36, 16] %  ·  device→remote: [36, 26, 2] %
- **douglas-8km** — remote→device best overlap: [88, 62, 43] %  ·  device→remote: [62, 88, 23] %
- **peel-5km** — remote→device best overlap: [67, 84, 96] %  ·  device→remote: [84, 67, 96] %
- **onchan-5km** — remote→device best overlap: [13, 94, 22] %  ·  device→remote: [22, 94, 18] %
- **douglas-prom-4km** — remote→device best overlap: [9, 3, 38] %  ·  device→remote: [20, 29, 38] %
- **douglas-wp1-6km** — remote→device best overlap: [72] %  ·  device→remote: [72, 5, 5] %
- **douglas-wp2-8km** — remote→device best overlap: [17] %  ·  device→remote: [17, 12] %

## Candidate throughput

Remote routes ~24 candidates and stops; on-device judges a pool of up
to 256 (by design — no wire). Compare the **pass rate**, not the raw
reject counts.

| fixture | remote routed → passed (rate) | on-device closed → passed (rate) |
|---|---|---|
| douglas-3km | 14 → 4 (29%) | 16 → 4 (25%) |
| douglas-4km | 16 → 4 (25%) | 16 → 5 (31%) |
| douglas-5km | 22 → 5 (23%) | 44 → 4 (9%) |
| douglas-8km | 21 → 4 (19%) | 10 → 4 (40%) |
| peel-5km | 24 → 5 (21%) | 56 → 3 (5%) |
| onchan-5km | 4 → 4 (100%) | 16 → 4 (25%) |
| douglas-prom-4km | 24 → 5 (21%) | 34 → 5 (15%) |
| douglas-wp1-6km | 24 → 1 (4%) | — |
| douglas-wp2-8km | 17 → 1 (6%) | — |

## Gate rejections (histogram, per fixture)

- **douglas-3km** — remote: `{"shapeless":3,"distance":9,"leg-too-long":3,"out-and-back-spur":2,"u-turns":1}`  ·  on-device: `{"distance":8,"leg-too-long":3,"leg-too-short":1,"out-and-back-spur":4,"shapeless":2}`
- **douglas-4km** — remote: `{"distance":9,"shapeless":6,"leg-too-long":3,"leg-too-short":3,"out-and-back-spur":5,"u-turns":2,"repeated-corridor":1}`  ·  on-device: `{"distance":8,"leg-too-long":2,"leg-too-short":1,"out-and-back-spur":5,"shapeless":6,"u-turns":1}`
- **douglas-5km** — remote: `{"distance":13,"out-and-back-spur":9,"leg-too-long":9,"leg-too-short":4,"shapeless":5}`  ·  on-device: `{"distance":30,"leg-too-long":9,"leg-too-short":2,"out-and-back-spur":19,"repeated-corridor":5,"shapeless":23,"u-turns":8}`
- **douglas-8km** — remote: `{"out-and-back-spur":12,"distance":12,"leg-too-long":6,"leg-too-short":4,"shapeless":9,"u-turns":3}`  ·  on-device: `{"distance":4,"leg-too-long":1,"leg-too-short":1,"out-and-back-spur":3,"shapeless":2,"u-turns":1}`
- **peel-5km** — remote: `{"out-and-back-spur":8,"shapeless":8,"distance":13,"repeated-corridor":4,"start-spur":4,"leg-too-long":3,"leg-too-short":1}`  ·  on-device: `{"distance":25,"leg-too-long":13,"leg-too-short":2,"out-and-back-spur":36,"repeated-corridor":4,"shapeless":35,"start-spur":1,"u-turns":9}`
- **onchan-5km** — remote: `{}`  ·  on-device: `{"distance":7,"out-and-back-spur":5,"shapeless":4,"u-turns":1}`
- **douglas-prom-4km** — remote: `{"out-and-back-spur":9,"shapeless":15,"distance":9,"leg-too-long":6,"leg-too-short":5}`  ·  on-device: `{"distance":24,"leg-too-long":15,"leg-too-short":5,"out-and-back-spur":17,"repeated-corridor":4,"shapeless":21,"u-turns":6}`
- **douglas-wp1-6km** — remote: `{"u-turns":7,"shapeless":15,"out-and-back-spur":17,"distance":5}`  ·  on-device: `{"distance":9,"out-and-back-spur":7,"shapeless":8,"u-turns":4}`
- **douglas-wp2-8km** — remote: `{"distance":15,"shapeless":10,"out-and-back-spur":5,"u-turns":1}`  ·  on-device: `{"distance":9,"out-and-back-spur":25,"repeated-corridor":2,"shapeless":21,"u-turns":25}`

## Notes

- pave% basis: remote from `steps[].roadClass`, on-device from
  `diagnostics.offeredPavement` (both edge-level). hops/km: remote is the
  run-level `diagnostics.metrics.pavementHopsPerKm`; on-device is the mean
  of the offered routes. Treat hops/km as indicative, not exact.
- The leg-routing ceiling section below is written by `bench/parity-legs.ts`
  against a local GraphHopper (`docker start looper-graphhopper-iom-1`).
- Analysis and the proposed 4b list: [`parity-4a-findings.md`](./parity-4a-findings.md).

## Leg-routing ceiling (LocalLegRouter vs local GraphHopper)

GraphHopper: `http://localhost:8989` (profile `foot`, `looper_foot.json`)

| leg | metres (gh / device) | Δ% | pave % (gh / device) | hops/km (gh / device) | corridor overlap % |
|---|---|---|---|---|---|
| douglas-seafront | 1559 / 1564 | +0.3 | 96.7 / 65 | 0.64 / 3.2 | 87.9 |
| douglas-inland | 1944 / 1883 | -3.1 | 87.5 / 50.4 | 0.51 / 1.59 | 72.2 |
| onchan | 1542 / 1542 | 0 | 70.3 / 70.3 | 0.65 / 0.65 | 100 |
| peel-control | 536 / — | — | 98.8 / — | 3.73 / — | — _(device: nothingToSnapTo(LooperKit.Point(lng: -4.69, lat: 54.232)))_ |
| bucks-road | 640 / 679 | +6.1 | 85.2 / 84.3 | 3.12 / 5.89 | 83.3 |

