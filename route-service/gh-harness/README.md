# LooperRoutingCore

The narrow seam between Looper and GraphHopper, and the Phase 1 evidence that
it behaves exactly like the shipped GraphHopper server.

Nothing here implements routing. `LooperRoutingCore` configures GraphHopper
from the same `graphhopper/config.yml` the container runs — deserialised into
GraphHopper's own `GraphHopperConfig`, so there is no second copy of the
settings to drift — loads the graph the container imported, and calls
`hopper.route`. The search, the snapping, the query graph, the custom-model
weighting and the landmark heuristic are all GraphHopper's, unmodified, used as
a Maven dependency. See [NOTICE.md](NOTICE.md).

| Class | Role |
|---|---|
| `LooperRoutingCore` | the facade: `snap`, `route(points, options)`, `routeJsonBody` |
| `Harness` | the equivalence benchmark; reads Looper's own request bodies |
| `Serve` | JDK `com.sun.net.httpserver` transport, so a TypeScript caller can reach the core |

`Serve` exists only because Looper is TypeScript and the core is Java: the
whole-generation comparison cannot run without a socket between them. It is
deliberately the JDK's own server and GraphHopper's own response serializer
rather than the Dropwizard stack, and the difference between what it costs and
what the container costs is the price of that stack — measured at a 32.7 MB
jar, 230 MiB of RSS and a 1.6 s → 0.6 s warm start, for no routing speed.

`routeJsonBody` is the equivalence path: the same JSON body `src/graphhopper.ts`
POSTs is deserialised by GraphHopper's own Jackson module into the very
`GHRequest` the HTTP resource would have built, the one default the resource
applies (snap preventions) is applied, and the same `hopper.route` is called.
Everything that differs from the container is therefore HTTP and JSON, and
nothing else.

## Build and run

```sh
docker build -t looper-gh-harness .
```

Then see [bench/equivalence/README.md](../bench/equivalence/README.md).

The harness never imports: it loads what the container built, read-only. That
is deliberate — a second import could differ, and then a graph difference would
be reported as an engine difference.
