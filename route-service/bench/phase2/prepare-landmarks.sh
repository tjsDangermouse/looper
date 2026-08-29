#!/usr/bin/env bash
# Phase 2 §7: build extra graphs that differ only in how many landmarks were
# prepared.
#
# A separate import per count, into its own directory under bench/phase2/graphs,
# because `prepare.lm.landmarks` is a preparation-time setting: it decides what
# is written to `landmarks_foot`, so it cannot be moved by a request hint or by
# reopening the same graph. Everything else — the extract, the profile, the
# encoded values, the subnetwork threshold — is the container's own config.yml,
# unmodified, so the count is the only variable.
set -euo pipefail
cd "$(dirname "$0")/../.."

# The image already carries the jar, config.yml and looper_foot.json at /gh, so
# nothing is mounted there: mounting the host's copy of the directory over it
# would hide the jar.
for count in "$@"; do
  out="bench/phase2/graphs/lm-$count"
  if [ -s "$out/edges" ]; then echo "lm-$count already built"; continue; fi
  echo "=== importing with prepare.lm.landmarks=$count ==="
  rm -rf "$out"; mkdir -p "$out" bench/phase2/graphs/config

  # `prepare.lm.landmarks` has to be written into the file rather than passed
  # as a Dropwizard `-Ddw.` override. GraphHopper collects its settings into a
  # map with an any-setter, and Dropwizard will only override a path that
  # already exists in the YAML — so an override for a key config.yml does not
  # mention is accepted in silence and ignored, which is how the first attempt
  # at this produced three graphs with sixteen landmarks each.
  conf="bench/phase2/graphs/config/config-lm-$count.yml"
  # After `profiles_ch`, which is a complete entry: inserting between
  # `profiles_lm:` and its own list item would split a sequence from its key.
  awk -v n="$count" '{ print } /^  profiles_ch:/ { print "  prepare.lm.landmarks: " n }' graphhopper/config.yml > "$conf"
  grep -q "prepare.lm.landmarks: $count" "$conf" || { echo "could not write the landmark count into $conf" >&2; exit 1; }
  # `custom_model_files` is resolved relative to the config file, so the
  # profile has to sit beside every copy of it.
  cp graphhopper/looper_foot.json bench/phase2/graphs/config/

  docker run --rm \
    -v "$PWD/data:/data/osm:ro" \
    -v "$PWD/bench/phase2/graphs:/out" \
    -v "$PWD/$conf:/conf.yml:ro" \
    -v "$PWD/graphhopper/looper_foot.json:/looper_foot.json:ro" \
    --entrypoint java looper-graphhopper-iom -Xmx4g -Xms256m \
      -Ddw.graphhopper.datareader.file=/data/osm/isle-of-man-latest.osm.pbf \
      -Ddw.graphhopper.graph.location="/out/lm-$count" \
      -jar /gh/graphhopper-web.jar import /conf.yml
done
du -sh bench/phase2/graphs/* 2>/dev/null || true
