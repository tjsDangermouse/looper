# Looper

Finding circular walks that bring you back to where you started, as a native iPhone and
Apple Watch app and as a mobile-first web PWA.

Looper generates its own loops. It proposes rings of waypoints around you, routes each
leg of the ring separately while holding the ground already walked against the next leg,
measures every finished candidate, and offers only the ones that are genuinely loops.
Nothing here asks a routing engine for a "round trip".

```text
Looper iOS + watchOS  ─┐
    (Swift/LooperKit)  │
                       ├──►  Looper Route Service  ─────►  self-hosted GraphHopper
Looper PWA  ───────────┘        POST /v1/loops              (walking graph)
 (Vite/React)                                                       │
                                                             OpenStreetMap PBF

map-styles.json  ──►  generated Swift + TypeScript palettes  ──►  both clients
   (style editor, web dev server only)
```

Two first-class clients, one API. The iOS app is native Swift — not a wrapper around the
PWA — with an Apple Watch companion for live guidance, and it shares no source code with
the web app. Both meet the route service only through
[Loop API v1](route-service/contracts/loop-api/v1.md).

Map styling is shared rather than duplicated: a style editor served by the web development
server writes `map-styles.json` and regenerates the Swift and TypeScript palette files
from it, so a colour is picked once and both clients get it.

Both apps talk to Looper's own API for routing. There is no third-party routing provider
and no routing API key anywhere in this repository. Both clients render their basemap
with MapLibre using OpenFreeMap's hosted Liberty vector style. The optional Looper
treatment restyles those same vector layers; map data still comes from OpenStreetMap.

## Repository map

| Path | What it is |
| --- | --- |
| `web/` | The web PWA — [web guide](web/README.md) |
| `ios/` | Native iPhone and Apple Watch apps, and the shared `LooperKit` package — [iOS guide](ios/README.md) |
| `route-service/` | Route API and all of its deployment assets — [service guide](route-service/README.md) |
| `route-service/contracts/loop-api/v1.md` | Versioned API contract shared by the web and iOS clients |
| `map-styles.json` | The map style catalogue: source of truth for both clients' palettes |
| `web/dev/mapStyleBackend.ts` | The style editor's backend, a Vite dev-server plugin — development only, never shipped |

The three product areas have no source-code imports between them. The web and
iOS clients meet the route service only through [Loop API v1](route-service/contracts/loop-api/v1.md).
GraphHopper, Compose files, data documentation, and the API contract are
operational assets owned by the route service and already sit within its
extraction boundary.

## Map rendering

Both clients use MapLibre with OpenFreeMap's hosted Liberty style. The map switch offers
the untouched style as **Default** plus every custom style saved in the catalogue.
Looper subdues motorways and POIs, clarifies parks and woodland, and adds strong,
separately coloured vector layers for footways, trails and cycleways. Basemap style
configuration is rendered by `web/src/mapStyle.ts` and
`ios/Looper/Looper/Map/MapStyleConfiguration.swift`.

### The style editor and its backend

Run the editor at `/map-style-editor` from the web development server to create and manage
styles, tune their colours against live vector tiles, and edit the shared route-option
colours. **Save to apps** writes `map-styles.json` and regenerates both platform files, so
a palette is never copied by hand between web and iOS.

The backend is `web/dev/mapStyleBackend.ts`, a Vite plugin serving a single endpoint
(`/__looper-style-editor/config`). Two things about it are deliberate:

- **It is development-only.** It writes files in the repository, so it exists solely in the
  dev server and is never part of a production build. Nothing in the deployed PWA can
  reach it.
- **It validates before it writes.** `validateCatalogue` checks the version, style IDs,
  names, every palette key, and the route colours, and rejects unknown palette fields. The
  files it writes are generated and committed, so a bad save is a bad commit — the
  validation is what keeps a typo out of both clients at once.

