#!/usr/bin/env bash
# GraphHopper container entrypoint.
#
#   serve   (default) start the routing server, importing first only if no
#           graph has been built yet
#   import  build the graph from an OSM extract, replacing any existing one
#
# The import is deliberately not repeated on every start: it is the slow,
# memory-hungry part, and the graph cache lives on a persistent volume so a
# restart should be seconds, not minutes.
set -euo pipefail

JAR=/gh/graphhopper-web.jar
CONFIG=${GH_CONFIG:-/gh/config.yml}
GRAPH_DIR=${GH_GRAPH_DIR:-/data/graph-cache}
OSM_DIR=${GH_OSM_DIR:-/data/osm}
HEAP=${GH_HEAP:-2g}

# Accepts a local path (absolute, or relative to $OSM_DIR) or an http(s) URL.
# Prints the resolved local path.
resolve_pbf() {
  local source="${1:-}"
  [ -n "$source" ] || { echo "No OSM source given. Set OSM_PBF_PATH or OSM_PBF_URL." >&2; return 1; }

  case "$source" in
    http://*|https://*)
      local name target
      name=$(basename "${source%%\?*}")
      target="$OSM_DIR/$name"
      if [ -s "$target" ]; then
        echo "Reusing already downloaded $target" >&2
      else
        echo "Downloading $source" >&2
        mkdir -p "$OSM_DIR"
        curl -fSL --retry 3 -o "$target.part" "$source"
        mv "$target.part" "$target"
      fi
      echo "$target"
      ;;
    /*)
      [ -s "$source" ] || { echo "OSM extract not found: $source" >&2; return 1; }
      echo "$source"
      ;;
    *)
      [ -s "$OSM_DIR/$source" ] || { echo "OSM extract not found: $OSM_DIR/$source" >&2; return 1; }
      echo "$OSM_DIR/$source"
      ;;
  esac
}

# Which extract to import: an explicit argument wins, then OSM_PBF_PATH if the
# file is actually there, then OSM_PBF_URL. The path-then-URL order lets a host
# keep a local extract and still bootstrap from nothing on a fresh volume.
pick_source() {
  if [ -n "${1:-}" ]; then echo "$1"; return; fi
  local given="${OSM_PBF_PATH:-}"
  if [ -n "$given" ]; then
    case "$given" in
      /*) [ -s "$given" ] && { echo "$given"; return; } ;;
      *)  [ -s "$OSM_DIR/$given" ] && { echo "$given"; return; } ;;
    esac
    echo "OSM_PBF_PATH=$given not found; falling back to OSM_PBF_URL." >&2
  fi
  echo "${OSM_PBF_URL:-}"
}

# A built graph always contains an `edges` file; anything less is a half-done
# import we should not try to serve.
graph_ready() { [ -s "$GRAPH_DIR/edges" ]; }

run_import() {
  local pbf
  pbf=$(resolve_pbf "$(pick_source "${1:-}")")
  echo "Importing $pbf into $GRAPH_DIR"
  rm -rf "${GRAPH_DIR:?}/"* 2>/dev/null || true
  mkdir -p "$GRAPH_DIR"
  # Dropwizard takes config overrides as -Ddw.<path> system properties, which
  # keeps config.yml free of anything environment-specific.
  java -Xmx"$HEAP" -Xms256m \
    "-Ddw.graphhopper.datareader.file=$pbf" \
    "-Ddw.graphhopper.graph.location=$GRAPH_DIR" \
    -jar "$JAR" import "$CONFIG"
  echo "Import finished."
}

case "${1:-serve}" in
  import)
    shift || true
    run_import "${1:-}"
    ;;
  serve)
    if graph_ready; then
      echo "Existing graph found in $GRAPH_DIR — skipping import."
    else
      echo "No graph in $GRAPH_DIR — importing once."
      run_import ""
    fi
    exec java -Xmx"$HEAP" -Xms256m \
      "-Ddw.graphhopper.graph.location=$GRAPH_DIR" \
      -jar "$JAR" server "$CONFIG"
    ;;
  *)
    exec "$@"
    ;;
esac
