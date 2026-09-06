# Phase 4a — iOS ↔ remote parity measurement

Remote: `https://www.woollams.com/looper_router`  ·  on-device: /private/tmp/claude-501/-Users-simonwoollams-GitHub-Walkabout/f86d3076-4c9a-48c4-afbe-28ef75fde441/scratchpad/ondevice-parity.log
Generated 2026-09-06T09:16:45.427Z

Each cell is **remote / on-device**. `sameWalk%` is the best geometry
overlap between any remote offer and any on-device offer for that fixture
(≥ 95% ⇒ the two engines found the same walk).

| fixture | offered | sameWalk% | dist err % | pave % | hops/km | u-turns | compactness | worst overlap % |
|---|---|---|---|---|---|---|---|---|
| douglas-3km | 3 / 3 | 82.6 | 6.0 / 3.9 | 72.2 / 63.1 | 4.12 / 2.53 | 0 / 0 | 0.381 / 0.401 | 45.1 / 51.2 |
| douglas-4km | 3 / 3 | 34.1 | 6.0 / 1.0 | 76.1 / 66.9 | 3.29 / 1.68 | 0 / 0 | 0.401 / 0.326 | 12.2 / 37.7 |
| douglas-5km | 3 / 3 | 33.8 | 4.6 / 3.1 | 84.2 / 55.3 | 2.72 / 1.42 | 0 / 1 | 0.427 / 0.276 | 18.2 / 8.6 |
| douglas-8km | 3 / 3 | 84.9 | 1.9 / 1.7 | 86.6 / 85.2 | 1.85 / 1.53 | 0 / 1 | 0.353 / 0.389 | 45.8 / 34.7 |
| peel-5km | 3 / 2 | 96.0 | 4.5 / 6.3 | 59.6 / 82.5 | 1.99 / 0.77 | 0 / 0 | 0.345 / 0.301 | 23.2 / 27.9 |
| onchan-5km | 3 / 3 | 33.2 | 6.3 / 2.9 | 53.2 / 51.5 | 2.60 / 1.69 | 1 / 0 | 0.330 / 0.286 | 13.7 / 17.2 |
| douglas-prom-4km | 3 / 3 | 47.6 | 0.8 / 7.2 | 88.4 / 66.0 | 3.10 / 1.40 | 0 / 0 | 0.427 / 0.408 | 38.2 / 44.6 |
| douglas-wp1-6km | 1 / 1 | 4.4 | 15.2 / 13.6 | 86.4 / — | 2.20 / — | 0 / 0 | 0.595 / 0.234 | 0.0 / 0.0 |
| douglas-wp2-8km | 1 / 2 | 15.5 | 17.6 / 13.3 | 85.3 / — | 1.89 / — | 0 / 2 | 0.243 / 0.327 | 0.0 / 43.4 |

## Per-route best match (offer-set agreement)

For each remote offer, its best geometry overlap with any on-device
offer, and vice versa. Three high numbers ⇒ the same three walks.

- **douglas-3km** — remote→device best overlap: [65, 83, 7] %  ·  device→remote: [65, 1, 83] %
- **douglas-4km** — remote→device best overlap: [34, 32, 7] %  ·  device→remote: [28, 32, 34] %
- **douglas-5km** — remote→device best overlap: [26, 34, 17] %  ·  device→remote: [34, 26, 2] %
- **douglas-8km** — remote→device best overlap: [85, 60, 42] %  ·  device→remote: [60, 85, 35] %
- **peel-5km** — remote→device best overlap: [42, 9, 96] %  ·  device→remote: [42, 96] %
- **onchan-5km** — remote→device best overlap: [7, 5, 33] %  ·  device→remote: [33, 7, 19] %
- **douglas-prom-4km** — remote→device best overlap: [48, 36, 38] %  ·  device→remote: [34, 48, 26] %
- **douglas-wp1-6km** — remote→device best overlap: [4] %  ·  device→remote: [4] %
- **douglas-wp2-8km** — remote→device best overlap: [15] %  ·  device→remote: [15, 12] %

## Candidate throughput

Remote routes ~24 candidates and stops; on-device judges a pool of up
to 256 (by design — no wire). Compare the **pass rate**, not the raw
reject counts.