Regenerated output — `web/src/mapStyleConfig.generated.ts` and
`ios/LooperKit/Sources/LooperKit/MapStyleConfig.generated.swift` — is committed, and edited
only through the editor. Change `map-styles.json` and the two generated files together, or
the clients disagree about what colour something is.

- `web/src/MapView.tsx` owns the web map, start/current-location markers, gestures and
  camera. Routes remain screen-space SVG overlays projected by MapLibre, which keeps
  their existing selection, colour, width and chevron behaviour above the basemap.
- `ios/Looper/Looper/Map/MapLibreMapView.swift` owns the interactive iOS map, annotations,
  gestures and camera. Route GeoJSON is represented by `MLNShapeSource` objects; route
  line and chevron layers are appended after the basemap style loads, placing them above
  its layers.
- `ios/Looper/Looper/Map/LoopSummaryMapView.swift` uses the same basemap for completed
  outing previews. `ios/Looper/Looper/Support/RouteTileCache.swift` uses the same style
  URL for per-walk offline regions.

The previous 256-by-256 OpenStreetMap PNG source was not misconfigured for Retina
displays. MapLibre scaled it as configured, but scaling source pixels cannot provide the
native sharpness of vector roads and labels.

## Local development

```bash
cd route-service
cp .env.example .env          # nothing secret in it; no API keys exist here
docker compose up --build     # GraphHopper + route service

cd ../web
npm install && npm run dev    # the PWA on :5173, proxying /v1 to :8988
```

The first `docker compose up` imports both OpenStreetMap extracts before the route service
will answer. The Isle of Man import is quick; England takes longer and needs substantially
more memory. Each container reports healthy once `/info` responds. Later starts reuse the
imported graphs and come up in seconds.

Check the stack is alive:

```bash
curl localhost:8988/health
curl -X POST localhost:8988/v1/loops -H 'content-type: application/json' \
  -d '{"start":{"lng":-4.4816,"lat":54.1506},"mode":"distance","distanceKm":5,"units":"km"}'
```

Vite proxies `/v1` to `http://localhost:8988`, so in development the browser sees a single
origin and no CORS. Set `LOOPER_API_URL` in `.env` if the route service is somewhere else.

### Running the route service without Docker

```bash
cd route-service
npm install
GRAPHHOPPER_URL=http://localhost:8989 npm run dev
```

## Importing OpenStreetMap data

Run the Docker commands in this section from `route-service/`.

The stack currently serves Isle of Man and England from separate GraphHopper graphs. The
route service selects a graph from the requested starting location; a location outside
those supported areas receives a clear availability message.

The importer accepts a local file or a download URL, in that order of preference:

```bash
# .env
OSM_PBF_IOM_PATH=isle-of-man-latest.osm.pbf                              # looked for in route-service/data
OSM_PBF_IOM_URL=https://download.geofabrik.de/europe/isle-of-man-latest.osm.pbf
OSM_PBF_ENGLAND_PATH=england-latest.osm.pbf
OSM_PBF_ENGLAND_URL=https://download.geofabrik.de/europe/united-kingdom/england-latest.osm.pbf
```

If the file named by `OSM_PBF_PATH` is not there, the URL is downloaded once into the
volume and reused. Data is never re-downloaded or re-imported on an ordinary restart.

### Downloading PBF backups on a Windows Docker host

Keep the raw extracts in `route-service/data/` so a graph can be rebuilt without
downloading them again. The commands below download through the same Docker mount that
GraphHopper uses, write atomically via a `.part` file, and do not rebuild a running graph.
They assume the Compose project is named `looper_router`; change the value after `-p` if
your Docker project has a different name.

