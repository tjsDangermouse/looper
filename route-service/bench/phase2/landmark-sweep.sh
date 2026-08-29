#!/usr/bin/env bash
# Phase 2 §6 and §7: the landmark matrix.
#
# The same corpus, the same JVM settings, the same everything, against three
# preparations that differ only in how many landmarks were computed — and,
# within each, several active counts. Run as separate JVMs per preparation
# because the prepared count is a property of the graph on disk.
set -euo pipefail
cd "$(dirname "$0")/../.."

for prepared in 16 32 64; do
  # Active counts above the prepared count throw rather than clamp, so each
  # preparation is asked only for the ones it can answer.
  case "$prepared" in
    16) configs="baseline active-2 active-4 active-6 active-8 active-12 active-16" ;;
    32) configs="baseline active-4 active-8 active-12 active-16 active-24 active-32" ;;
    64) configs="baseline active-4 active-8 active-12 active-16 active-24 active-32" ;;
  esac
  echo "=== prepared: $prepared ==="
  # The config that built this graph, not the shipped one. GraphHopper checks
  # the requested active count against `prepare.lm.landmarks` as the *config*
  # states it, not against what the storage on disk actually holds, so serving
  # a 32-landmark graph under the 16-landmark config refuses any active count
  # above 16 — and silently caps the default at 8.
  docker run --rm \
    -v "$PWD/bench/phase2/graphs/lm-$prepared:/data/graph-cache:ro" \
    -v "$PWD/graphhopper:/gh:ro" \
    -v "$PWD/bench/phase2/graphs/config:/conf:ro" \
    -v "$PWD/bench/phase2:/lab" \
    --entrypoint java looper-gh-harness -Xmx2g -Xms256m -cp /h/gh-harness.jar \
    com.looper.routing.Lab "/conf/config-lm-$prepared.yml" /data/graph-cache /lab/corpus \
      "/lab/results/lm-prepared-$prepared.json" 5 $configs 2>&1 | grep -E "^  |Exception"
done
