# Phase 9 P13 — materialisation

| representation | walks | via points | median |routed − searched| m | median edge agreement | gate passes | median quality | median compactness |
|---|---:|---:|---:|---:|---:|---:|---:|
| M0 searched walk, unrouted | 12 | 0 | 0 | 100.0% | 12/12 | 77.9 | 0.472 |
| M1 every junction | 12 | 83 | 21 | 92.2% | 9/12 | 75.7 | 0.470 |
| M2 every fourth junction | 12 | 22 | 51 | 65.5% | 3/12 | 70.7 | 0.466 |
| M3 three corners (Phase 8 control) | 12 | 5 | 1486 | 15.1% | 0/12 | 1.1 | 0.056 |

GraphHopper calls: 36, boundary wall 451 ms

## Per walk

| fixture | walk | representation | points | searched m | routed m | delta | edge agreement | pass | rejections |
|---|---:|---|---:|---:|---:|---:|---:|---|---|
| douglas-5km | 0 | M1 every junction | 172 | 4974 | 4997 | 23 | 92.5% | yes | — |
| douglas-5km | 0 | M2 every fourth junction | 44 | 4974 | 4940 | -34 | 59.9% | no | out-and-back-spur |
| douglas-5km | 0 | M3 three corners (Phase 8 control) | 5 | 4974 | 2761 | -2213 | 18.6% | no | distance, repeated-corridor, out-and-back-spur, u-turns, shapeless |
| douglas-5km | 0 | M0 searched walk, unrouted | 0 | 4974 | 4974 | 0 | 100.0% | yes | — |
| douglas-5km | 1 | M1 every junction | 169 | 4949 | 4972 | 23 | 92.2% | yes | — |
| douglas-5km | 1 | M2 every fourth junction | 43 | 4949 | 4939 | -10 | 57.7% | no | out-and-back-spur |
| douglas-5km | 1 | M3 three corners (Phase 8 control) | 5 | 4949 | 2740 | -2210 | 14.7% | no | distance, u-turns, shapeless |
| douglas-5km | 1 | M0 searched walk, unrouted | 0 | 4949 | 4949 | 0 | 100.0% | yes | — |
| douglas-5km | 2 | M1 every junction | 169 | 4949 | 4972 | 23 | 92.3% | yes | — |
| douglas-5km | 2 | M2 every fourth junction | 43 | 4949 | 4939 | -10 | 59.1% | no | out-and-back-spur |
| douglas-5km | 2 | M3 three corners (Phase 8 control) | 5 | 4949 | 2740 | -2210 | 17.8% | no | distance, u-turns, shapeless |
| douglas-5km | 2 | M0 searched walk, unrouted | 0 | 4949 | 4949 | 0 | 100.0% | yes | — |
| douglas-3km | 0 | M1 every junction | 87 | 3004 | 3063 | 59 | 81.0% | no | out-and-back-spur |
| douglas-3km | 0 | M2 every fourth junction | 23 | 3004 | 3071 | 67 | 57.4% | no | out-and-back-spur |
| douglas-3km | 0 | M3 three corners (Phase 8 control) | 5 | 3004 | 2329 | -675 | 14.5% | no | distance, u-turns, shapeless |
| douglas-3km | 0 | M0 searched walk, unrouted | 0 | 3004 | 3004 | 0 | 100.0% | yes | — |
| douglas-3km | 1 | M1 every junction | 88 | 3006 | 3082 | 76 | 75.2% | no | out-and-back-spur |
| douglas-3km | 1 | M2 every fourth junction | 23 | 3006 | 3104 | 98 | 52.1% | no | out-and-back-spur |
| douglas-3km | 1 | M3 three corners (Phase 8 control) | 5 | 3006 | 2285 | -721 | 12.6% | no | distance, u-turns, shapeless |
| douglas-3km | 1 | M0 searched walk, unrouted | 0 | 3006 | 3006 | 0 | 100.0% | yes | — |
| douglas-3km | 2 | M1 every junction | 87 | 3006 | 3082 | 76 | 75.0% | no | out-and-back-spur |
| douglas-3km | 2 | M2 every fourth junction | 23 | 3006 | 3090 | 84 | 52.2% | no | out-and-back-spur |
| douglas-3km | 2 | M3 three corners (Phase 8 control) | 5 | 3006 | 2285 | -721 | 10.3% | no | distance, u-turns, shapeless |
| douglas-3km | 2 | M0 searched walk, unrouted | 0 | 3006 | 3006 | 0 | 100.0% | yes | — |
| peel-5km | 0 | M1 every junction | 49 | 4971 | 4980 | 9 | 97.5% | yes | — |
| peel-5km | 0 | M2 every fourth junction | 13 | 4971 | 4853 | -119 | 77.8% | yes | — |
| peel-5km | 0 | M3 three corners (Phase 8 control) | 5 | 4971 | 2476 | -2495 | 47.7% | no | distance, repeated-corridor, out-and-back-spur, u-turns, shapeless |
| peel-5km | 0 | M0 searched walk, unrouted | 0 | 4971 | 4971 | 0 | 100.0% | yes | — |
| peel-5km | 1 | M1 every junction | 48 | 5033 | 5051 | 18 | 89.3% | yes | — |
| peel-5km | 1 | M2 every fourth junction | 13 | 5033 | 4928 | -105 | 75.9% | yes | — |
| peel-5km | 1 | M3 three corners (Phase 8 control) | 5 | 5033 | 2219 | -2814 | 41.3% | no | distance, repeated-corridor, out-and-back-spur, u-turns |
| peel-5km | 1 | M0 searched walk, unrouted | 0 | 5033 | 5033 | 0 | 100.0% | yes | — |
| peel-5km | 2 | M1 every junction | 46 | 5038 | 5055 | 18 | 89.4% | yes | — |
| peel-5km | 2 | M2 every fourth junction | 13 | 5038 | 4928 | -109 | 71.1% | yes | — |
| peel-5km | 2 | M3 three corners (Phase 8 control) | 5 | 5038 | 2303 | -2734 | 36.5% | no | distance, repeated-corridor, out-and-back-spur |
| peel-5km | 2 | M0 searched walk, unrouted | 0 | 5038 | 5038 | 0 | 100.0% | yes | — |
| onchan-5km | 0 | M1 every junction | 78 | 5037 | 5037 | 0 | 100.0% | yes | — |
| onchan-5km | 0 | M2 every fourth junction | 21 | 5037 | 5070 | 33 | 89.8% | no | out-and-back-spur |
| onchan-5km | 0 | M3 three corners (Phase 8 control) | 5 | 5037 | 4276 | -761 | 12.8% | no | distance, repeated-corridor, u-turns, shapeless, start-spur |
| onchan-5km | 0 | M0 searched walk, unrouted | 0 | 5037 | 5037 | 0 | 100.0% | yes | — |
| onchan-5km | 1 | M1 every junction | 78 | 5038 | 5038 | 0 | 100.0% | yes | — |
| onchan-5km | 1 | M2 every fourth junction | 21 | 5038 | 5070 | 32 | 87.5% | no | out-and-back-spur |
| onchan-5km | 1 | M3 three corners (Phase 8 control) | 5 | 5038 | 4276 | -762 | 12.8% | no | distance, repeated-corridor, u-turns, shapeless, start-spur |
| onchan-5km | 1 | M0 searched walk, unrouted | 0 | 5038 | 5038 | 0 | 100.0% | yes | — |
| onchan-5km | 2 | M1 every junction | 75 | 5040 | 5049 | 9 | 95.2% | yes | — |
| onchan-5km | 2 | M2 every fourth junction | 20 | 5040 | 5070 | 30 | 83.6% | no | out-and-back-spur |
| onchan-5km | 2 | M3 three corners (Phase 8 control) | 5 | 5040 | 4401 | -639 | 15.5% | no | repeated-corridor, u-turns, shapeless |
| onchan-5km | 2 | M0 searched walk, unrouted | 0 | 5040 | 5040 | 0 | 100.0% | yes | — |