```powershell
# Isle of Man
docker compose -p looper_router run --rm --no-deps graphhopper-iom sh -c 'curl -fL --retry 5 --connect-timeout 30 --speed-time 60 --speed-limit 1024 -o /data/osm/isle-of-man-latest.osm.pbf.part https://download.geofabrik.de/europe/isle-of-man-latest.osm.pbf && mv /data/osm/isle-of-man-latest.osm.pbf.part /data/osm/isle-of-man-latest.osm.pbf'

# England
docker compose -p looper_router run --rm --no-deps graphhopper-england sh -c 'curl -fL --retry 5 --connect-timeout 30 --speed-time 60 --speed-limit 1024 -o /data/osm/england-latest.osm.pbf.part https://download.geofabrik.de/europe/united-kingdom/england-latest.osm.pbf && mv /data/osm/england-latest.osm.pbf.part /data/osm/england-latest.osm.pbf'
```

The completed files appear on the Windows host as `data/isle-of-man-latest.osm.pbf` and
`data/england-latest.osm.pbf`. Do not delete a `.part` file unless you intentionally want
to discard an interrupted download.

### Rebuilding the graph after an OSM update

The graph is only built when there isn't one. To replace it deliberately:

```bash
docker compose run --rm graphhopper-iom import                    # uses the IOM variables
docker compose run --rm graphhopper-england import                 # uses the England variables
docker compose up -d graphhopper-iom graphhopper-england
```

`import` wipes the graph cache and rebuilds from scratch, so GraphHopper is unavailable
while it runs. To avoid downtime, build the new graph into a second volume and switch.

## Deploying

The front end and the routing engine deploy separately. The engine holds a multi-hundred-
megabyte graph in memory and takes minutes to import; it cannot run in a serverless
function.

### Front end

Deploy `web/` to Vercel or any static host. Set one build-time variable:

```
VITE_LOOPER_API_BASE=https://looper-routes.example.com
```

Leave it blank only for local development, where Vite's proxy stands in for it. The value
is baked into the bundle at build time, so changing it needs a rebuild.

### Routing service

Deploy `route-service/docker-compose.prod.yml` to a small persistent container host — Fly.io, Render,
Railway, or a VPS. It differs from the development stack in one deliberate way:
GraphHopper publishes no port and is reachable only from the route service over the
internal Docker network. Only the route service faces the internet.

```bash
cd route-service
CORS_ORIGINS=https://looper.example.com docker compose -f docker-compose.prod.yml up -d --build
```

Set `CORS_ORIGINS` to the PWA's exact origin. It defaults to `*`, which is convenient
locally and wrong in production.

### Updating only the route service

On a Windows host using the `looper_router` Compose project, rebuild and replace only the
route service without interrupting either GraphHopper container or an in-progress PBF
download:

```powershell
docker compose -p looper_router -f docker-compose.prod.yml up -d --no-deps --build route-service
```

Sizing: the Isle of Man graph runs comfortably in 512 MB. England's first import is the
memory-hungry phase — use at least 8 GB available RAM with the default 6 GB England heap.
The graph volumes must be persistent, or every restart pays for a fresh import.

## How a loop is generated

1. **Candidates.** Twenty-four deterministic shapes, seeded from the rounded start point,
   the target distance and the `variation` counter. Each is three waypoints at 120°
   around an outer ring, in mirrored clockwise/counter-clockwise pairs.
2. **Sequential routing.** `start → A → B → C → start`, one ordinary point-to-point
   request per leg. After each leg its geometry becomes a buffered corridor, minus a 75 m
   circle around the start, and is handed to the next leg as a GraphHopper custom-model
   area at priority `0.05` — a twenty-fold cost, discouraging rather than forbidding. A
   leg that cannot be routed under that penalty is retried once at `0.2`, and if that
   fails the candidate is abandoned rather than quietly turned into an out-and-back.
3. **Quality.** Every finished candidate is measured: repeated corridors, out-and-back
   spurs, U-turns, leg balance, elongation, closure, and closeness to what was asked for.
   Anything outside the thresholds is rejected outright.
4. **Diversity.** Survivors are ranked, then filtered so no two offered walks share more
   than a third of their ground, preferring different ways out of the door.

If no clean loop passes, Looper falls back to walks of the right length that double back
on themselves, and says so plainly — some places have one road up a valley and no circuit
at any distance. Only if even the length is out of reach does it return nothing.

