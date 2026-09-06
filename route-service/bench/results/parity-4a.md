# Phase 4a — iOS ↔ remote parity measurement

Remote: `https://www.woollams.com/looper_router`  ·  on-device: /private/tmp/claude-501/-Users-simonwoollams-GitHub-Walkabout/f86d3076-4c9a-48c4-afbe-28ef75fde441/scratchpad/ondevice-parity.log
Generated 2026-09-06T08:17:19.653Z

Each cell is **remote / on-device**. `sameWalk%` is the best geometry
overlap between any remote offer and any on-device offer for that fixture
(≥ 95% ⇒ the two engines found the same walk).

| fixture | offered | sameWalk% | dist err % | pave % | hops/km | u-turns | compactness | worst overlap % |
|---|---|---|---|---|---|---|---|---|
| douglas-3km | 3 / 3 | 64.6 | 6.0 / 3.8 | 72.2 / 57.7 | 4.12 / 3.00 | 0 / 0 | 0.381 / 0.384 | 45.1 / 18.5 |
| douglas-4km | 3 / 3 | 32.0 | 6.0 / 0.8 | 76.1 / 59.8 | 3.29 / 2.01 | 0 / 1 | 0.401 / 0.342 | 12.2 / 30.0 |
| douglas-5km | 3 / 3 | 34.0 | 4.6 / 3.1 | 84.2 / 50.3 | 2.72 / 1.80 | 0 / 1 | 0.427 / 0.276 | 18.2 / 8.6 |
| douglas-8km | 3 / 3 | 85.2 | 1.9 / 1.7 | 86.6 / 76.1 | 1.85 / 1.76 | 0 / 1 | 0.353 / 0.384 | 45.8 / 34.3 |
| peel-5km | 3 / 2 | 96.0 | 4.5 / 6.3 | 59.6 / 82.5 | 1.99 / 0.77 | 0 / 0 | 0.345 / 0.301 | 23.2 / 27.9 |
| onchan-5km | 3 / 3 | 33.2 | 6.3 / 2.9 | 53.2 / 46.3 | 2.60 / 1.69 | 1 / 0 | 0.330 / 0.286 | 13.7 / 17.2 |
| douglas-prom-4km | 3 / 3 | 38.0 | 0.8 / 5.8 | 88.4 / 65.9 | 3.10 / 1.85 | 0 / 0 | 0.427 / 0.366 | 38.2 / 36.9 |
| douglas-wp1-6km | 1 / 1 | 5.2 | 15.2 / 13.6 | 86.4 / — | 2.20 / — | 0 / 0 | 0.595 / 0.225 | 0.0 / 0.0 |
| douglas-wp2-8km | 1 / 2 | 15.5 | 17.6 / 13.3 | 85.3 / — | 1.89 / — | 0 / 2 | 0.243 / 0.327 | 0.0 / 43.4 |

## Gate rejections (histogram, per fixture)

- **douglas-3km** — remote: `{"shapeless":3,"distance":9,"leg-too-long":3,"out-and-back-spur":2,"u-turns":1}`  ·  on-device: `{"distance":6,"leg-too-long":3,"leg-too-short":2,"out-and-back-spur":3,"shapeless":2}`
- **douglas-4km** — remote: `{"distance":9,"shapeless":6,"leg-too-long":3,"leg-too-short":3,"out-and-back-spur":5,"u-turns":2,"repeated-corridor":1}`  ·  on-device: `{"distance":12,"leg-too-long":3,"leg-too-short":2,"out-and-back-spur":9,"repeated-corridor":2,"shapeless":10,"u-turns":2}`
- **douglas-5km** — remote: `{"distance":13,"out-and-back-spur":9,"leg-too-long":9,"leg-too-short":4,"shapeless":5}`  ·  on-device: `{"distance":30,"leg-too-long":10,"leg-too-short":2,"out-and-back-spur":20,"repeated-corridor":5,"shapeless":22,"u-turns":8}`
- **douglas-8km** — remote: `{"out-and-back-spur":12,"distance":12,"leg-too-long":6,"leg-too-short":4,"shapeless":9,"u-turns":3}`  ·  on-device: `{"distance":7,"leg-too-long":1,"leg-too-short":1,"out-and-back-spur":4,"shapeless":8,"u-turns":5}`
- **peel-5km** — remote: `{"out-and-back-spur":8,"shapeless":8,"distance":13,"repeated-corridor":4,"start-spur":4,"leg-too-long":3,"leg-too-short":1}`  ·  on-device: `{"distance":53,"leg-too-long":27,"leg-too-short":7,"out-and-back-spur":66,"repeated-corridor":4,"shapeless":71,"start-spur":1,"u-turns":12}`
- **onchan-5km** — remote: `{}`  ·  on-device: `{"distance":13,"leg-too-long":1,"leg-too-short":1,"out-and-back-spur":11,"shapeless":6,"u-turns":1}`
- **douglas-prom-4km** — remote: `{"out-and-back-spur":9,"shapeless":15,"distance":9,"leg-too-long":6,"leg-too-short":5}`  ·  on-device: `{"distance":15,"leg-too-long":10,"leg-too-short":3,"out-and-back-spur":10,"repeated-corridor":3,"shapeless":15,"u-turns":3}`
- **douglas-wp1-6km** — remote: `{"u-turns":7,"shapeless":15,"out-and-back-spur":17,"distance":5}`  ·  on-device: `{"distance":12,"out-and-back-spur":14,"shapeless":8,"u-turns":4}`
- **douglas-wp2-8km** — remote: `{"distance":15,"shapeless":10,"out-and-back-spur":5,"u-turns":1}`  ·  on-device: `{"distance":9,"out-and-back-spur":25,"repeated-corridor":4,"shapeless":22,"start-spur":2,"u-turns":20}`

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
| douglas-seafront | 1559 / 1561 | +0.1 | 96.7 / 56.7 | 0.64 / 1.92 | 69.7 |
| douglas-inland | 1944 / 1883 | -3.1 | 87.5 / 50.4 | 0.51 / 1.59 | 72.2 |
| onchan | 1542 / 1542 | 0 | 70.3 / 70.3 | 0.65 / 0.65 | 100 |
| peel-control | 536 / — | — | 98.8 / — | 3.73 / — | — _(device: nothingToSnapTo(LooperKit.Point(lng: -4.69, lat: 54.232)))_ |

