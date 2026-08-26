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
production probe settled on, and both compose files pass them through. Which of
the two places you put one in is the whole question, and it follows from how
long you mean it to last.

**Trying one, to measure it — use `.env`.** Copy the line you want out of
`.env.example` into a `.env` beside the compose file, and bring the service
back up. Only the route service is recreated, so GraphHopper keeps its imported
graphs and this is seconds rather than a reimport:

```
LOOPER_PROGRESSIVE_CORNER_SWEEP=true
```

```
docker compose -f docker-compose.prod.yml up -d route-service
```

Compose reads `.env` from the compose file's own directory automatically, on
every host and in every shell. Delete or comment the line and run the same
`up -d` to put it back.

On Windows, write that file as ASCII. PowerShell 5.1's `>` and `Set-Content`
default to UTF-16 with a byte-order mark, which Compose cannot read at all —
it fails with `unexpected character` and a variable name with a null byte
between every letter:

```powershell
Set-Content -Path .env -Value 'LOOPER_PROGRESSIVE_CORNER_SWEEP=true' -Encoding ascii
```

Prefer this to setting the variable in the shell. It survives a reboot, a new
terminal and whoever runs the next deployment, none of which a shell variable
does — and a shell variable that has quietly expired looks exactly like a flag
that did nothing, which is the one failure that wastes a measurement. Note that
`docker compose restart` picks up neither: it restarts the container as it
already stands, so it has to be `up -d`.

Measure with `bench/probe-production.sh`. It is a bash script and only sends
ordinary route requests, so it runs from WSL, Git Bash, or any machine that can
reach the service — it does not have to be the host.

**Keeping one, because the measurement settled it — use `flags.ts`.** Change
`DEFAULT_FLAGS` and commit it with the numbers, the way every flag that ships
on got there, and take the line back out of `.env`. `.env` is gitignored, so a
flag left in it is a fork of the algorithm that nothing in the repository
mentions and no one reviewing the code can see.

A variable left unset arrives as an empty string, which is read as "leave it as
it ships", so an incomplete `.env` cannot quietly switch off the flags that
ship on. Only an explicit `true` or `1` turns one on; anything else, a typo
included, means the algorithm you already had.