The fallback never mixes with clean loops: a walk that retraces is offered only when there
is no clean one at all, so the list is never a quiet blend of two different answers.

## Changing the walking profile

`route-service/graphhopper/looper_foot.json` is the custom model GraphHopper routes with.
It is a small file and it is the highest-leverage thing in the repository: a one-line
change to it moved the whole service by 2–3× in August 2026. Read this before touching it.

### Priority divides the weight

GraphHopper's weight is roughly `distance / (speed × priority)`. So `multiply_by: 0.1` on a
road class does **not** mean "prefer the alternative a bit". It means *the alternative is
worth walking ten times as far for*. That is almost never what is wanted, and the cost does
not show up as a slower engine — it shows up as a slower **service**:

1. Legs come back longer and bent, because the router took a large detour.
2. Longer legs miss what the corridor aimed at and blow `MAX_DISTANCE_ERROR` (0.12).
3. The candidate is rejected, and Looper asks again. And again.

Measured: a 0.1 demotion on non-pedestrian roads made legs 13–20% long and cost **2–3× the
engine calls** on urban ground, while `ms/call` and `visited_nodes` never moved. If a
profile change makes things slow, look at call counts before you look at the engine.

### Nudges are not preferences, and weak nudges are worse than none

Where OSM maps a pavement as its own way, a pavement and its carriageway weigh near enough
the same that the router takes whichever is a few metres shorter, block by block. Settling
that near-tie needs a *nudge*. But the sweep found the effect is not monotonic — at 0.95 and
0.9, hopping got **worse** than no preference at all, because the route takes the pavement
for some stretches and not others. 0.8 was the knee, and 0.6 and 0.3 were identical to it.

Reasoning had picked 0.9. Reasoning was wrong, and only in the one region that makes the
problem worse. **Sweep it; don't estimate it.**

### Measure it with the tools that exist

```bash
bench/probe-pavement.mjs     # sweep a multiplier over real legs — hops/km vs leg length
bench/probe-production.sh    # whole requests: calls, ms/call, nodes/call, hops/km
bench/probe-engine.mjs       # one leg against the engine, with and without landmarks
```

`probe-pavement.mjs` sends candidate values as **per-request** custom models, which compose
*multiplicatively* with the profile — so it only reads correctly against a neutral profile.
Sweeping against an already-demoting profile measures every value ten times too strong.

Trust **call counts and hops/km**: they have been byte-stable across runs. Do not trust
wall-clock — the same work measured three times in one evening gave 1.3 s, 1.9 s and 3.4 s.

### Deploying a profile change requires a graph rebuild

This is the operational trap, and it has bitten twice.

`looper_foot.json` is `COPY`'d into the **GraphHopper** image, not the route service, so a
profile change means rebuilding `graphhopper-iom` *and* `graphhopper-england` with
`--build`. Without it Compose reuses the old image and the deploy silently does nothing —
which looks exactly like a change that had no effect. Check what actually landed:

```bash
docker compose -p looper_router -f docker-compose.prod.yml exec graphhopper-iom cat /gh/looper_foot.json
```

Then both engines will fail their healthcheck and restart-loop. Observed twice, on two
different profile changes, and cleared both times by deleting the graph volumes; the logs
were never actually read, so the *reason* is inferred rather than established — most likely
that landmarks are prepared against the profile's weighting and GraphHopper will not serve a
graph prepared under a different one. `entrypoint.sh` cannot save you either way:
`graph_ready()` only checks that `edges` exists, so it keeps trying to serve a graph the
engine rejects. If it happens again, read the logs first and settle it:

```bash
docker compose -p looper_router -f docker-compose.prod.yml logs --tail=40 graphhopper-iom
```

Then delete the graph volumes and let them reimport:

