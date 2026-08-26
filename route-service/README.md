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
host environment. There is no `.env` file in play unless you make one, and for
most of these you do not want one — where a flag lives says what it means.

**Trying one, to measure it.** Set it for the one command. Only the route
service is recreated, so GraphHopper keeps its imported graphs and this is
seconds rather than a reimport:

```bash
LOOPER_PROGRESSIVE_CORNER_SWEEP=true docker compose -f docker-compose.prod.yml up -d route-service
```

The production host runs Docker Desktop on Windows, where that first line is
bash syntax PowerShell does not have. There, set it and then run the command:

```powershell
$env:LOOPER_PROGRESSIVE_CORNER_SWEEP = "true"
docker compose -f docker-compose.prod.yml up -d route-service
```

Either way, measure it with `bench/probe-production.sh` — a bash script, so
from WSL, Git Bash, or any machine that can reach the service, since it only
sends ordinary route requests.

To put it back, clear the variable and run the same `up -d` again
(`Remove-Item Env:\LOOPER_PROGRESSIVE_CORNER_SWEEP` in PowerShell). Nothing
persists: interpolation happens at `up` time, so the next deployment that does
not name the flag gets the shipped default. Note that `docker compose restart`
will *not* pick a change up — it restarts the container as it already stands,
and `$env:` lasts only as long as the PowerShell session that set it.

**Keeping one, because the measurement settled it.** Change `DEFAULT_FLAGS` in
`src/loops/flags.ts` and commit it with the numbers, the way every flag that
ships on got there. A decision that outlives a redeploy belongs in the file
that records why it was taken, not in the environment of one host, where it is
invisible to anyone reading the algorithm.

A `.env` beside the compose file is read too, and suits a setting genuinely
local to one host — but a flag held there is a fork of the algorithm that
nothing in the repository mentions.

A variable left unset arrives as an empty string, which is read as "leave it as
it ships", so an incomplete environment cannot quietly switch off the flags
that ship on. Only an explicit `true` or `1` turns one on; anything else, a
typo included, means the algorithm you already had.
