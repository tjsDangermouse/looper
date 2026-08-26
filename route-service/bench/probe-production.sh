#!/usr/bin/env bash
#
# Ask the live service for a few walks and print what each one cost.
#
#   bench/probe-production.sh [base-url]
#
# These are ordinary route requests — exactly what the app sends — so this is
# safe to run against production. It is rate limited to 20/minute per IP, which
# is why the calls below are spaced.
#
# What to look at:
#   wall vs engineMs   the gap is parallelism. If engineMs/wall is well under
#                      ROUTING_CONCURRENCY, walkers are waiting on
#                      serialisation rather than on the engine.
#   pull/budget/spike  the per-leg fix-ups. They were 43% of all calls before
#                      the gates went in.
#   stage              waypoint requests only: where the generator gave up.
set -euo pipefail
BASE="${1:-https://www.woollams.com/looper_router}"

ask() {
  local name="$1" body="$2"
  local began ended
  began=$(python3 -c 'import time;print(time.time())')
  curl -s -o "/tmp/looper_probe_$name.json" -X POST "$BASE/v1/loops" \
    -H 'Content-Type: application/json' -d "$body" --max-time 45 || true
  ended=$(python3 -c 'import time;print(time.time())')
  python3 - "$name" "$began" "$ended" <<'PY'
import json, sys
name, began, ended = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
try:
    answer = json.load(open(f'/tmp/looper_probe_{name}.json'))
except Exception:
    print(f'{name:16} no answer'); raise SystemExit
routes = len(answer.get('routes') or [])
diagnostics = answer.get('diagnostics') or {}
metrics = diagnostics.get('metrics')
stage = diagnostics.get('stage', '-')
if not metrics:
    warning = (answer.get('warning') or '')[:44]
    print(f'{name:16} {ended-began:5.1f}s routes={routes} (no metrics — old build?) {warning!r}')
    raise SystemExit
calls = metrics['callsByPurpose']
fixups = metrics.get('fixups', {})
kept = ' '.join(f"{k.split('-')[-1]}={v['kept']}/{v['attempted']}" for k, v in fixups.items())
total = metrics['graphhopperCalls'] or 1
print(f"{name:16} {ended-began:5.1f}s routes={routes} calls={metrics['graphhopperCalls']:4} "
      f"ms/call={metrics['engineMs']/total:5.1f} par={metrics['engineMs']/max(1, metrics['totalMs']):4.2f}x "
      f"pull={calls['join-pullback']:3} budget={calls['leg-budget']:3} stage={stage}")
print(f"{'':16} fixups kept: {kept}")
areas = metrics.get('engineMsByAreas')
if areas:
    # If ms/call climbs with polygon count, the anti-retrace areas are the
    # ceiling and fewer or simpler ones buy more than any call reduction.
    cells = ' '.join(f"{b}:{v['ms']/v['calls']:.0f}ms/{v['calls']}" for b, v in areas.items() if v['calls'])
    print(f"{'':16} ms per call by avoidance polygons -> {cells}")
backbone = diagnostics.get('backboneStage')
if backbone:
    print(f"{'':16} backbone gave up at {backbone}: {json.dumps(diagnostics.get('backboneRejections') or {})}")
PY
}

START='"start":{"lng":-4.4816,"lat":54.1506}'
ask douglas-5km  "{$START,\"mode\":\"distance\",\"distanceKm\":5,\"units\":\"km\",\"variation\":0}"; sleep 2
ask douglas-3km  "{$START,\"mode\":\"distance\",\"distanceKm\":3,\"units\":\"km\",\"variation\":0}"; sleep 2
ask peel-5km     '{"start":{"lng":-4.6947,"lat":54.2247},"mode":"distance","distanceKm":5,"units":"km","variation":0}'; sleep 2
ask onchan-5km   '{"start":{"lng":-4.4530,"lat":54.1745},"mode":"distance","distanceKm":5,"units":"km","variation":0}'; sleep 2
ask wp-one       "{$START,\"mode\":\"distance\",\"distanceKm\":6,\"units\":\"km\",\"variation\":0,\"waypoints\":[{\"lng\":-4.4746,\"lat\":54.1566}]}"; sleep 2
ask wp-two       "{$START,\"mode\":\"distance\",\"distanceKm\":8,\"units\":\"km\",\"variation\":0,\"waypoints\":[{\"lng\":-4.4700,\"lat\":54.1560},{\"lng\":-4.4900,\"lat\":54.1600}]}"
