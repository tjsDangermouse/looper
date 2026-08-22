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
npm install && npm run dev    # the PWA on :5173, proxying /v1 to :8080
```

The first `docker compose up` imports the OpenStreetMap extract before GraphHopper will
answer. On the Isle of Man that takes well under a minute; the container reports healthy
once `/info` responds. Later starts reuse the imported graph and come up in seconds.

Check the stack is alive:

```bash
curl localhost:8080/health
curl -X POST localhost:8080/v1/loops -H 'content-type: application/json' \
  -d '{"start":{"lng":-4.4816,"lat":54.1506},"mode":"distance","distanceKm":5,"units":"km"}'
```

Vite proxies `/v1` to `http://localhost:8080`, so in development the browser sees a single
origin and no CORS. Set `LOOPER_API_URL` in `.env` if the route service is somewhere else.

### Running the route service without Docker

```bash
cd services/route-service
npm install
GRAPHHOPPER_URL=http://localhost:8989 npm run dev
```

## Importing OpenStreetMap data

The Isle of Man is the default region. Nothing in the stack is specific to it — any
Geofabrik (or other) `.osm.pbf` extract works.

The importer accepts a local file or a download URL, in that order of preference:

```bash
# .env
OSM_PBF_PATH=isle-of-man-latest.osm.pbf                                  # looked for in ./data
OSM_PBF_URL=https://download.geofabrik.de/europe/isle-of-man-latest.osm.pbf
```

If the file named by `OSM_PBF_PATH` is not there, the URL is downloaded once into the
volume and reused. Data is never re-downloaded or re-imported on an ordinary restart.

### Switching region

```bash
# e.g. Greater Manchester instead
OSM_PBF_URL=https://download.geofabrik.de/europe/great-britain/england/greater-manchester-latest.osm.pbf
OSM_PBF_PATH=greater-manchester-latest.osm.pbf
```

Then rebuild the graph (below). Larger extracts need more memory for the import — raise
`GH_HEAP` to roughly 2–4 GB per country-sized extract.

### Rebuilding the graph after an OSM update

The graph is only built when there isn't one. To replace it deliberately:

```bash
docker compose run --rm graphhopper import                       # uses OSM_PBF_PATH / OSM_PBF_URL
docker compose run --rm graphhopper import /data/osm/some.pbf    # or an explicit file
docker compose run --rm graphhopper import https://example.com/region.osm.pbf
docker compose up -d graphhopper
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

Sizing: the Isle of Man graph runs comfortably in 512 MB. Import is the memory-hungry
phase — give the machine at least `GH_HEAP` plus 512 MB during the first boot. The graph
volume must be persistent, or every restart pays for a fresh import.

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

If nothing passes, the response carries no routes and a plain sentence saying so. Looper
does not pad the list with walks nobody wanted.

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

- **There is not always a loop.** Coastlines, rivers, railways, sparse rural paths and
  cul-de-sac estates can leave no clean circuit at a chosen distance. Looper says so
  rather than offering a walk out and back.
- **Distance is a target, not a promise.** Loops are offered within ±12% of the request.
  Where the streets cannot get closer than that, nothing is offered.
- **Live guidance needs the app open.** Browser PWAs cannot guarantee guidance while
  backgrounded or locked.
- **Geolocation needs HTTPS.** Test on a phone against the deployed URL, not a LAN
  address.

## Attribution

Map data and routing are derived from **OpenStreetMap**, © OpenStreetMap contributors,
available under the [Open Database Licence](https://www.openstreetmap.org/copyright).
Both the map tiles and every route Looper generates are ODbL-licensed derivatives, so the
credit must stay visible wherever the app is deployed. It is shown in the app on the
welcome screen and in the map's attribution control — keep both. Routing is performed by
self-hosted [GraphHopper](https://www.graphhopper.com/), Apache 2.0.
