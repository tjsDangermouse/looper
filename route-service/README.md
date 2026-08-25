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
