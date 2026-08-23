# Looper

A mobile-first PWA for finding circular walks that bring you back to where you started.

Looper generates its own loops. It proposes rings of waypoints around you, routes each
leg of the ring separately while holding the ground already walked against the next leg,
measures every finished candidate, and offers only the ones that are genuinely loops.
Nothing here asks a routing engine for a "round trip".

```text
Looper PWA  ─────►  Looper Route Service  ─────►  self-hosted GraphHopper
 (Vite/React)          POST /v1/loops              (walking graph)
                                                          │
                                                   OpenStreetMap PBF
```

The app talks to Looper's own API and to nothing else. There is no third-party routing
provider and no routing API key anywhere in this repository.

## Layout

| Path | What it is |
| --- | --- |
| `src/` | The PWA: map, planner, route choices, active-walk guidance |
| `services/route-service/` | The Looper Route Service — loop generation, quality, diversity |
| `graphhopper/` | Self-hosted GraphHopper: Dockerfile, `config.yml`, import/serve entrypoint |
| `docker-compose.yml` | Local development stack |
| `docker-compose.prod.yml` | Production stack — GraphHopper stays on the internal network |
| `data/` | Where OSM extracts live (git-ignored) |

## Local development

```bash
cp .env.example .env          # nothing secret in it; no API keys exist here
docker compose up --build     # GraphHopper + route service
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
cd services/route-service
npm install
GRAPHHOPPER_URL=http://localhost:8989 npm run dev
```

## Importing OpenStreetMap data

The stack currently serves Isle of Man and England from separate GraphHopper graphs. The
route service selects a graph from the requested starting location; a location outside
those supported areas receives a clear availability message.

The importer accepts a local file or a download URL, in that order of preference:

```bash
# .env
OSM_PBF_IOM_PATH=isle-of-man-latest.osm.pbf                              # looked for in ./data
OSM_PBF_IOM_URL=https://download.geofabrik.de/europe/isle-of-man-latest.osm.pbf
OSM_PBF_ENGLAND_PATH=england-latest.osm.pbf
OSM_PBF_ENGLAND_URL=https://download.geofabrik.de/europe/united-kingdom/england-latest.osm.pbf
```

If the file named by `OSM_PBF_PATH` is not there, the URL is downloaded once into the
volume and reused. Data is never re-downloaded or re-imported on an ordinary restart.

### Downloading PBF backups on a Windows Docker host

Keep the raw extracts in the project's `data/` folder so a graph can be rebuilt without
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

Stays where it is — Vercel or any static host. Set one build-time variable:

```
VITE_LOOPER_API_BASE=https://looper-routes.example.com
```

Leave it blank only for local development, where Vite's proxy stands in for it. The value
is baked into the bundle at build time, so changing it needs a rebuild.

### Routing service

Deploy `docker-compose.prod.yml` to a small persistent container host — Fly.io, Render,
Railway, or a VPS. It differs from the development stack in one deliberate way:
GraphHopper publishes no port and is reachable only from the route service over the
internal Docker network. Only the route service faces the internet.

```bash
CORS_ORIGINS=https://looper.example.com docker compose -f docker-compose.prod.yml up -d --build
```

Set `CORS_ORIGINS` to the PWA's exact origin. It defaults to `*`, which is convenient
locally and wrong in production.

### Updating only the route service

On a Windows host using the `looper_router` Compose project, rebuild and replace only the
route service without interrupting either GraphHopper container or an in-progress PBF
download:

```powershell
docker compose -p looper_router up -d --build --no-deps --force-recreate route-service
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

## Checks

```bash
npm run lint && npm run typecheck && npm test && npm run build
```

`npm test` at the repository root runs both the app's tests and the route service's.
The service can also be checked on its own:

```bash
cd services/route-service && npm run lint && npm run typecheck && npm test
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
Both the map tiles and every route Looper generates are ODbL-licensed derivatives, so the
credit must stay visible wherever the app is deployed. It is shown in the app on the
welcome screen and in the map's attribution control — keep both. Routing is performed by
self-hosted [GraphHopper](https://www.graphhopper.com/), Apache 2.0.