```bash
docker compose -p looper_router -f docker-compose.prod.yml down
docker volume rm looper_router_graph-cache-iom looper_router_graph-cache-england
docker compose -p looper_router -f docker-compose.prod.yml up -d
```

**Keep `osm-data`** — it holds the downloaded extracts, and deleting it re-downloads
England for nothing. Do the Isle of Man first and confirm it comes up healthy before
committing to the England import, which is the long one.

Bump `profileVersion` in `route-service/src/config.ts` with every profile change. It is a
cache epoch, so it always goes forward — never back to a previous value, even when the
weighting itself is a revert.

### Open

Shipping the 0.8 pavement nudge regressed **waypoint mode**: `wp-two` went from 54 engine
calls to 379, the backbone rejects all 24 plans (`shapeless`, `u-turns`,
`out-and-back-spur`) and falls back to `legacy-guides`. Unexplained. The likely mechanism is
that pavement routing adds crossings and set-backs, so the backbone comes back wigglier and
trips shape gates — `MAX_U_TURNS` is 1, and stepping onto a pavement and back may read as a
U-turn. Standard loops are unaffected and improved.

Also unresolved: `hops/km` counts *all* pedestrian-to-carriageway transitions, so a walk
legitimately turning onto a park path scores the same as a confusing flip-flop. It is a good
relative signal and a poor absolute one. Single legs improved 3 hops → 1 under the nudge;
whole loops only 3–20%, and the gap is probably this.

The full history, including four wrong hypotheses that each cost a day, is in
[`route-service/docs/routing-report.md`](route-service/docs/routing-report.md).

## Checks

```bash
(cd web && npm run lint && npm run typecheck && npm test && npm run build)
(cd route-service && npm run lint && npm run typecheck && npm test && npm run build)
(cd ios/LooperKit && swift test)
```

Run checks from each component directory. The service can be checked with:

```bash
cd route-service && npm run lint && npm run typecheck && npm test
```

## Known limits

- **There is not always a clean loop.** Coastlines, rivers, railways, sparse rural paths
  and cul-de-sac estates can leave no circuit at a chosen distance. Looper then offers the
  best walk of the right length that doubles back, labelled as such.
- **Open country wants longer walks.** The distance at which a clean loop exists is set by
  the terrain: around a single valley road it may be 12 km when 5 km was asked for. Nothing
  is stretched to fit — the shorter request falls back or returns nothing.
- **Distance is a target, not a promise.** Loops are offered within ±12% of the request.
  Where the streets cannot get closer than that, nothing is offered.
- **Live guidance needs the app open.** Browser PWAs cannot guarantee guidance while
  backgrounded or locked.
- **Geolocation needs HTTPS.** Test on a phone against the deployed URL, not a LAN
  address.

## Possible future work

- **Offline map-area downloads.** Let a walker download tiles for a chosen area ahead
  of time, for use with no signal. `RouteTileCache.swift` already does this per-route
  automatically via MapLibre's `MLNOfflineStorage` / `MLNTilePyramidOfflineRegion`, but
  ties the pack to a single walk and releases it when the walk ends. A user-facing
  version would reuse the same API with a persistent (not auto-released) pack: let the
  walker pick an area (e.g. the current map viewport), show download progress via the
  pack's KVO progress updates, and add a small list in Settings to view/delete saved
  areas since they'd no longer expire on their own. Tile storage grows fast at high
  zoom (the walk cache already goes to zoom 18), so a manual download would likely want
  a capped zoom range and an estimated-size prompt before starting.

## Attribution

Map data and routing are derived from **OpenStreetMap**, © OpenStreetMap contributors,
available under the [Open Database Licence](https://www.openstreetmap.org/copyright).
OpenFreeMap supplies the OpenMapTiles vector basemap style and hosting. Both the map tiles
and every route Looper generates are ODbL-licensed derivatives, so the credit must stay
visible wherever the app is deployed. It is shown in the app on the welcome screen.
Routing is performed by self-hosted [GraphHopper](https://www.graphhopper.com/), Apache 2.0.
