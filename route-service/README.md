# Looper Route Service

The route service owns loop generation and the public
[Loop API v1 contract](contracts/loop-api/v1.md). It is independently
buildable and deployable; web and iOS clients access it only over HTTP.

## Run locally

```bash
npm install
GRAPHHOPPER_URL=http://localhost:8989 npm run dev
```

Or, from the repository root, start the complete routing stack:

```bash
docker compose up --build
```

The `graphhopper/` directory, Compose files, `data/` documentation, and API
contract are deployment assets owned by this service. They are colocated here
so this directory can move to its own repository as one unit:

- `graphhopper/`
- `docker-compose.yml` and `docker-compose.prod.yml`
- `data/README.md` (but not the ignored OSM extracts)
- `contracts/loop-api/`

## Checks

```bash
npm run lint
npm run typecheck
npm test
npm run build
```

## Configuration

`GRAPHHOPPER_IOM_URL` and `GRAPHHOPPER_ENGLAND_URL` select the underlying
engines. `CORS_ORIGINS` is the comma-separated allow-list for browser clients;
set it to the deployed web origin in production. Other service tuning variables
are documented in `src/config.ts`.

### Flipping an algorithm flag on a deployment

Every `LOOPER_*` flag in `.env.example` ships at the default the benchmark or a
production probe settled on, and both compose files pass them through from the
host. To change one, put it in `.env` next to the compose file and restart just
the service — GraphHopper keeps its imported graphs, so this is seconds rather
than a reimport:

```bash
echo 'LOOPER_PROGRESSIVE_CORNER_SWEEP=true' >> .env
docker compose -f docker-compose.prod.yml up -d route-service
curl -s localhost:8988/health          # or bench/probe-production.sh to measure it
```

A variable left unset arrives as an empty string, which is read as "leave it as
it ships" — so an incomplete `.env` cannot quietly switch off the flags that
ship on. Only an explicit `true` or `1` turns one on; anything else, a typo
included, means the algorithm you already had.
