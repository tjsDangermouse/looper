# Phase 7 — network-aware candidate families

This is analysis-only. It does not change production generation.

```sh
docker build -t looper-phase7-field gh-harness
docker run --rm --entrypoint java \
  -v looper_graph-cache-iom:/data/graph-cache:ro \
  -v "$PWD/graphhopper:/gh:ro" -v "$PWD/bench/phase7:/work" \
  looper-phase7-field -Xmx2g -cp /h/gh-harness.jar \
  com.looper.routing.NetworkField /gh/config.yml /data/graph-cache \
  /work/fixtures.json /work/network-fields.json
npx tsx bench/phase7/analyse.mts
```

The field uses GraphHopper's loaded `BaseGraph`, `LocationIndex`, profile
`Weighting` as an access filter, `NodeAccess`, and `EdgeExplorer`. Candidate
legs are still routed by GraphHopper. No production endpoint or second router
is introduced.