| fixture | remote routed → passed (rate) | on-device closed → passed (rate) |
|---|---|---|
| douglas-3km | 14 → 4 (29%) | 16 → 5 (31%) |
| douglas-4km | 16 → 4 (25%) | 24 → 6 (25%) |
| douglas-5km | 22 → 5 (23%) | 44 → 4 (9%) |
| douglas-8km | 21 → 4 (19%) | 16 → 4 (25%) |
| peel-5km | 24 → 5 (21%) | 110 → 5 (5%) |
| onchan-5km | 4 → 4 (100%) | 24 → 5 (21%) |
| douglas-prom-4km | 24 → 5 (21%) | 27 → 5 (19%) |
| douglas-wp1-6km | 24 → 1 (4%) | — |
| douglas-wp2-8km | 17 → 1 (6%) | — |

## Gate rejections (histogram, per fixture)

- **douglas-3km** — remote: `{"shapeless":3,"distance":9,"leg-too-long":3,"out-and-back-spur":2,"u-turns":1}`  ·  on-device: `{"distance":6,"leg-too-long":2,"leg-too-short":2,"out-and-back-spur":3,"shapeless":3}`
- **douglas-4km** — remote: `{"distance":9,"shapeless":6,"leg-too-long":3,"leg-too-short":3,"out-and-back-spur":5,"u-turns":2,"repeated-corridor":1}`  ·  on-device: `{"distance":10,"leg-too-long":3,"leg-too-short":1,"out-and-back-spur":9,"repeated-corridor":2,"shapeless":10,"u-turns":2}`
- **douglas-5km** — remote: `{"distance":13,"out-and-back-spur":9,"leg-too-long":9,"leg-too-short":4,"shapeless":5}`  ·  on-device: `{"distance":30,"leg-too-long":7,"leg-too-short":3,"out-and-back-spur":19,"repeated-corridor":5,"shapeless":20,"u-turns":8}`
- **douglas-8km** — remote: `{"out-and-back-spur":12,"distance":12,"leg-too-long":6,"leg-too-short":4,"shapeless":9,"u-turns":3}`  ·  on-device: `{"distance":8,"leg-too-long":1,"leg-too-short":1,"out-and-back-spur":3,"shapeless":8,"u-turns":5}`
- **peel-5km** — remote: `{"out-and-back-spur":8,"shapeless":8,"distance":13,"repeated-corridor":4,"start-spur":4,"leg-too-long":3,"leg-too-short":1}`  ·  on-device: `{"distance":53,"leg-too-long":27,"leg-too-short":7,"out-and-back-spur":66,"repeated-corridor":4,"shapeless":71,"start-spur":1,"u-turns":12}`
- **onchan-5km** — remote: `{}`  ·  on-device: `{"distance":14,"leg-too-long":1,"leg-too-short":1,"out-and-back-spur":11,"shapeless":6,"u-turns":1}`
- **douglas-prom-4km** — remote: `{"out-and-back-spur":9,"shapeless":15,"distance":9,"leg-too-long":6,"leg-too-short":5}`  ·  on-device: `{"distance":18,"elongated":1,"leg-too-long":8,"leg-too-short":4,"out-and-back-spur":11,"repeated-corridor":3,"shapeless":18,"u-turns":4}`
- **douglas-wp1-6km** — remote: `{"u-turns":7,"shapeless":15,"out-and-back-spur":17,"distance":5}`  ·  on-device: `{"distance":12,"out-and-back-spur":12,"shapeless":8,"u-turns":4}`
- **douglas-wp2-8km** — remote: `{"distance":15,"shapeless":10,"out-and-back-spur":5,"u-turns":1}`  ·  on-device: `{"distance":9,"out-and-back-spur":25,"repeated-corridor":5,"shapeless":26,"u-turns":23}`

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
| douglas-seafront | 1559 / 1553 | -0.4 | 96.7 / 96.7 | 0.64 / 0.64 | 68.2 |
| douglas-inland | 1944 / 1868 | -3.9 | 87.5 / 100 | 0.51 / 0 | 59.3 |
| onchan | 1542 / 1542 | 0 | 70.3 / 70.3 | 0.65 / 0.65 | 100 |
| peel-control | 536 / — | — | 98.8 / — | 3.73 / — | — _(device: nothingToSnapTo(LooperKit.Point(lng: -4.69, lat: 54.232)))_ |

