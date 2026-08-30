#!/usr/bin/env bash
# Two facades, identical but for whether a registered model's weighting is
# reused: :8991 reuses it, :8992 rebuilds it every call. That is the only way
# to say what the registry buys on the wire and what it buys inside the engine
# without inferring one from the other.
set -euo pipefail
cd "$(dirname "$0")/../.."
docker build -q -t looper-gh-harness gh-harness >/dev/null
for spec in "looper-core:8991:" "looper-core-norebuild:8992:-Dlooper.registry.reuse_weighting=false"; do
  name="${spec%%:*}"; rest="${spec#*:}"; port="${rest%%:*}"; prop="${rest#*:}"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" -p "$port:$port" \
    -v looper_graph-cache-iom:/data/graph-cache:ro -v "$PWD/graphhopper:/gh:ro" \
    --entrypoint java looper-gh-harness -Xmx2g -Xms256m ${prop:+$prop} \
    -cp /h/gh-harness.jar com.looper.routing.Serve /gh/config.yml /data/graph-cache "$port" >/dev/null
done
for port in 8991 8992; do
  for _ in $(seq 1 60); do curl -sf "http://localhost:$port/info" >/dev/null && break; sleep 1; done
  echo "$port $(curl -s "http://localhost:$port/info" | head -c 80)"
done
